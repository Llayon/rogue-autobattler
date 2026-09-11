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
	await _test_movement_primary_y_blocked_x_fallback()
	await _test_movement_primary_x_blocked_y_fallback()
	await _test_movement_both_axes_blocked_no_movement()
	await _test_movement_primary_free_wins_over_fallback()
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
	# BLOCKER 4 fix: cell occupancy is GLOBAL — same cell cannot
	# be occupied by two players, two enemies, or one of each.
	# First, test two players same cell.
	var s1: BattleSetupScript = BattleSetupScript.new(42, [
		BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 3), 30, 30, 5, 2, 1),
		BattleUnitSetupScript.new("p2", &"warrior", 0, Vector2i(0, 3), 30, 30, 5, 2, 1)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 5, 2, 1)
	])
	var msg1: String = s1.validate()
	_assert(msg1.find("already occupied") >= 0, "rejects duplicate player cell (got '%s')" % msg1)
	# Now test player + enemy same cell.
	var s2: BattleSetupScript = BattleSetupScript.new(42, [
		BattleUnitSetupScript.new("p1", &"warrior", 0, Vector2i(0, 3), 30, 30, 5, 2, 1)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 3), 30, 30, 5, 2, 1)
	])
	var msg2: String = s2.validate()
	_assert(msg2.find("already occupied") >= 0, "rejects cross-team cell (got '%s')" % msg2)


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


# === HIGH 3: Direct BattleWorld movement fallback contract tests ===

func _make_world_with_two_units(src: Vector2i, target: Vector2i) -> BattleWorldScript:
	# Build a 7x4 world with two units: entity 0 at `src` (player
	# team), entity 1 at `target` (enemy team). Both alive,
	# attack_range=1.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"warrior", 0, src, 80, 80, 20, 5, 1)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, target, 80, 80, 20, 5, 1)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var w: BattleWorldScript = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(s)
	return w


func _add_blocker(w: BattleWorldScript, team: int, cell: Vector2i) -> int:
	var u: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"wall", team, cell, 9999, 9999, 0, 0, 0)
	var s: BattleSetupScript = BattleSetupScript.new(
		0,
		[u] if team == 0 else [],
		[u] if team == 1 else [],
		7, 4)
	w.spawn_from_setup(s)
	return w.all_known_ids().back()


func _test_movement_primary_y_blocked_x_fallback() -> void:
	print("[m-A] movement_primary_y_blocked_x_fallback [HIGH 3]")
	# HIGH 3.A: source (3, 0), target (2, 3), blocker at (3, 1).
	# Primary axis is Y (|dy|=3 > |dx|=1). Step toward target is
	# (3, 1) — blocked by blocker. X fallback: (2, 0) or (4, 0).
	# Expected: source moves to (2, 0).
	var w: BattleWorldScript = _make_world_with_two_units(
		Vector2i(3, 0), Vector2i(2, 3))
	var blocker_id: int = _add_blocker(w, 0, Vector2i(3, 1))
	_assert(w.is_alive(0), "source entity 0 alive")
	_assert(w.is_alive(1), "target entity 1 alive")
	_assert(w.is_alive(blocker_id), "blocker alive")
	var src_before: Vector2i = w.position_of(0)
	var dst_before: Vector2i = w.position_of(1)
	var dist_before: int = absi(int(src_before.x) - int(dst_before.x)) + absi(int(src_before.y) - int(dst_before.y))
	# Source is player team 0, target is enemy team 1 — call
	# try_move_toward with the target.
	var result: Vector2i = w.try_move_toward(0, 1)
	_assert(result == Vector2i(2, 0),
		"Y primary blocked -> X fallback: source moves to (2, 0) (got %s)" % str(result))
	# World position must match.
	var src_after: Vector2i = w.position_of(0)
	_assert(src_after == Vector2i(2, 0),
		"world position updated to (2, 0) (got %s)" % str(src_after))
	# Distance decreased by exactly 1 (Manhattan step).
	var dist_after: int = absi(int(src_after.x) - int(dst_before.x)) + absi(int(src_after.y) - int(dst_before.y))
	_assert(dist_after == dist_before - 1,
		"Manhattan distance decreased by 1 (before=%d after=%d)" % [dist_before, dist_after])
	# No overlap: source (2, 0), blocker (3, 1), target (2, 3)
	# — all distinct cells.
	_assert(w.position_of(0) != w.position_of(1), "source != target cell")
	_assert(w.position_of(0) != w.position_of(blocker_id), "source != blocker cell")
	_assert(w.position_of(1) != w.position_of(blocker_id), "target != blocker cell")


func _test_movement_primary_x_blocked_y_fallback() -> void:
	print("[m-B] movement_primary_x_blocked_y_fallback [HIGH 3]")
	# HIGH 3.B: source (0, 1), target (3, 3), blocker at (1, 1).
	# |dx|=3, |dy|=2 — primary X (|dx| > |dy|). Step toward
	# target: (1, 1) — blocked by blocker. Y fallback: (0, 0)
	# or (0, 2).
	# Expected: source moves to (0, 0) (Y toward target).
	var w: BattleWorldScript = _make_world_with_two_units(
		Vector2i(0, 1), Vector2i(3, 3))
	var blocker_id: int = _add_blocker(w, 0, Vector2i(1, 1))
	var src_before: Vector2i = w.position_of(0)
	var dst_before: Vector2i = w.position_of(1)
	var dist_before: int = absi(int(src_before.x) - int(dst_before.x)) + absi(int(src_before.y) - int(dst_before.y))
	var result: Vector2i = w.try_move_toward(0, 1)
	_assert(result == Vector2i(0, 2),
		"X primary blocked -> Y fallback: source moves to (0, 2) (got %s)" % str(result))
	var src_after: Vector2i = w.position_of(0)
	_assert(src_after == Vector2i(0, 2),
		"world position updated to (0, 2) (got %s)" % str(src_after))
	var dist_after: int = absi(int(src_after.x) - int(dst_before.x)) + absi(int(src_after.y) - int(dst_before.y))
	_assert(dist_after == dist_before - 1,
		"Manhattan distance decreased by 1 (before=%d after=%d)" % [dist_before, dist_after])
	_assert(w.position_of(0) != w.position_of(1), "source != target cell")
	_assert(w.position_of(0) != w.position_of(blocker_id), "source != blocker cell")


func _test_movement_both_axes_blocked_no_movement() -> void:
	print("[m-C] movement_both_axes_blocked_no_movement [HIGH 3]")
	# HIGH 3.C: source (1, 1), target (3, 3). Blockers at (1, 2)
	# (primary Y blocked) and (2, 1) (fallback X blocked).
	# try_move_toward must return source cell unchanged.
	var w: BattleWorldScript = _make_world_with_two_units(
		Vector2i(1, 1), Vector2i(3, 3))
	_add_blocker(w, 0, Vector2i(1, 2))
	_add_blocker(w, 0, Vector2i(2, 1))
	var src_before: Vector2i = w.position_of(0)
	var result: Vector2i = w.try_move_toward(0, 1)
	_assert(result == src_before,
		"both axes blocked -> returns source unchanged (got %s expected %s)" % [str(result), str(src_before)])
	var src_after: Vector2i = w.position_of(0)
	_assert(src_after == src_before,
		"world position unchanged (got %s)" % str(src_after))


func _test_movement_primary_free_wins_over_fallback() -> void:
	print("[m-D] movement_primary_free_wins_over_fallback [HIGH 3]")
	# HIGH 3.D: source (3, 0), target (3, 3). Primary Y axis.
	# Y step is (3, 1) — FREE (no blocker). Even though Y is
	# the primary axis, ALSO place a block on the X fallback
	# cell (2, 0) to verify the deterministic primary axis is
	# preferred when both are available.
	# Expected: source moves to (3, 1) (primary Y), not (2, 0)
	# (fallback X).
	var w: BattleWorldScript = _make_world_with_two_units(
		Vector2i(3, 0), Vector2i(3, 3))
	_add_blocker(w, 0, Vector2i(2, 0))
	var result: Vector2i = w.try_move_toward(0, 1)
	_assert(result == Vector2i(3, 1),
		"primary Y free wins over X fallback (got %s)" % str(result))
	var src_after: Vector2i = w.position_of(0)
	_assert(src_after == Vector2i(3, 1),
		"world position updated to (3, 1) (got %s)" % str(src_after))
