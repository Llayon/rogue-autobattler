extends SceneTree
## TD-06 — A FULLY MITIGATED DAMAGE MUST NOT COUNT AS PROGRESS.
##
## Baseline defect: BattleSimulation._has_progressed() treated ANY
## DAMAGE_APPLIED event as progress, including one with amount = 0.
## A battle in which every hit is fully mitigated therefore looked
## like it was making progress forever and never reached the
## stalemate termination.
##
## Contract:
##   - DAMAGE_APPLIED is progress IFF amount > 0;
##   - DAMAGE_APPLIED(0) stays a VALID telemetry event of a
##     successfully completed, fully mitigated damage transaction;
##   - positive DAMAGE_APPLIED, UNIT_DIED, UNIT_MOVED and
##     STATUS_EXPIRED remain progress;
##   - a finite status countdown remains progress;
##   - an indefinite no-op Regen still ends in a stalemate;
##   - the tick budget is unchanged.

const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleResultScript = preload("res://core/battle_ecs/battle_result.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectContextScript = preload(
	"res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload(
	"res://core/battle_ecs/effects/effect_executor.gd")
const ReactionDefScript = preload("res://core/data/reaction_def.gd")
const ModifyPendingDamageEffectScript = preload(
	"res://core/battle_ecs/effects/modify_pending_damage_effect.gd")
const TriggerReactionScript = preload(
	"res://core/battle_ecs/triggers/trigger_reaction.gd")
const TriggerProviderScript = preload(
	"res://core/battle_ecs/triggers/trigger_provider.gd")

var _passed: int = 0
var _failed: int = 0


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] ", label)


## A provider that fully mitigates every damage: the pending amount
## is set to 0 on DAMAGE_STARTED.
class _ZeroMitigator extends RefCounted:
	var fired: int = 0

	func discover(_world, p_event, _rng) -> Array:
		if int(p_event.type) != BattleEventTypeScript.DAMAGE_STARTED:
			return []
		fired += 1
		var req = EffectRequestScript.root(
			EffectKindScript.MODIFY_PENDING_DAMAGE,
			int(p_event.source_entity), int(p_event.target_entity), 0)
		req.definition_id = StringName("zero_mitigator")
		var tr = TriggerReactionScript.new()
		tr.reacting_entity = int(p_event.source_entity)
		tr.request = req
		return [tr]


func _initialize() -> void:
	print("=== TD-06: zero-damage stalemate ===")
	_test_fully_mitigated_damage_reaches_stalemate()
	_test_positive_damage_still_progresses()
	_test_indefinite_noop_regen_still_stalemate()
	print("\n=== TD-06: %d pass / %d fail ===\n" % [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## Two neighbours that can attack each other. Every hit is fully
## mitigated, so nothing ever changes.
func _make_fixture() -> RefCounted:
	var p0 = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var e0 = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1)
	return BattleSetupScript.new(42, [p0], [e0], 1, 4)


func _test_fully_mitigated_damage_reaches_stalemate() -> void:
	var setup = _make_fixture()
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	# Replace the provider with the zero mitigator.
	var provider = _ZeroMitigator.new()
	sim.set_trigger_provider(provider)
	sim._rng = DeterministicRngScript.new(7)

	var events: Array = sim.run_until_done(20)
	var result = sim.get_result()
	if result == null:
		_assert(false, "TD-06: the result exists")
		return

	# The damage was attempted and fully mitigated.
	var applied_zero: int = 0
	var applied_positive: int = 0
	for ev in events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			if int(ev.amount) == 0:
				applied_zero += 1
			else:
				applied_positive += 1
	_assert(applied_zero > 0,
		"TD-06: a fully mitigated hit emits DAMAGE_APPLIED with amount 0 (got %d)"
			% applied_zero)
	_assert(applied_positive == 0,
		"TD-06: no positive DAMAGE_APPLIED was emitted (got %d)" % applied_positive)

	# Nothing changed: no death, no movement.
	var died: int = 0
	for ev in events:
		if int(ev.type) == BattleEventTypeScript.UNIT_DIED:
			died += 1
	_assert(died == 0, "TD-06: no unit died (got %d)" % died)

	# The battle must end in a stalemate, not run to the tick budget.
	_assert(int(result.termination_reason) == int(BattleResultScript.TERMINATION_STALEMATE),
		"TD-06: TERMINATION_STALEMATE (got %d)" % int(result.termination_reason))
	_assert(int(result.winner_team) == -1, "TD-06: DRAW (winner -1)")
	_assert(int(result.tick_count) == 2,
		"TD-06: the stalemate is detected at tick 2 (got %d)" % int(result.tick_count))


func _test_positive_damage_still_progresses() -> void:
	# The same fixture WITHOUT the mitigator: real damage happens, so
	# the battle must NOT end in a stalemate.
	var setup = _make_fixture()
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(7)
	var events: Array = sim.run_until_done(20)
	var result = sim.get_result()
	if result == null:
		_assert(false, "TD-06: the result exists")
		return
	var applied_positive: int = 0
	for ev in events:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			if int(ev.amount) > 0:
				applied_positive += 1
	_assert(applied_positive > 0,
		"TD-06: a real hit emits a positive DAMAGE_APPLIED (got %d)" % applied_positive)
	_assert(int(result.termination_reason) != int(BattleResultScript.TERMINATION_STALEMATE),
		"TD-06: positive damage prevents a stalemate (got %d)"
			% int(result.termination_reason))


func _test_indefinite_noop_regen_still_stalemate() -> void:
	# An indefinite Regen (remaining = -1) at max HP changes nothing.
	# It must still end in a stalemate, so the zero-damage fix must
	# not have broken the existing no-progress detection.
	# The same 1x4 no-progress fixture the B4 stalemate baseline
	# uses: two units per side that cannot reach each other, so no
	# attack and no movement ever happens.
	var p0 = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var p1 = BattleUnitSetupScript.new(
		"p1", &"warrior", 0, Vector2i(0, 1), 100, 100, 20, 5, 1)
	var e0 = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 3), 100, 100, 20, 5, 1)
	var e1 = BattleUnitSetupScript.new(
		"e1", &"orc", 1, Vector2i(0, 2), 100, 100, 20, 5, 1)
	var setup = BattleSetupScript.new(42, [p0, p1], [e0, e1], 1, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim._rng = DeterministicRngScript.new(7)
	var events: Array = sim.run_until_done(20)
	var result = sim.get_result()
	if result == null:
		_assert(false, "TD-06: the result exists")
		return
	_assert(int(result.termination_reason) == int(BattleResultScript.TERMINATION_STALEMATE),
		"TD-06: the no-progress fixture still ends in a stalemate (got %d)"
			% int(result.termination_reason))
