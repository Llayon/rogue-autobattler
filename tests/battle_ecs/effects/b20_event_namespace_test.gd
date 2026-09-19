extends SceneTree
## Phase 3 / B2.0 — focused tests for the unified battle event
## namespace. Verifies:
##   - BattleEventType registry (frozen values, uniqueness)
##   - No local magic event-type integers in Phase-3 effects
##   - BattleSimulation owns one BattleEventEmitter; no
##     _next_event_id
##   - Emitter reset semantics across initialize()
##   - Root/child ancestry for movement / attack / battle_ended
##   - Two-simulation isolation
##   - Event ID invariants (1, 2, 3, ... monotonic)
##   - Determinism trace now includes ancestry fields

const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const BattleEventScript = preload("res://core/battle_ecs/battle_event.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const BattleResultScript = preload("res://core/battle_ecs/battle_result.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_event_type_registry_uniqueness_and_frozen_values()
	await _test_no_local_event_type_constants_in_phase3_effects()
	await _test_battle_simulation_has_no_next_event_id_member()
	await _test_battle_simulation_emits_through_single_emitter()
	await _test_emit_step_tick_carries_to_events()
	await _test_first_event_id_is_one()
	await _test_basic_attack_ancestry()
	await _test_basic_attack_root_action_id_allocated_once()
	await _test_movement_root_event()
	await _test_unit_died_parent_is_damage_applied()
	await _test_battle_ended_own_root_event()
	await _test_two_simulation_isolation()
	await _test_reinitialize_resets_event_and_root_ids()
	await _test_event_auditor_pass_against_real_battle_trace()
	print("\n=== B2.0 focused tests: %d passed, %d failed ===\n" % [_passed, _failed])
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


# === Event type registry ===

func _test_event_type_registry_uniqueness_and_frozen_values() -> void:
	print("[R1] event_type_registry_uniqueness_and_frozen_values")
	var entries: Array = BattleEventTypeScript.all_entries()
	var values: Dictionary = {}
	var expected: Dictionary = {
		"UNIT_SPAWNED": 0,
		"UNIT_DIED": 1,
		"ATTACK_RESOLVED": 2,
		"DAMAGE_APPLIED": 3,
		"BATTLE_ENDED": 4,
		"UNIT_MOVED": 5,
		"HEAL_APPLIED": 6,
		"STATUS_APPLIED": 7,
		"STATUS_REMOVED": 8,
		"STATUS_TICKED": 9,
		"STATUS_EXPIRED": 10,
	}
	for e in entries:
		var name: String = String(e[0])
		var v: int = int(e[1])
		_assert(expected.has(name), "registered name: %s" % name)
		_assert(int(expected.get(name, -1)) == v,
			"frozen value %s == %d (got %d)" % [name, int(expected.get(name, -1)), v])
		_assert(not values.has(v), "value %d unique (collision on %s)" % [v, name])
		values[v] = true
	_assert(values.size() == 11, "11 unique values total")


func _test_no_local_event_type_constants_in_phase3_effects() -> void:
	print("[R2] no_local_event_type_constants_in_phase3_effects")
	# No integer-typed local event-type constants in Phase-3
	# production effects.
	var dir: String = "res://core/battle_ecs/effects/"
	var bad: Array = []
	for f in ["heal_effect.gd", "apply_status_effect.gd", "remove_status_effect.gd"]:
		var content: String = FileAccess.get_file_as_string(dir + f)
		# Look for `const XXX: int = 6|7|8` at module scope.
		for line in content.split("\n"):
			var s: String = String(line).strip_edges()
			if s.begins_with("const ") and "int =" in s:
				for v in [6, 7, 8]:
					if ("= " + str(v)) in s:
						bad.append("%s: %s" % [f, s])
	_assert(bad.is_empty(),
		"no local event-type int constants in phase-3 effects (found: %s)" % str(bad))


# === Emitter ownership ===

func _test_battle_simulation_has_no_next_event_id_member() -> void:
	print("[O1] battle_simulation_has_no_next_event_id_member")
	var sim = BattleSimulationScript.new()
	_assert(not "_next_event_id" in sim,
		"sim has no _next_event_id field")


func _test_battle_simulation_emits_through_single_emitter() -> void:
	print("[O2] battle_simulation_emits_through_single_emitter")
	var sim = _make_sim()
	_assert(sim.is_valid(), "sim valid")
	var e = sim.emitter()
	_assert(e != null, "sim.emitter() returns the emitter")
	_assert(e is BattleEventEmitterScript, "emitter is BattleEventEmitterScript")


func _test_emit_step_tick_carries_to_events() -> void:
	print("[O3] step_tick_carries_to_events")
	var sim = _make_sim()
	sim.set_max_ticks(2)
	var evs: Array = sim.run_until_done(1000)
	for e in evs:
		_assert(int(e.tick) >= 1, "event tick >= 1 (got %d)" % int(e.tick))


# === Event ID invariants ===

func _test_first_event_id_is_one() -> void:
	print("[ID1] first_event_id_is_one")
	# B2.1: first root event_id must be exactly 1 (not >= 1).
	var sim = _make_sim()
	sim.set_max_ticks(1)
	var evs: Array = sim.run_until_done(1000)
	var first: int = -1
	for e in evs:
		if int(e.type) == BattleEventTypeScript.UNIT_MOVED or int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED:
			first = int(e.event_id)
			break
	_assert(first == 1, "first root event_id == 1 (got %d)" % first)


func _test_basic_attack_ancestry() -> void:
	print("[A1] basic_attack_ancestry_ATTACK_DAMAGE_DIED")
	var sim = _make_sim()
	sim.set_max_ticks(50)
	var evs: Array = sim.run_until_done(1000)
	var attack_ev = null
	var damage_ev = null
	var died_ev = null
	for e in evs:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED:
			attack_ev = e
		elif int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			damage_ev = e
		elif int(e.type) == BattleEventTypeScript.UNIT_DIED:
			died_ev = e
		if attack_ev and damage_ev and died_ev:
			break
	if attack_ev == null or damage_ev == null:
		_assert(false, "expected at least one attack + damage in trace")
		return
	_assert(int(attack_ev.parent_event_id) == -1,
		"ATTACK_RESOLVED parent_event_id == -1 (got %d)" % int(attack_ev.parent_event_id))
	_assert(int(attack_ev.chain_depth) == 0,
		"ATTACK_RESOLVED chain_depth == 0 (got %d)" % int(attack_ev.chain_depth))
	_assert(int(attack_ev.root_action_id) > 0,
		"ATTACK_RESOLVED root_action_id > 0 (got %d)" % int(attack_ev.root_action_id))
	_assert(int(damage_ev.parent_event_id) == int(attack_ev.event_id),
		"DAMAGE_APPLIED parent == ATTACK_RESOLVED.event_id (got %d, expected %d)" % [int(damage_ev.parent_event_id), int(attack_ev.event_id)])
	_assert(int(damage_ev.root_action_id) == int(attack_ev.root_action_id),
		"DAMAGE_APPLIED shares root_action_id with ATTACK_RESOLVED")
	_assert(int(damage_ev.chain_depth) == 1,
		"DAMAGE_APPLIED chain_depth == 1 (got %d)" % int(damage_ev.chain_depth))
	if died_ev != null:
		_assert(int(died_ev.parent_event_id) == int(damage_ev.event_id),
			"UNIT_DIED parent == DAMAGE_APPLIED.event_id")
		_assert(int(died_ev.chain_depth) == 2,
			"UNIT_DIED chain_depth == 2 (got %d)" % int(died_ev.chain_depth))


func _test_basic_attack_root_action_id_allocated_once() -> void:
	print("[A2] basic_attack_root_action_id_allocated_once")
	var sim = _make_sim()
	sim.set_max_ticks(50)
	var evs: Array = sim.run_until_done(1000)
	# Group events by root_action_id. Each root_action_id should
	# have exactly one root event.
	var roots: Dictionary = {}
	for e in evs:
		var rid: int = int(e.root_action_id)
		if rid <= 0:
			continue
		if int(e.parent_event_id) == -1:
			if not roots.has(rid):
				roots[rid] = 0
			roots[rid] = int(roots[rid]) + 1
	for rid in roots.keys():
		var n: int = int(roots[rid])
		_assert(n == 1,
			"root_action_id %d has exactly 1 root event (got %d)" % [int(rid), n])


func _test_movement_root_event() -> void:
	print("[A3] movement_root_event")
	var sim = _make_sim()
	sim.set_max_ticks(50)
	var evs: Array = sim.run_until_done(1000)
	var moves: Array = []
	for e in evs:
		if int(e.type) == BattleEventTypeScript.UNIT_MOVED:
			moves.append(e)
	if moves.is_empty():
		_assert(false, "expected at least one UNIT_MOVED to verify ancestry")
		return
	var m = moves[0]
	_assert(int(m.parent_event_id) == -1, "UNIT_MOVED parent_event_id == -1")
	_assert(int(m.chain_depth) == 0, "UNIT_MOVED chain_depth == 0")
	_assert(int(m.root_action_id) > 0, "UNIT_MOVED root_action_id > 0")


func _test_unit_died_parent_is_damage_applied() -> void:
	print("[A4] unit_died_parent_is_damage_applied")
	# B2.1 strict contract: UNIT_DIED is always a child of
	# DAMAGE_APPLIED (which is a child of ATTACK_RESOLVED).
	# No root UNIT_DIED from the BattleSimulation attack path.
	var sim = _make_sim()
	sim.set_max_ticks(100)
	var evs: Array = sim.run_until_done(1000)
	var damage_ids: Dictionary = {}
	var damage_by_id: Dictionary = {}
	var died: Array = []
	for e in evs:
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			damage_ids[int(e.event_id)] = true
			damage_by_id[int(e.event_id)] = e
		elif int(e.type) == BattleEventTypeScript.UNIT_DIED:
			died.append(e)
	if died.is_empty():
		_assert(false, "expected at least one UNIT_DIED")
		return
	for d in died:
		var pid: int = int(d.parent_event_id)
		_assert(pid > 0, "UNIT_DIED parent_event_id > 0 (got %d)" % pid)
		_assert(damage_ids.has(pid),
			"UNIT_DIED parent is a real DAMAGE_APPLIED event_id (got %d)" % pid)
		var p = damage_by_id[pid]
		_assert(int(p.type) == BattleEventTypeScript.DAMAGE_APPLIED,
			"UNIT_DIED parent.type == DAMAGE_APPLIED")
		_assert(int(p.root_action_id) == int(d.root_action_id),
			"UNIT_DIED shares root_action_id with its DAMAGE_APPLIED parent")
		_assert(int(d.chain_depth) == int(p.chain_depth) + 1,
			"UNIT_DIED chain_depth == parent.chain_depth + 1")


func _test_battle_ended_own_root_event() -> void:
	print("[A5] battle_ended_own_root_event")
	var sim = _make_sim()
	sim.set_max_ticks(100)
	var evs: Array = sim.run_until_done(1000)
	var ended = null
	for e in evs:
		if int(e.type) == BattleEventTypeScript.BATTLE_ENDED:
			ended = e
			break
	_assert(ended != null, "BATTLE_ENDED exists")
	if ended != null:
		_assert(int(ended.parent_event_id) == -1,
			"BATTLE_ENDED has its own root (parent=-1)")
		_assert(int(ended.chain_depth) == 0, "BATTLE_ENDED chain_depth == 0")
		_assert(int(ended.root_action_id) > 0, "BATTLE_ENDED root_action_id > 0")


# === Two-simulation isolation ===

func _test_two_simulation_isolation() -> void:
	print("[I1] two_simulation_isolation")
	var sim_a = _make_sim()
	var sim_b = _make_sim()
	# Interleave.
	sim_a.step_tick()
	sim_b.step_tick()
	sim_a.step_tick()
	sim_b.step_tick()
	# Each sim's emitter tick is the simulation's own tick count,
	# unaffected by the other.
	var a_tick: int = int(sim_a.emitter().current_tick())
	var b_tick: int = int(sim_b.emitter().current_tick())
	_assert(a_tick == 2, "sim_a emitter tick == 2 (got %d)" % a_tick)
	_assert(b_tick == 2, "sim_b emitter tick == 2 (got %d)" % b_tick)


func _test_reinitialize_resets_event_and_root_ids() -> void:
	print("[R3] reinitialize_resets_event_and_root_ids")
	var sim = _make_sim()
	sim.set_max_ticks(2)
	sim.run_until_done(1000)
	# Re-initialize and check the next event_id is 1.
	var setup = _build_setup()
	_assert(sim.initialize(setup), "second initialize succeeds")
	sim.set_max_ticks(1)
	var evs: Array = sim.run_until_done(1000)
	for e in evs:
		if int(e.parent_event_id) == -1 and int(e.chain_depth) == 0:
			_assert(int(e.event_id) == 1,
				"first root event_id after reinitialize == 1 (got %d)" % int(e.event_id))
			_assert(int(e.root_action_id) == 1,
				"first root_action_id after reinitialize == 1 (got %d)" % int(e.root_action_id))
			return
	_assert(false, "no root event found after reinitialize")


# === Auditor ===

func _test_event_auditor_pass_against_real_battle_trace() -> void:
	print("[AUD1] event_auditor_pass_against_real_battle_trace")
	var sim = _make_sim()
	sim.set_max_ticks(50)
	var evs: Array = sim.run_until_done(1000)
	var ok: bool = _audit(evs)
	_assert(ok, "auditor passes on a real BattleSimulation trace")


func _audit(evs: Array) -> bool:
	# event_id unique and strictly increasing.
	var seen: Dictionary = {}
	var prev_id: int = 0
	for e in evs:
		var id: int = int(e.event_id)
		if seen.has(id):
			return false
		seen[id] = true
		if id != prev_id + 1:
			return false
		prev_id = id
	# root invariants + child invariants.
	var by_id: Dictionary = {}
	for e in evs:
		by_id[int(e.event_id)] = e
	for e in evs:
		var id: int = int(e.event_id)
		if int(e.parent_event_id) == -1:
			if int(e.chain_depth) != 0:
				return false
			if int(e.root_action_id) <= 0:
				return false
		else:
			var pid: int = int(e.parent_event_id)
			if not by_id.has(pid):
				return false
			var p = by_id[pid]
			if int(p.root_action_id) != int(e.root_action_id):
				return false
			if int(e.chain_depth) != int(p.chain_depth) + 1:
				return false
	return true


# === Helpers ===

func _build_setup() -> BattleSetupScript:
	# Place units far enough apart that the player must move at
	# least once before attacking. Range is 1, so (0,1) vs (0,3)
	# forces movement.
	var p = BattleUnitSetupScript.new("p", &"warrior", 0, Vector2i(0, 0), 80, 80, 20, 5, 1)
	var e1 = BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 3), 80, 80, 20, 5, 1)
	return BattleSetupScript.new(42, [p], [e1], 7, 4)


func _make_sim() -> BattleSimulationScript:
	var sim = BattleSimulationScript.new()
	sim.initialize(_build_setup())
	return sim
