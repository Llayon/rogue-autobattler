extends RefCounted
## Phase 3 / B2.2 / DamageEffect — generic deterministic
## physical damage.
##
## Semantics (Phase 2 parity):
##   - Uses Balance.compute_damage (pure defense scaling)
##   - NO crit / dodge / variance (NORMATIVE FEATURE DEFER)
##   - Damage amount = actual HP removed (not requested)
##   - Dead target -> EffectResult.failed (no mutation, no event)
##   - Invalid target -> EffectResult.failed
##   - Self-target -> EffectResult.failed
##
## Event semantics:
##   - Emits DAMAGE_APPLIED (NOT ATTACK_RESOLVED).
##   - If lethal, emits UNIT_DIED as a CHILD of DAMAGE_APPLIED.
##   - result.events contains EVERY event emitted, in emission
##     order. For lethal damage: [DAMAGE_APPLIED, UNIT_DIED].
##
## B2.2 ancestry contract:
##   - Validates req.validate_ancestry() BEFORE any mutation.
##   - Bad ancestry -> success=false, no world mutation, no
##     event, no emitter counter advance.
##
## Called ONLY through EffectExecutor. Never invoked directly.

const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const EffectResultScript = preload("res://core/battle_ecs/effects/effect_result.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const BalanceScript = preload("res://core/balance.gd")


## Execute damage effect against the world's target_entity.
## Emits DAMAGE_APPLIED (and UNIT_DIED on kill) through the
## emitter. Does NOT emit ATTACK_RESOLVED.
static func execute(ctx, req) -> RefCounted:
	# B2.2: validate ancestry FIRST. No mutation may occur
	# before this check.
	var av = req.validate_ancestry()
	if not bool(av.get("ok", false)):
		return EffectResultScript.failed(
			"damage invalid ancestry: %s" % String(av.get("reason", "")),
			[], false)
	var world = ctx.world()
	# Validate target.
	if not world.is_alive(int(req.target_entity)):
		return EffectResultScript.failed("target not alive", [], false)
	var src: int = int(req.source_entity)
	var tgt: int = int(req.target_entity)
	if src == tgt:
		return EffectResultScript.failed("source equals target", [], false)
	# Compute damage via Balance.compute_damage. is_magic=false.
	var atk: int = int(world.attack_of(src))
	var dfs: int = int(world.defense_of(tgt))
	var dmg: int = int(BalanceScript.compute_damage(
		atk, dfs, false, 0.0, 1.0))
	# Override with request amount if explicitly provided and
	# non-zero (caller is source of truth for explicit damage).
	if int(req.amount) > 0:
		dmg = int(req.amount)
	var emitter = ctx.emitter()
	var req_parent: int = int(req.parent_event_id)
	var req_root: int = int(req.root_action_id)
	var req_depth: int = int(req.chain_depth)
	# Build DAMAGE_APPLIED via the emitter. If the request is
	# CHILD, the emitted event has chain_depth == req_depth and
	# shares req_root_action_id. If ROOT, the emitter allocates
	# a fresh root.
	var dmg_event = null
	if String(av.get("kind", "")) == EffectRequestScript.ANCESTRY_CHILD:
		dmg_event = emitter.emit_child(
			BattleEventTypeScript.DAMAGE_APPLIED,
			req_parent,
			req_root,
			req_depth - 1,  # emitter stores parent.depth; ours is depth+1
			src,
			tgt,
			"",
			"",
			0,  # amount placeholder; set after apply
			"")
	else:
		# ROOT request.
		dmg_event = emitter.emit(
			BattleEventTypeScript.DAMAGE_APPLIED,
			src,
			tgt,
			"",
			"",
			0,  # amount placeholder; set after apply
			"")
	if dmg_event == null:
		return EffectResultScript.failed(
			"damage emit failed (request was valid but emitter refused)", [], false)
	# Apply damage (returns actual amount removed, capped at HP).
	var dealt: int = int(world.apply_damage(tgt, dmg))
	# Patch the event with the actual dealt amount (post-apply).
	dmg_event.amount = int(dealt)
	ctx.emit_through_sink(dmg_event)
	# B2.2: result.events must include EVERY emitted event.
	var result_events: Array = [dmg_event]
	# If lethal, emit UNIT_DIED as child of DAMAGE_APPLIED.
	var continues_chain: bool = true
	if dealt > 0 and not world.is_alive(tgt):
		var died_event = emitter.emit_child(
			BattleEventTypeScript.UNIT_DIED,
			int(dmg_event.event_id),
			int(dmg_event.root_action_id),
			int(dmg_event.chain_depth),
			src,
			tgt)
		if died_event != null:
			ctx.emit_through_sink(died_event)
			result_events.append(died_event)
		# UNIT_DIED ends the chain (no reaction should fire on
		# a dead unit within this EffectExecutor pass).
		continues_chain = false
	return EffectResultScript.succeeded(result_events, continues_chain)
