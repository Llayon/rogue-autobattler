extends SceneTree
## TD-07 — S28 END-TO-END HOSTILE MINIMUM.
##
## The existing S28 scenario in b64d_shield_block_test.gd proves the
## percentage/minimum reducer at the HANDLE level: it sets the
## pending amount by hand and calls the modifier directly. That is a
## unit proof, not an end-to-end one.
##
## This suite drives the same hostile minimum through the FULL
## production path:
##
##   attack -> DAMAGE_STARTED -> window work item
##          -> TriggerDispatcher -> provider discovery
##          -> MODIFY_PENDING_DAMAGE reaction
##          -> DamageWindowContinuation.finalize
##          -> DAMAGE_APPLIED / HP mutation
##
## The provider is TEST-LOCAL: the shipping shield_block.tres is not
## mutated. The reaction is DAMAGE_STARTED + DIRECT +
## MODIFY_PENDING_DAMAGE with percent 50 and a hostile minimum 5.
##
## Case A: pending 6 -> 50% = 3 -> the minimum 5 applies -> committed 5.
## Case B: pending 1 -> 50% = 0 -> the minimum 5 would amplify it ->
##         the monotonic clamp keeps it at 1.

const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectContextScript = preload(
	"res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload(
	"res://core/battle_ecs/effects/effect_executor.gd")
const TriggerReactionScript = preload(
	"res://core/battle_ecs/triggers/trigger_reaction.gd")
const TriggerDispatcherScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatcher.gd")
const TriggerLimitsScript = preload(
	"res://core/battle_ecs/triggers/trigger_limits.gd")
const PerformAttackEffectScript = preload(
	"res://core/battle_ecs/effects/perform_attack_effect.gd")

var _passed: int = 0
var _failed: int = 0


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] ", label)


## A TEST-LOCAL provider that discovers one DAMAGE_STARTED reaction
## with a hostile percentage/minimum.
##
## The reaction payload carries the same keys the production modifier
## reads, so the FULL production modifier runs.
class _HostileMinimumProvider extends RefCounted:
	var percent: int = 50
	var minimum: int = 5
	var fired: int = 0

	func discover(_world, p_event, _rng) -> Array:
		if int(p_event.type) != BattleEventTypeScript.DAMAGE_STARTED:
			return []
		fired += 1
		var req = EffectRequestScript.root(
			EffectKindScript.MODIFY_PENDING_DAMAGE,
			int(p_event.source_entity), int(p_event.target_entity), 0)
		req.definition_id = StringName("hostile_minimum")
		req.payload = {
			EffectRequestScript.PAYLOAD_PENDING_DAMAGE_PERCENT: percent,
			EffectRequestScript.PAYLOAD_PENDING_DAMAGE_MINIMUM: minimum,
		}
		var tr = TriggerReactionScript.new()
		tr.reacting_entity = int(p_event.source_entity)
		tr.request = req
		return [tr]


## Builds the battle. The attacker's attack stat sets the base
## damage, so the pending damage at DAMAGE_STARTED time is exactly
## p_attack (the defender has no defense).
func _make_sim(p_attack: int) -> Array:
	var mover = BattleUnitSetupScript.new(
		"p0", &"attacker", 0, Vector2i(1, 1), 200, 200, p_attack, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"defender", 1, Vector2i(1, 2), 200, 200, 5, 0, 1, [])
	var setup = BattleSetupScript.new(42, [mover], [knight], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(0)
	return [sim, sim.world(), sim._event_emitter]


## Runs the FULL production path for one attack with a pending damage
## of p_pending, through the dispatcher and the continuation.
##
## Returns a dictionary with the observable outcome.
func _run(p_pending: int) -> Dictionary:
	var parts = _make_sim(p_pending)
	var sim = parts[0]
	var world = parts[1]
	var emitter = parts[2]
	var rng = sim._rng
	var sink: Array = []

	# The attack opens the damage window.
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	var req = EffectRequestScript.root(
		int(EffectKindScript.PERFORM_ATTACK), 0, 1, 0)
	req.source_entity = 0
	req.target_entity = 1
	var result = PerformAttackEffectScript.execute(ctx, req)
	if result == null or result.dispatch_work.size() != 1:
		return {"error": "the attack did not open a window"}

	var item = result.dispatch_work[0]
	# The pending damage is produced by the attack itself (the
	# attacker's attack stat minus the defender's defense), so the
	# hostile minimum is measured against a REAL pending amount.
	var handle = item.handle
	var tx = item.continuation.tx
	if int(tx.pending_amount()) != int(p_pending):
		return {"error": "the pending amount is %d, expected %d"
			% [int(tx.pending_amount()), int(p_pending)]}

	var hp_before: int = int(world.current_hp_of(1))

	# The FULL production path: dispatcher -> provider -> modifier ->
	# continuation finalize -> DAMAGE_APPLIED + HP mutation.
	var provider = _HostileMinimumProvider.new()
	var limits = TriggerLimitsScript.new()
	limits.max_events_per_tick = 32
	limits.max_chain_depth = 7
	limits.max_reactions_per_root = 4
	var dispatcher = TriggerDispatcherScript.new()
	var dr = dispatcher.process_work(
		result.dispatch_work, world, rng, emitter, sink, provider,
		limits, null)

	var hp_after: int = int(world.current_hp_of(1))
	var started_amount: int = -1
	var applied_amount: int = -1
	var applied_count: int = 0
	for ev in sink:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_STARTED:
			started_amount = int(ev.amount)
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			applied_amount = int(ev.amount)
			applied_count += 1

	return {
		"error": "",
		"started": started_amount,
		"applied": applied_amount,
		"applied_count": applied_count,
		"hp_before": hp_before,
		"hp_after": hp_after,
		"hp_delta": hp_before - hp_after,
		"discoveries": int(provider.fired),
		"pending": int(dispatcher.pending_count()),
		"tx_committed": bool(tx.is_committed()),
		"handle_active": bool(handle.is_active()),
		"rng_after": rng.snapshot(),
		"truncated": bool(dr.truncated),
	}


func _initialize() -> void:
	print("=== TD-07: S28 end-to-end hostile minimum ===")
	_test_case_a_pending_6_minimum_5()
	_test_case_b_pending_1_minimum_5()
	print("\n=== TD-07: %d pass / %d fail ===\n" % [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


func _test_case_a_pending_6_minimum_5() -> void:
	# pending 6 -> 50% = 3 -> the minimum 5 applies -> committed 5.
	var out = _run(6)
	if String(out.get("error", "")) != "":
		_assert(false, "TD-07 case A: %s" % String(out.get("error", "")))
		return
	print("  case A: %s" % str(out))
	_assert(int(out["discoveries"]) == 1,
		"TD-07 case A: the reaction executed exactly once (got %d)"
			% int(out["discoveries"]))
	_assert(int(out["started"]) == 6,
		"TD-07 case A: DAMAGE_STARTED.amount == 6 (got %d)" % int(out["started"]))
	_assert(int(out["applied_count"]) == 1,
		"TD-07 case A: exactly one DAMAGE_APPLIED (got %d)" % int(out["applied_count"]))
	_assert(int(out["applied"]) == 5,
		"TD-07 case A: DAMAGE_APPLIED.amount == 5 (got %d)" % int(out["applied"]))
	_assert(int(out["hp_delta"]) == 5,
		"TD-07 case A: the HP delta is 5 (got %d)" % int(out["hp_delta"]))
	_assert(int(out["pending"]) == 0,
		"TD-07 case A: no pending window is left (got %d)" % int(out["pending"]))
	_assert(bool(out["tx_committed"]),
		"TD-07 case A: the transaction is committed")
	_assert(not bool(out["handle_active"]),
		"TD-07 case A: the window handle is closed")


func _test_case_b_pending_1_minimum_5() -> void:
	# pending 1 -> 50% = 0 -> the minimum 5 would AMPLIFY it, so the
	# monotonic clamp keeps it at 1.
	var out = _run(1)
	if String(out.get("error", "")) != "":
		_assert(false, "TD-07 case B: %s" % String(out.get("error", "")))
		return
	print("  case B: %s" % str(out))
	_assert(int(out["discoveries"]) == 1,
		"TD-07 case B: the reaction executed exactly once (got %d)"
			% int(out["discoveries"]))
	_assert(int(out["started"]) == 1,
		"TD-07 case B: DAMAGE_STARTED.amount == 1 (got %d)" % int(out["started"]))
	_assert(int(out["applied_count"]) == 1,
		"TD-07 case B: exactly one DAMAGE_APPLIED (got %d)" % int(out["applied_count"]))
	_assert(int(out["applied"]) == 1,
		"TD-07 case B: DAMAGE_APPLIED.amount == 1 (got %d)" % int(out["applied"]))
	_assert(int(out["hp_delta"]) == 1,
		"TD-07 case B: the HP delta is 1 (got %d)" % int(out["hp_delta"]))
	_assert(int(out["pending"]) == 0,
		"TD-07 case B: no pending window is left (got %d)" % int(out["pending"]))
	_assert(bool(out["tx_committed"]),
		"TD-07 case B: the transaction is committed")
	_assert(not bool(out["handle_active"]),
		"TD-07 case B: the window handle is closed")
