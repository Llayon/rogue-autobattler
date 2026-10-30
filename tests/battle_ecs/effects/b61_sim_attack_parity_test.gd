extends SceneTree
## B6.1.1 sim characterization.
##
## Two responsibilities kept distinct:
##   1. _test_explicit_normal_attack_characterization — proves
##      that for a single-tick adjacent fixture, the FIRST
##      player ATTACK_RESOLVED and player DAMAGE_APPLIED match
##      expected entity/run-unit/ancestry/amount semantics. The
##      enemy scheduled action (if it lands in the same tick) is
##      also characterized.
##   2. _test_two_run_determinism_equality — proves that two
##      independent runs of the same fixture produce
##      element-by-element identical 14-field normalized traces.
##      This is DETERMINISM, NOT pre/post parity.
##
## The previous single test (which conflated the two) is
## split. Per the B6.1.1 spec, the historical pre/post parity
## claim must not be made here — B6.1 already landed; the
## canonical attack path is in production.

const BattleSimulationScript = preload(
	"res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload(
	"res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload(
	"res://core/battle_ecs/battle_unit_setup.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const ContentDBScript = preload(
	"res://core/utils/content_db.gd")
const DamageBridgeScript = preload(
	"res://tests/battle_ecs/effects/b64c_damage_bridge.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	await _test_explicit_normal_attack_characterization()
	await _test_two_run_determinism_equality()
	print("\n=== B6.1.1 sim characterization: %d pass / %d fail ===\n" % [_passed, _failed])
	if _failed > 0:
		quit(1)
	quit(0)


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  [OK]   %s" % label)
	else:
		_failed += 1
		print("  [FAIL] %s" % label)


func _make_sim() -> RefCounted:
	var sim = BattleSimulationScript.new()
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 3)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1)],
		7, 4)
	sim.initialize(s)
	return sim


# ============================================================
# 1) explicit characterization — what the trace MUST look like
# ============================================================
func _test_explicit_normal_attack_characterization() -> void:
	print("[B61-SIM-CHAR] explicit_normal_attack_characterization")
	var sim: RefCounted = _make_sim()
	# Use set_max_ticks so the run terminates predictably.
	sim.set_max_ticks(3)
	var events: Array = []
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	_assert(events.size() >= 2,
		"trace contains the player attack pair (got %d events)"
		% events.size())
	if events.size() < 2:
		return
	# First event: player ATTACK_RESOLVED.
	var p_atk = events[0]
	_assert(int(p_atk.type) == BattleEventTypeScript.ATTACK_RESOLVED,
		"events[0].type == ATTACK_RESOLVED")
	_assert(int(p_atk.source_entity) == 0,
		"events[0].source_entity == 0 (player)")
	_assert(int(p_atk.target_entity) == 1,
		"events[0].target_entity == 1 (enemy)")
	_assert(String(p_atk.source_run_unit_id) == "p0",
		"events[0].source_run_unit_id == 'p0'")
	_assert(String(p_atk.target_run_unit_id) == "e0",
		"events[0].target_run_unit_id == 'e0'")
	_assert(int(p_atk.parent_event_id) == -1,
		"events[0].parent_event_id == -1 (root)")
	_assert(int(p_atk.chain_depth) == 0,
		"events[0].chain_depth == 0 (root)")
	_assert(int(p_atk.amount) > 0,
		"events[0].amount > 0 (raw attack damage)")
	# B6.4c: the pre-damage window inserts DAMAGE_STARTED between
	# the attack intent and the damage commit:
	#   ATTACK_RESOLVED -> DAMAGE_STARTED -> DAMAGE_APPLIED
	# The full bridge is proven by the shared helper.
	var bridge: Dictionary = DamageBridgeScript.assert_attack_damage_bridge(
		events, p_atk, "sim attack parity", _assert)
	var p_dmg = bridge.get("applied", null)
	_assert(p_dmg != null, "player DAMAGE_APPLIED committed")
	if p_dmg == null:
		return
	_assert(int(p_dmg.source_entity) == 0,
		"damage.source_entity == 0 (player)")
	_assert(int(p_dmg.target_entity) == 1,
		"damage.target_entity == 1 (enemy)")
	_assert(String(p_dmg.source_run_unit_id) == "p0",
		"damage.source_run_unit_id == 'p0'")
	_assert(String(p_dmg.target_run_unit_id) == "e0",
		"damage.target_run_unit_id == 'e0'")
	_assert(int(p_dmg.amount) > 0,
		"damage.amount > 0 (actual HP removed)")
	# damage.amount <= attack.amount (HP cap invariant).
	_assert(int(p_dmg.amount) <= int(p_atk.amount),
		"damage.amount (actual) <= attack.amount (raw) "
		+ "[%d <= %d]" % [int(p_dmg.amount), int(p_atk.amount)])


# ============================================================
# 2) determinism — two independent runs produce same trace
# ============================================================
func _normalize_14(e) -> Dictionary:
	return {
		"event_id": int(e.event_id),
		"type": int(e.type),
		"tick": int(e.tick),
		"source_entity": int(e.source_entity),
		"target_entity": int(e.target_entity),
		"source_run_unit_id": String(e.source_run_unit_id),
		"target_run_unit_id": String(e.target_run_unit_id),
		"amount": int(e.amount),
		"tag": String(e.tag),
		"from_cell": str(e.from_cell),
		"to_cell": str(e.to_cell),
		"parent_event_id": int(e.parent_event_id),
		"root_action_id": int(e.root_action_id),
		"chain_depth": int(e.chain_depth),
	}

func _run_until_finished() -> Array:
	var sim: RefCounted = _make_sim()
	sim.set_max_ticks(5)
	var events: Array = []
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	return events

func _test_two_run_determinism_equality() -> void:
	print("[B61-SIM-DET] two_run_determinism_equality")
	var ev_a: Array = _run_until_finished()
	var ev_b: Array = _run_until_finished()
	_assert(ev_a.size() == ev_b.size(),
		"two runs produce same trace length (got %d vs %d)"
		% [ev_a.size(), ev_b.size()])
	# Element-by-element equality on full 14 fields.
	var n: int = mini(ev_a.size(), ev_b.size())
	for i in n:
		var fa: Dictionary = _normalize_14(ev_a[i])
		var fb: Dictionary = _normalize_14(ev_b[i])
		var ok: bool = true
		for k in fa.keys():
			if str(fa[k]) != str(fb.get(k, "<missing>")):
				ok = false
				break
		_assert(ok,
			"trace[%d] 14 fields identical across runs" % i)
	# event_ids unique within each run.
	var seen_a: Dictionary = {}
	var dup_a: Array = []
	for e in ev_a:
		var id: int = int(e.event_id)
		if seen_a.has(id):
			dup_a.append(id)
		seen_a[id] = true
	_assert(dup_a.size() == 0,
		"run A: event_ids unique (got %s)" % str(dup_a))
