extends RefCounted
## B6.1 + B6.4c — canonical attack execution path routed through
## the B6.4b DamageTransaction seam and the B6.4c pre-damage
## reaction window.
##
## BOTH BattleSimulation normal attacks and reaction
## PerformAttack requests route through this effect. There
## is exactly ONE production mutation path for attacks.
##
## Validation order (no mutation / event allocation before
## all checks pass):
##   1. req != null + req.validate_ancestry_shape() ok
##   2. source exists + alive
##   3. source is not blocks_actions() (real Stun)
##   4. target exists + alive
##   5. source != target
##   6. opposing teams
##   7. target is in attack range
## Failure returns EffectResult.failed(reason, [], false).
##
## B6.4c sequence:
##   1. validate attack
##   2. compute raw/base damage
##   3. create ATTACK_RESOLVED (ROOT or CHILD based on req)
##   4. create DamageTransaction, setup with raw_dmg
##   5. create DAMAGE_STARTED as CHILD of ATTACK_RESOLVED
##      amount = base (= raw_dmg, immutable)
##   6. publish ATTACK_RESOLVED + DAMAGE_STARTED synchronously
##   7. create DamageWindowHandle(tx)
##   8. create DamageWindowContinuation
##   9. create DamageWindowWorkItem with
##      delayed_dispatch_seeds = [ATTACK_RESOLVED]
##  10. return EffectResult.succeeded_with_work(
##         [ATTACK_RESOLVED, DAMAGE_STARTED], [work_item], continues_chain)
##
## DO NOT commit HP, allocate DAMAGE_APPLIED, allocate UNIT_DIED,
## or call TriggerDispatcher here.
##
## B6.4c ancestry contract (PerformAttack):
##   ATTACK_RESOLVED  (depth 0, root)
##   └ DAMAGE_STARTED  (depth 1)
##     └ DAMAGE_APPLIED  (depth 2, allocated by continuation.finalize)
##       └ UNIT_DIED if lethal
##
## ATTACK_RESOLVED.amount remains the BASE/RAW attack damage.

const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const EffectResultScript = preload(
	"res://core/battle_ecs/effects/effect_result.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const AttackMathScript = preload(
	"res://core/battle_ecs/effects/attack_math.gd")
const StatQueryScript = preload(
	"res://core/battle_ecs/status/stat_query.gd")
const DamageTransactionScript = preload(
	"res://core/battle_ecs/effects/damage_transaction.gd")
const DamageWindowHandleScript = preload(
	"res://core/battle_ecs/effects/damage_window_handle.gd")
const DamageWindowContinuationScript = preload(
	"res://core/battle_ecs/effects/damage_window_continuation.gd")
const DamageWindowWorkItemScript = preload(
	"res://core/battle_ecs/effects/damage_window_work_item.gd")


static func execute(ctx, req) -> RefCounted:
	if req == null:
		return EffectResultScript.failed(
			"perform_attack: null request", [], false)
	if int(req.amount) != 0:
		return EffectResultScript.failed(
			"perform_attack: amount must be 0 (got %d)"
			% int(req.amount), [], false)
	var p_world = ctx.world()
	var p_emitter = ctx.emitter()

	var av = req.validate_ancestry_shape()
	if not bool(av.get("ok", false)):
		return EffectResultScript.failed(
			"perform_attack: %s"
			% String(av.get("reason", "")), [], false)

	var src: int = int(req.source_entity)
	var tgt: int = int(req.target_entity)

	if not p_world.is_alive(src):
		return EffectResultScript.failed(
			"perform_attack: source not alive", [], false)
	if StatQueryScript.blocks_actions(p_world, src):
		return EffectResultScript.failed(
			"perform_attack: source blocks_actions", [], false)
	if not p_world.is_alive(tgt):
		return EffectResultScript.failed(
			"perform_attack: target not alive", [], false)
	if src == tgt:
		return EffectResultScript.failed(
			"perform_attack: source == target", [], false)
	var src_team: int = int(p_world.team_of(src))
	var tgt_team: int = int(p_world.team_of(tgt))
	if src_team < 0 or tgt_team < 0:
		return EffectResultScript.failed(
			"perform_attack: team lookup failed", [], false)
	if src_team == tgt_team:
		return EffectResultScript.failed(
			"perform_attack: same team", [], false)
	if not p_world.in_attack_range(src, tgt):
		return EffectResultScript.failed(
			"perform_attack: out of range", [], false)

	var src_run: String = String(p_world.source_run_unit_id_of(src))
	var tgt_run: String = String(p_world.target_run_unit_id_of(tgt))
	var raw_dmg: int = int(AttackMathScript.compute(
		int(p_world.attack_of(src)),
		int(p_world.defense_of(tgt))))
	var sem_tag: StringName = StringName("")
	if req != null and req.payload != null:
		var t: Variant = req.payload.get(
			EffectRequestScript.PAYLOAD_EVENT_TAG, null)
		if t != null:
			sem_tag = StringName(String(t))

	# Allocate ATTACK_RESOLVED.
	var ancestry_kind: String = String(av.get("kind", ""))
	var atk_event = null
	if ancestry_kind == EffectRequestScript.ANCESTRY_CHILD:
		atk_event = p_emitter.emit_child(
			BattleEventTypeScript.ATTACK_RESOLVED,
			int(req.parent_event_id), int(req.root_action_id),
			int(req.chain_depth) - 1,
			src, tgt, src_run, tgt_run, raw_dmg, sem_tag,
			Vector2i(-1, -1), Vector2i(-1, -1))
	else:
		atk_event = p_emitter.emit(
			BattleEventTypeScript.ATTACK_RESOLVED,
			src, tgt, src_run, tgt_run, raw_dmg, sem_tag,
			Vector2i(-1, -1), Vector2i(-1, -1))
	if atk_event == null:
		return EffectResultScript.failed(
			"perform_attack: emitter refused ATTACK_RESOLVED", [], false)

	# Create DamageTransaction and DAMAGE_STARTED.
	var tx = DamageTransactionScript.new()
	if not bool(tx.setup(src, tgt, int(raw_dmg))):
		return EffectResultScript.failed(
			"perform_attack: damage transaction setup rejected",
			[], false)

	# DAMAGE_STARTED as CHILD of ATTACK_RESOLVED. Amount =
	# base (= raw_dmg, immutable).
	var dmg_started = p_emitter.emit_child(
		BattleEventTypeScript.DAMAGE_STARTED,
		int(atk_event.event_id), int(atk_event.root_action_id),
		int(atk_event.chain_depth),
		src, tgt, src_run, tgt_run, int(raw_dmg), sem_tag,
		Vector2i(-1, -1), Vector2i(-1, -1))
	if dmg_started == null:
		return EffectResultScript.failed(
			"perform_attack: emitter refused DAMAGE_STARTED", [], false)

	# Synchronously publish public events.
	var sink: Array = ctx.event_sink()
	sink.append(atk_event)
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
	continuation.source_run_unit_id = src_run
	continuation.target_run_unit_id = tgt_run
	# B6.4c: PerformAttack carries the reaction's semantic tag
	# onto the final events (final_event_tag). The
	# DAMAGE_STARTED intent event carries it too (materialised
	# at allocation time). This preserves legacy a5dd87d parity
	# for Counterattack / AoO DAMAGE_APPLIED / UNIT_DIED tag.
	#
	# Legacy PerformAttack passed the amount and the tag
	# EXPLICITLY to the UNIT_DIED emit_child call, so the death
	# event carries dealt and sem_tag there too.
	continuation.final_event_tag = sem_tag
	continuation.died_event_tag = sem_tag
	continuation.died_amount_is_dealt = true

	var work_item = DamageWindowWorkItemScript.new(
		dmg_started, continuation, handle,
		[atk_event])  # ATTACK_RESOLVED delayed to post-commit

	# B6.4c: succeeds_with_work so the work-pump picks up the
	# window after this synchronous phase.
	return EffectResultScript.succeeded_with_work(
		[atk_event, dmg_started], [work_item], true)