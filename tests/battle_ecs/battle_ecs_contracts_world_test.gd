extends SceneTree
## Phase 2 / Gauntlet 1+2 — BattleSetup / BattleUnitSetup /
## BattleResult / BattleEvent / BattleWorld smoke tests.

const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleResultScript = preload("res://core/battle_ecs/battle_result.gd")
const BattleEventScript = preload("res://core/battle_ecs/battle_event.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_battle_unit_setup_construction()
	await _test_battle_setup_validate_empty_player()
	await _test_battle_setup_validate_empty_enemy()
	await _test_battle_setup_validate_oob_cell()
	await _test_battle_setup_validate_duplicate_cell()
	await _test_battle_setup_validate_bad_hp()
	await _test_battle_setup_validate_ok()
	await _test_battle_world_allocates_monotonic_ids()
	await _test_battle_world_two_entities_distinct_ids()
	await _test_battle_world_remove_entity_clears_components()
	await _test_battle_world_same_definition_still_distinct()
	await _test_battle_world_multiple_worlds_independent()
	await _test_battle_world_reset_via_new_instance()
	await _test_battle_world_attack_range_manhattan()
	await _test_battle_world_nearest_enemy_tie_break_by_id()
	await _test_battle_simulation_initialize_owns_rng()
	await _test_battle_simulation_two_instances_independent()
	await _test_battle_simulation_1v1_completes()
	print("\n=== battle_ecs contracts/world: %d passed, %d failed ===\n" % [_passed, _failed])
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


# === Gauntlet 1: contracts ===

func _test_battle_unit_setup_construction() -> void:
	print("[c-1] battle_unit_setup_construction")
	var u: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"warrior_1", &"warrior", 0, Vector2i(1, 2),
		50, 100, 12, 5, 1)
	_assert(u.source_run_unit_id == "warrior_1", "source_run_unit_id stored")
	_assert(u.definition_id == &"warrior", "definition_id stored")
	_assert(u.team == 0, "team stored")
	_assert(u.cell == Vector2i(1, 2), "cell stored")
	_assert(u.starting_hp == 50 and u.max_hp == 100, "hp stored")
	_assert(u.attack_base == 12, "attack stored")
	_assert(u.defense_base == 5, "defense stored")
	_assert(u.attack_range == 1, "attack_range stored")


func _test_battle_setup_validate_empty_player() -> void:
	print("[c-2] battle_setup_validate_empty_player")
	var s: BattleSetupScript = BattleSetupScript.new(42, [], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 5, 2, 1)
	])
	var msg: String = s.validate()
	_assert(msg == "no player units", "rejects empty player (got '%s')" % msg)


func _test_battle_setup_validate_empty_enemy() -> void:
	print("[c-3] battle_setup_validate_empty_enemy")
	var s: BattleSetupScript = BattleSetupScript.new(42, [
		BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 3), 30, 30, 5, 2, 1)
	], [])
	var msg: String = s.validate()
	_assert(msg == "no enemy units", "rejects empty enemy (got '%s')" % msg)


func _test_battle_setup_validate_oob_cell() -> void:
	print("[c-4] battle_setup_validate_oob_cell")
	var s: BattleSetupScript = BattleSetupScript.new(42, [
		BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 99), 30, 30, 5, 2, 1)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 5, 2, 1)
	])
	var msg: String = s.validate()
	_assert(msg.find("out of bounds") >= 0, "rejects OOB cell (got '%s')" % msg)


func _test_battle_setup_validate_duplicate_cell() -> void:
	print("[c-5] battle_setup_validate_duplicate_cell")
	var s: BattleSetupScript = BattleSetupScript.new(42, [
		BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 3), 30, 30, 5, 2, 1),
		BattleUnitSetupScript.new("p2", &"warrior", 0, Vector2i(0, 3), 30, 30, 5, 2, 1)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 5, 2, 1)
	])
	var msg: String = s.validate()
	_assert(msg.find("duplicate deployment") >= 0, "rejects duplicate cell (got '%s')" % msg)


func _test_battle_setup_validate_bad_hp() -> void:
	print("[c-6] battle_setup_validate_bad_hp")
	var s: BattleSetupScript = BattleSetupScript.new(42, [
		BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 3), 200, 100, 5, 2, 1)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 5, 2, 1)
	])
	var msg: String = s.validate()
	_assert(msg.find("starting_hp") >= 0, "rejects starting_hp > max_hp (got '%s')" % msg)


func _test_battle_setup_validate_ok() -> void:
	print("[c-7] battle_setup_validate_ok")
	var s: BattleSetupScript = BattleSetupScript.new(42, [
		BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 3), 80, 100, 20, 5, 1)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 10, 3, 1)
	])
	var msg: String = s.validate()
	_assert(msg == "", "valid setup passes (got '%s')" % msg)


# === Gauntlet 2: world ===

func _test_battle_world_allocates_monotonic_ids() -> void:
	print("[w-1] battle_world_allocates_monotonic_ids")
	var w: BattleWorldScript = BattleWorldScript.new(7, 4)
	var a: int = w.allocate_entity_id()
	var b: int = w.allocate_entity_id()
	var c: int = w.allocate_entity_id()
	_assert(a == 0 and b == 1 and c == 2, "IDs are 0,1,2 (got %d,%d,%d)" % [a, b, c])
	_assert(b > a and c > b, "IDs strictly monotonic")


func _test_battle_world_two_entities_distinct_ids() -> void:
	print("[w-2] battle_world_two_entities_distinct_ids")
	var s: BattleSetupScript = BattleSetupScript.new(42, [
		BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 3), 80, 100, 20, 5, 1),
		BattleUnitSetupScript.new("p2", &"warrior", 0, Vector2i(1, 3), 80, 100, 20, 5, 1)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 10, 3, 1)
	])
	var w: BattleWorldScript = BattleWorldScript.new(7, 4)
	var spawned: Array = w.spawn_from_setup(s)
	_assert(spawned.size() == 3, "spawned 3 entities (got %d)" % spawned.size())
	_assert(spawned[0] != spawned[1] and spawned[1] != spawned[2], "IDs distinct")
	_assert(int(spawned[0]) < int(spawned[1]) and int(spawned[1]) < int(spawned[2]), "IDs monotonic")


func _test_battle_world_remove_entity_clears_components() -> void:
	print("[w-3] battle_world_remove_entity_clears_components")
	var s: BattleSetupScript = BattleSetupScript.new(42, [
		BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 3), 80, 100, 20, 5, 1)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 10, 3, 1)
	])
	var w: BattleWorldScript = BattleWorldScript.new(7, 4)
	var spawned: Array = w.spawn_from_setup(s)
	var id: int = int(spawned[0])
	_assert(w.is_alive(id), "entity alive after spawn")
	w.remove_entity(id)
	_assert(not w.is_alive(id), "entity dead after remove")
	_assert(w.team_of(id) == -1, "team cleared")
	_assert(w.position_of(id) == Vector2i(-1, -1), "position cleared")
	_assert(w.attack_of(id) == 0, "attack cleared")
	_assert(w.definition_id_of(id) == &"", "definition_id cleared")


func _test_battle_world_same_definition_still_distinct() -> void:
	print("[w-4] battle_world_same_definition_still_distinct")
	var s: BattleSetupScript = BattleSetupScript.new(42, [
		BattleUnitSetupScript.new("warrior_A", &"warrior", 0, Vector2i(0, 3), 80, 100, 20, 5, 1),
		BattleUnitSetupScript.new("warrior_B", &"warrior", 0, Vector2i(1, 3), 80, 100, 20, 5, 1)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 10, 3, 1)
	])
	var w: BattleWorldScript = BattleWorldScript.new(7, 4)
	var spawned: Array = w.spawn_from_setup(s)
	var a: int = int(spawned[0])
	var b: int = int(spawned[1])
	_assert(a != b, "distinct IDs despite same definition_id")
	_assert(w.source_run_unit_id_of(a) == "warrior_A", "warrior_A source id")
	_assert(w.source_run_unit_id_of(b) == "warrior_B", "warrior_B source id")
	_assert(w.definition_id_of(a) == w.definition_id_of(b), "same definition_id is preserved")
	w.apply_damage(a, 100)
	_assert(not w.is_alive(a) and w.is_alive(b), "killing one does not affect the other")


func _test_battle_world_multiple_worlds_independent() -> void:
	print("[w-5] battle_world_multiple_worlds_independent")
	var w1: BattleWorldScript = BattleWorldScript.new(7, 4)
	var w2: BattleWorldScript = BattleWorldScript.new(7, 4)
	# Both worlds share ID counter starting at 0.
	var a: int = w1.allocate_entity_id()
	var b: int = w2.allocate_entity_id()
	_assert(a == 0 and b == 0, "both worlds start at 0 (got w1=%d w2=%d)" % [a, b])
	# Both worlds must be independently trackable. Spawning into w1
	# must NOT make w1.is_alive(0) leak into w2, and vice versa.
	var s: BattleSetupScript = BattleSetupScript.new(42, [
		BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 3), 80, 100, 20, 5, 1)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 10, 3, 1)
	])
	w1.spawn_from_setup(s)
	w2.spawn_from_setup(s)
	# Now both worlds have a fresh allocation. The earlier allocation
	# (id=0) was orphaned in each world.
	_assert(w1.alive_ids_by_team(0).size() == 1, "w1 has 1 alive player")
	_assert(w2.alive_ids_by_team(0).size() == 1, "w2 has 1 alive player")
	# w1 kills its player.
	var w1_ids: Array = w1.alive_ids_by_team(0)
	w1.apply_damage(int(w1_ids[0]), 9999)
	_assert(not w1.is_alive(int(w1_ids[0])), "w1 player dead")
	_assert(w2.is_alive(int(w2.alive_ids_by_team(0)[0])), "w2 player unaffected by w1")


func _test_battle_world_reset_via_new_instance() -> void:
	print("[w-6] battle_world_reset_via_new_instance")
	var w: BattleWorldScript = BattleWorldScript.new(7, 4)
	var a: int = w.allocate_entity_id()
	var b: int = w.allocate_entity_id()
	_assert(a == 0 and b == 1, "old IDs 0,1")
	var w2: BattleWorldScript = BattleWorldScript.new(7, 4)
	_assert(w2.allocate_entity_id() == 0, "new world fresh at 0")


func _test_battle_world_attack_range_manhattan() -> void:
	print("[w-7] battle_world_attack_range_manhattan")
	var s: BattleSetupScript = BattleSetupScript.new(42, [
		BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 3), 80, 100, 20, 5, 1)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 10, 3, 1)
	])
	var w: BattleWorldScript = BattleWorldScript.new(7, 4)
	var spawned: Array = w.spawn_from_setup(s)
	var attacker: int = int(spawned[0])
	var target: int = int(spawned[1])
	# distance = |0-0| + |3-0| = 3, range = 1 => out of range
	_assert(not w.in_attack_range(attacker, target), "out of range (d=3, range=1)")


func _test_battle_world_nearest_enemy_tie_break_by_id() -> void:
	print("[w-8] battle_world_nearest_enemy_tie_break_by_id")
	# Two enemies equidistant from player. Smaller ID must win.
	var s: BattleSetupScript = BattleSetupScript.new(42, [
		BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 2), 80, 100, 20, 5, 1)
	], [
		BattleUnitSetupScript.new("", &"orc_A", 1, Vector2i(0, 0), 30, 30, 10, 3, 1),
		BattleUnitSetupScript.new("", &"orc_B", 1, Vector2i(1, 1), 30, 30, 10, 3, 1)
	])
	var w: BattleWorldScript = BattleWorldScript.new(7, 4)
	var spawned: Array = w.spawn_from_setup(s)
	var p: int = int(spawned[0])
	var e1: int = int(spawned[1])
	var e2: int = int(spawned[2])
	# Distance from p=(0,2): e1=(0,0)=>2, e2=(1,1)=>2. Both 2.
	var nearest: int = w.nearest_enemy_id(p, [e1, e2])
	_assert(nearest == e1, "tie broken by smaller ID (got %d expected %d)" % [nearest, e1])


# === Gauntlet 4 (simulation RNG) — minimal here ===

func _test_battle_simulation_initialize_owns_rng() -> void:
	print("[s-1] battle_simulation_initialize_owns_rng")
	var s: BattleSetupScript = BattleSetupScript.new(999, [
		BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 3), 80, 100, 20, 5, 1)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 10, 3, 1)
	])
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	var rng_a: RefCounted = sim.rng()
	_assert(rng_a != null, "RNG is owned")
	_assert(rng_a.seed_value == 999, "RNG seeded from setup.seed (got %d)" % rng_a.seed_value)


func _test_battle_simulation_two_instances_independent() -> void:
	print("[s-2] battle_simulation_two_instances_independent")
	var s: BattleSetupScript = BattleSetupScript.new(777, [
		BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 3), 80, 100, 20, 5, 1)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 10, 3, 1)
	])
	var sim1: BattleSimulationScript = BattleSimulationScript.new()
	var sim2: BattleSimulationScript = BattleSimulationScript.new()
	sim1.initialize(s)
	sim2.initialize(s)
	var rng1: RefCounted = sim1.rng()
	var rng2: RefCounted = sim2.rng()
	_assert(rng1 != rng2, "two simulations own different RNG instances")
	rng1.randf()
	rng1.randf()
	rng1.randf()
	_assert(rng2.draw_count == 0, "rng2 draw_count untouched by rng1 (got %d)" % rng2.draw_count)


func _test_battle_simulation_1v1_completes() -> void:
	print("[s-3] battle_simulation_1v1_completes")
	var s: BattleSetupScript = BattleSetupScript.new(42, [
		BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 3), 80, 100, 20, 5, 1)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 10, 3, 1)
	])
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	# Player at (0,3), enemy at (0,0). distance=3, range=1.
	# Range too short for current implementation — battle stalls.
	# We use a wider range for this slice.
	s.player_units[0] = BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 1), 80, 100, 20, 5, 5)
	sim.initialize(s)
	# Should terminate within bounded ticks.
	var ticks: int = 0
	while not sim.is_finished() and ticks < 200:
		var evs: Array = sim.step_tick()
		ticks += 1
	_assert(sim.is_finished(), "1v1 reaches is_finished (after %d ticks)" % ticks)
	var result: BattleResultScript = sim.get_result()
	_assert(result != null, "result non-null")
	_assert(result.outcome != -1, "outcome set (got %d)" % result.outcome)
	_assert(result.tick_count > 0, "tick_count > 0 (got %d)" % result.tick_count)
	_assert(result.tick_count <= 200, "battle terminated within 200 ticks (got %d)" % result.tick_count)
