extends RefCounted
## Phase 3 / B6.4c / DamageEffect — generic deterministic
## physical damage routed through the B6.4b DamageTransaction
## seam and the B6.4c pre-damage reaction window.
##
## B2.2 semantics (Phase 2 parity) for amount selection:
##   - req.amount > 0  -> use it as base
##   - otherwise       -> Balance.compute_damage path
##   - Dead target    -> EffectResult.failed (no event)
##   - Self-target    -> EffectResult.failed
##
## B6.4b integration: uses DamageTransaction.
## B6.4c integration: routes through DamageWindowWorkItem
## before commit. DAMAGE_APPLIED is allocated by the continuation's
## finalize(), NOT here. The pre-damage window is mandatory for
## every DamageEffect invocation (ROOT or CHILD ancestry).
##
## B6.4c ancestry contract:
##   ROOT:  DAMAGE_STARTED (depth 0, root)
##          └ DAMAGE_APPLIED (depth 1)
##            └ UNIT_DIED if lethal
##   CHILD: matches request ancestry
##          e.g. parent=STATUS_TICKED, depth=N
##                DAMAGE_STARTED (depth N+1)
##                └ DAMAGE_APPLIED (depth N+2)
##
## B2.2 contract: validates req.validate_ancestry() BEFORE any
## mutation. Bad ancestry -> success=false, no world mutation,
## no event, no emitter counter advance.
##
## Called through EffectExecutor. Never invoked directly.

const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const EffectResultScript = preload("res://core/battle_ecs/effects/effect_result.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const BalanceScript = preload("res://core/balance.gd")
const DamageTransactionScript = preload(
	"res://core/battle_ecs/effects/damage_transaction.gd")
const DamageWindowHandleScript = preload(
	"res://core/battle_ecs/effects/damage_window_handle.gd")
const DamageWindowContinuationScript = preload(
	"res://core/battle_ecs/effects/damage_window_continuation.gd")
const DamageWindowWorkItemScript = preload(
	"res://core/battle_ecs/effects/damage_window_work_item.gd")


## Execute damage effect against the world's target_entity.
## Emits DAMAGE_STARTED + returns a DamageWindowWorkItem in
## dispatch_work. Does NOT emit DAMAGE_APPLIED here; the
## continuation's finalize() does that AFTER pre-damage
## reactions.
static func execute(ctx, req) -> RefCounted:
	var av = req.validate_ancestry()
	if not bool(av.get("ok", false)):
		return EffectResultScript.failed(
			"damage invalid ancestry: %s" % String(av.get("reason", "")),
			[], false)
	var world = ctx.world()
	if not world.is_alive(int(req.target_entity)):
		return EffectResultScript.failed("target not alive", [], false)
	var src: int = int(req.source_entity)
	var tgt: int = int(req.target_entity)
	if src == tgt:
		return EffectResultScript.failed("source equals target", [], false)

	# Amount selection: explicit overrides Balance.
	var dmg: int = 0
	if int(req.amount) > 0:
		dmg = int(req.amount)
	else:
		var atk: int = int(world.attack_of(src))
		var dfs: int = int(world.defense_of(tgt))
		dmg = int(BalanceScript.compute_damage(
			atk, dfs, false, 0.0, 1.0))

	var emitter = ctx.emitter()
	var req_parent: int = int(req.parent_event_id)
	var req_root: int = int(req.root_action_id)
	var req_depth: int = int(req.chain_depth)

	# B6.4c: extract the semantic tag from payload (used by
	# periodic processor to carry status_id for ancestry
	# identity). Empty when no semantic tag was attached.
	var sem_tag: StringName = &""
	if req.payload != null:
		var t: Variant = req.payload.get(
			EffectRequestScript.PAYLOAD_EVENT_TAG, null)
		if t != null:
			sem_tag = StringName(String(t))

	# Build DAMAGE_STARTED with the appropriate ancestry kind.
	var dmg_started = null
	if String(av.get("kind", "")) == EffectRequestScript.ANCESTRY_CHILD:
		dmg_started = emitter.emit_child(
			BattleEventTypeScript.DAMAGE_STARTED,
			req_parent, req_root, req_depth - 1,
			src, tgt, "", "",
			int(dmg), String(sem_tag),
			Vector2i(-1, -1), Vector2i(-1, -1),
			int(_origin_of_request(req)))
	else:
		dmg_started = emitter.emit(
			BattleEventTypeScript.DAMAGE_STARTED,
			src, tgt, "", "",
			int(dmg), String(sem_tag),
			Vector2i(-1, -1), Vector2i(-1, -1),
			int(_origin_of_request(req)))
	if dmg_started == null:
		return EffectResultScript.failed(
			"damage emit failed (request was valid but emitter refused)",
			[], false)

	# Damage transaction.
	var tx = DamageTransactionScript.new()
	if not bool(tx.setup(src, tgt, int(dmg))):
		return EffectResultScript.failed(
			"damage transaction setup rejected (base=%d)"
			% int(dmg), [], false)

	# Synchronously publish DAMAGE_STARTED.
	var sink: Array = ctx.event_sink()
	sink.append(dmg_started)

	# Build window machinery.
	var handle = DamageWindowHandleScript.new()
	handle.setup(tx)
	var continuation = DamageWindowContinuationScript.new()
	continuation.tx = tx
	continuation.handle = handle
	continuation.event = dmg_started
	continuation.source_entity = src
	continuation.target_entity = tgt
	# DamageEffect has no RunUnit identity propagation; use empty.
	# The continuation will use them only for events it allocates.
	continuation.source_run_unit_id = ""
	continuation.target_run_unit_id = ""
	# B6.4c: tag contract — origin-aware.
	#   The DAMAGE_STARTED intent event already carries the
	#   payload tag (e.g. "burn" from the periodic processor) —
	#   it is materialised at allocation time, so the
	#   continuation does not keep it.
	#   final_event_tag = "" (legacy) — direct DamageEffect
	#                    does NOT carry a tag on DAMAGE_APPLIED
	#                    or UNIT_DIED. This matches a5dd87d
	#                    legacy semantic differential exactly.
	#   died_event_tag = "" and died_amount_is_dealt = false
	#                    — legacy DamageEffect emitted
	#                    UNIT_DIED with the DEFAULT arguments,
	#                    so amount = 0 and tag = "".
	continuation.final_event_tag = StringName("")
	continuation.died_event_tag = StringName("")
	continuation.died_amount_is_dealt = false

	# delayed_dispatch_seeds: empty for direct ROOT DamageEffect
	# (no parent event to delay). For CHILD DamageEffect called
	# from a reaction, the triggering parent is already in the
	# active FIFO; we do not need to delay it.
	var work_item = DamageWindowWorkItemScript.new(
		dmg_started, continuation, handle, [])

	# B6.4c: succeeds_with_work. The work-pump processes the
	# window after this synchronous phase.
	return EffectResultScript.succeeded_with_work(
		[dmg_started], [work_item], true)

## B6.4d / damage origin discriminator.
##
## The origin is stated by the REQUEST, never guessed from a
## string. A request may carry an explicit origin on its payload
## (the periodic processor sets PERIODIC). Otherwise the request
## is a DIRECT damage.
static func _origin_of_request(req) -> int:
	if req != null and req.payload != null:
		var raw = req.payload.get(
			EffectRequestScript.PAYLOAD_DAMAGE_ORIGIN, null)
		if raw != null:
			return int(raw)
	return int(EffectRequestScript.DAMAGE_ORIGIN_DIRECT)
