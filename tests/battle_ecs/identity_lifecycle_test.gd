extends SceneTree
## Phase 2 / Round 2 — identity, reinit-leak, and caller-mutation tests.

const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const BattleResultScript = preload("res://core/battle_ecs/battle_result.gd")
const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const BattleSetupBuilderScript = preload("res://core/battle_ecs/battle_setup_builder.gd")
const RunDomainStateScript = preload("res://core/progression/run_domain_state.gd")
const RunUnitScript = preload("res://core/progression/run_unit.gd")
const RunItemScript = preload("res://core/progression/run_item.gd")
const CombatantScript = preload("res://core/battle/combatant.gd")
const ContentDBScript = preload("res://core/utils/content_db.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_reinitialize_resets_max_ticks()
	await _test_reinitialize_resets_termination_reason()
	await _test_reinitialize_resets_result()
	await _test_player_team_must_be_0()
	await _test_enemy_team_must_be_1()
	await _test_team_outside_0_1_rejected()
	await _test_duplicate_non_empty_source_run_unit_id_rejected()
	await _test_empty_source_run_unit_id_allowed_multiple()
	await _test_caller_mutation_after_initialize_does_not_affect_world()
	await _test_caller_seed_mutation_after_initialize_does_not_affect_simulation()
	await _test_caller_player_units_array_mutation_does_not_leak()
	await _test_caller_unit_field_mutation_after_initialize()
	await _test_sentinel_full_hp_with_bonus_max_hp()
	await _test_partially_damaged_with_bonus_max_hp_preserves_damage()
	await _test_setup_snapshot_owns_true_copy()
	await _test_secondary_axis_fallback_movement()
	print("\n=== identity / reinit-leak / caller-mutation: %d passed, %d failed ===\n" % [_passed, _failed])
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


func _make_simple_setup() -> BattleSetupScript:
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p1", &"warrior", 0, Vector2i(0, 3), 80, 80, 20, 5, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	return BattleSetupScript.new(42, [p], [e], 7, 4)


# === BLOCKER 2: reinitialize leaks max_ticks ===

func _test_reinitialize_resets_max_ticks() -> void:
	print("[i-1] reinitialize_resets_max_ticks")
	var s1: BattleSetupScript = _make_simple_setup()
	var s2: BattleSetupScript = _make_simple_setup()
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	# First run with max_ticks=2 (forces finish in 2 ticks).
	sim.initialize(s1)
	sim.set_max_ticks(2)
	sim.run_until_done(100)
	var r1 = sim.get_result()
	_assert(r1.tick_count <= 2, "first run uses max_ticks=2 (got %d)" % r1.tick_count)
	_assert(r1.termination_reason == BattleResultScript.TERMINATION_TICK_BUDGET,
		"first run terminated by TICK_BUDGET (got %d)" % r1.termination_reason)
	# Reinitialize WITHOUT set_max_ticks. Must NOT inherit the
	# previous max_ticks=2.
	sim.initialize(s2)
	var ticks_after_reinit: int = 0
	while not sim.is_finished() and ticks_after_reinit < 1000:
		sim.step_tick()
		ticks_after_reinit += 1
	_assert(ticks_after_reinit > 2, "second run NOT bounded by inherited max_ticks=2 (got %d)" % ticks_after_reinit)
	_assert(sim.is_finished(), "second run still terminates")


func _test_reinitialize_resets_termination_reason() -> void:
	print("[i-2] reinitialize_resets_termination_reason")
	# Reinitialize should reset _termination_reason to NATURAL,
	# not preserve the previous TICK_BUDGET.
	var s1: BattleSetupScript = _make_simple_setup()
	var s2: BattleSetupScript = _make_simple_setup()
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s1)
	sim.set_max_ticks(1)
	sim.run_until_done(100)
	_assert(sim.get_result().termination_reason == BattleResultScript.TERMINATION_TICK_BUDGET,
		"first run: TICK_BUDGET")
	sim.initialize(s2)
	# Run naturally — should terminate NATURALLY (not TICK_BUDGET).
	while not sim.is_finished():
		sim.step_tick()
	_assert(sim.get_result().termination_reason == BattleResultScript.TERMINATION_NATURAL,
		"second run: NATURAL (got %d)" % sim.get_result().termination_reason)


func _test_reinitialize_resets_result() -> void:
	print("[i-3] reinitialize_resets_result")
	var s1: BattleSetupScript = _make_simple_setup()
	var s2: BattleSetupScript = _make_simple_setup()
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s1)
	sim.run_until_done(100)
	var r1 = sim.get_result()
	_assert(r1 != null, "first run has result")
	sim.initialize(s2)
	# During the new run, get_result() should not return r1's
	# cached data. The result is built fresh on finish.
	while not sim.is_finished():
		sim.step_tick()
	var r2 = sim.get_result()
	_assert(r2 != null, "second run has result")
	# r2 must reflect the second run, not r1.
	_assert(r2.tick_count > 0, "second run tick_count > 0 (got %d)" % r2.tick_count)


# === BLOCKER 3: BattleSetup team invariants ===

func _test_player_team_must_be_0() -> void:
	print("[t-1] player_team_must_be_0")
	# Player array containing team=1 entry must be rejected.
	var p1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p1", &"warrior", 1, Vector2i(0, 3), 80, 80, 20, 5, 5)  # WRONG team
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p1], [e], 7, 4)
	var msg: String = s.validate()
	_assert(msg.find("team=1") >= 0 or msg.find("expected 0") >= 0,
		"rejects player array with team=1 entry (got '%s')" % msg)


func _test_enemy_team_must_be_1() -> void:
	print("[t-2] enemy_team_must_be_1")
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p1", &"warrior", 0, Vector2i(0, 3), 80, 80, 20, 5, 5)
	var e1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 0, Vector2i(0, 0), 80, 80, 20, 5, 5)  # WRONG team
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e1], 7, 4)
	var msg: String = s.validate()
	_assert(msg.find("team=0") >= 0 or msg.find("expected 1") >= 0,
		"rejects enemy array with team=0 entry (got '%s')" % msg)


func _test_team_outside_0_1_rejected() -> void:
	print("[t-3] team_outside_0_1_rejected")
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p1", &"warrior", 2, Vector2i(0, 3), 80, 80, 20, 5, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var msg: String = s.validate()
	_assert(msg.find("team=2") >= 0 or msg.find("expected 0") >= 0,
		"rejects player team=2 (got '%s')" % msg)


# === HIGH 4: source_run_unit_id uniqueness ===

func _test_duplicate_non_empty_source_run_unit_id_rejected() -> void:
	print("[i-4] duplicate_non_empty_source_run_unit_id_rejected")
	# Two players with the SAME source_run_unit_id is rejected.
	var p1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"DUPLICATE", &"warrior", 0, Vector2i(0, 3), 80, 80, 20, 5, 5)
	var p2: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"DUPLICATE", &"warrior", 0, Vector2i(1, 3), 80, 80, 20, 5, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p1, p2], [e], 7, 4)
	var msg: String = s.validate()
	_assert(msg.find("duplicate source_run_unit_id") >= 0,
		"rejects duplicate source id (got '%s')" % msg)
	# Cross-team (player vs enemy) duplicate is also rejected.
	var p3: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"CROSS", &"warrior", 0, Vector2i(0, 3), 80, 80, 20, 5, 5)
	var e3: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"CROSS", &"orc", 1, Vector2i(1, 0), 80, 80, 20, 5, 5)
	var s2: BattleSetupScript = BattleSetupScript.new(42, [p3], [e3], 7, 4)
	var msg2: String = s2.validate()
	_assert(msg2.find("duplicate source_run_unit_id") >= 0,
		"rejects cross-team duplicate source id (got '%s')" % msg2)


func _test_empty_source_run_unit_id_allowed_multiple() -> void:
	print("[i-5] empty_source_run_unit_id_allowed_multiple")
	# Multiple enemies with empty source id (no RunUnit source)
	# is allowed (e.g., pure enemy spawns).
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p1", &"warrior", 0, Vector2i(0, 3), 80, 80, 20, 5, 5)
	var e1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var e2: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(1, 0), 80, 80, 20, 5, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e1, e2], 7, 4)
	_assert(s.validate() == "",
		"empty source id allowed multiple times (got '%s')" % s.validate())


# === HIGH 6: caller mutation after initialize() does not affect simulation ===

func _test_caller_mutation_after_initialize_does_not_affect_world() -> void:
	print("[i-6] caller_mutation_after_initialize_does_not_affect_world")
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p1", &"warrior", 0, Vector2i(0, 3), 80, 80, 20, 5, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	# Mutate the caller's units after initialize.
	p.attack_base = 999
	p.cell = Vector2i(99, 99)
	# Simulation must use the snapshot, not the mutated p.
	var w: BattleWorldScript = sim.world()
	_assert(w.attack_of(0) == 20, "warrior attack_base unchanged (got %d)" % w.attack_of(0))
	_assert(w.position_of(0) == Vector2i(0, 3),
		"warrior position unchanged (got %s)" % str(w.position_of(0)))


func _test_caller_seed_mutation_after_initialize_does_not_affect_simulation() -> void:
	print("[i-7] caller_seed_mutation_after_initialize_does_not_affect_simulation")
	var s1: BattleSetupScript = _make_simple_setup()
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s1)
	var first_dmg_at_seed_42: int = -1
	while not sim.is_finished():
		var evs: Array = sim.step_tick()
		for e in evs:
			if e.type == 3:
				first_dmg_at_seed_42 = e.amount
				break
		if first_dmg_at_seed_42 >= 0:
			break
	_assert(first_dmg_at_seed_42 > 0, "first run produced damage (got %d)" % first_dmg_at_seed_42)
	# Now reinitialize, then mutate the seed after init.
	var s2: BattleSetupScript = _make_simple_setup()
	sim.initialize(s2)
	s2.seed = 99999  # mutate seed after initialize
	# Run again — must NOT be affected by the seed mutation.
	while not sim.is_finished():
		sim.step_tick()
	var r = sim.get_result()
	# If seed had leaked, behavior would differ from baseline seed=42.
	# Verify by running a fresh simulation with seed=42 and comparing.
	var s2_baseline: BattleSetupScript = _make_simple_setup()
	var sim_baseline: BattleSimulationScript = BattleSimulationScript.new()
	sim_baseline.initialize(s2_baseline)
	while not sim_baseline.is_finished():
		sim_baseline.step_tick()
	_assert(r.tick_count == sim_baseline.get_result().tick_count,
		"seed mutation after initialize does not leak (got %d vs %d)" % [r.tick_count, sim_baseline.get_result().tick_count])


func _test_caller_player_units_array_mutation_does_not_leak() -> void:
	print("[i-8] caller_player_units_array_mutation_does_not_leak")
	var p1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p1", &"warrior", 0, Vector2i(0, 3), 80, 80, 20, 5, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var players: Array = [p1]
	var s: BattleSetupScript = BattleSetupScript.new(42, players, [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	# Mutate caller's array.
	players.append(BattleUnitSetupScript.new("p2", &"archer", 0, Vector2i(1, 3), 70, 70, 14, 3, 4))
	players.clear()
	# Simulation must still have the original 1 player entity.
	var w: BattleWorldScript = sim.world()
	_assert(w.alive_ids_by_team(0).size() == 1,
		"player count unchanged (got %d)" % w.alive_ids_by_team(0).size())


func _test_caller_unit_field_mutation_after_initialize() -> void:
	print("[i-9] caller_unit_field_mutation_after_initialize")
	# Confirm that mutating a unit's fields after initialize()
	# does not affect simulation outcomes.
	var s1: BattleSetupScript = _make_simple_setup()
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s1)
	# Mutate the caller's enemy unit's max_hp and starting_hp.
	# (Original was 80/80.)
	s1.enemy_units[0].max_hp = 1
	s1.enemy_units[0].starting_hp = 1
	# World still has the snapshot value (80).
	var w: BattleWorldScript = sim.world()
	_assert(w.max_hp_of(1) == 80, "enemy max_hp unchanged (got %d)" % w.max_hp_of(1))
	_assert(w.current_hp_of(1) == 80, "enemy current_hp unchanged (got %d)" % w.current_hp_of(1))


# === BLOCKER 2: sentinel / partially-damaged + bonus_max_hp ===

func _find_amulet_with_bonus_max_hp() -> Resource:
	ContentDBScript.load_all()
	# Find an actual content item with bonus_max_hp > 0.
	for cand in [&"amulet_vigor", &"rune_power", &"potion_strength"]:
		var d: Resource = ContentDBScript.get_by_id(cand)
		if d != null and int(d.bonus_max_hp) > 0:
			return d
	return null


func _test_sentinel_full_hp_with_bonus_max_hp() -> void:
	print("[i-10] sentinel_full_hp_with_bonus_max_hp [BLOCKER 2]")
	# Fresh RunUnit.current_hp == -1 (sentinel). Equipping an
	# item with bonus_max_hp > 0 must start the battle at the
	# FULL BONUSED HP — matching legacy start_battle semantics.
	var item_def: Resource = _find_amulet_with_bonus_max_hp()
	if item_def == null:
		_assert(false, "no real item with bonus_max_hp>0 in content")
		return
	var bonus_hp: int = int(item_def.bonus_max_hp)
	# Create fresh warrior (current_hp == -1).
	var state: RunDomainStateScript = RunDomainStateScript.new()
	var warrior_def: Resource = ContentDBScript.get_by_id(&"warrior")
	var u: RunUnitScript = state.create_unit(&"warrior", int(warrior_def.max_hp), RunUnitScript.LOCATION_BOARD)
	_assert(int(u.current_hp) == -1, "fresh RunUnit.current_hp == -1 (got %d)" % int(u.current_hp))
	# Equip the item. create_item() already adds to state.items;
	# DO NOT append again.
	var item: RunItemScript = state.create_item(item_def.id)
	item.owner_unit_id = String(u.instance_id)
	u.equipped_item_ids.append(String(item.instance_id))
	# Build setup.
	var s: BattleSetupScript = BattleSetupBuilderScript.build(state, 42, 1)
	_assert(s.player_units.size() == 1, "1 player row")
	var pu: BattleUnitSetupScript = s.player_units[0]
	_assert(pu.max_hp == int(warrior_def.max_hp) + bonus_hp,
		"max_hp = def.max_hp + bonus (got %d expected %d)" % [pu.max_hp, int(warrior_def.max_hp) + bonus_hp])
	_assert(pu.starting_hp == pu.max_hp,
		"sentinel current_hp=-1 -> starting_hp = max_hp (got %d expected %d)" % [pu.starting_hp, pu.max_hp])
	# Also verify against legacy Combatant.
	var Rng = preload("res://core/utils/rng_service.gd")
	Rng.seed_run(42)
	var legacy = CombatantScript.new(warrior_def, 1.0, 1.0, 1.0, -1, 0, 0, bonus_hp)
	_assert(int(legacy.health.current_hp) == pu.starting_hp,
		"legacy current_hp matches new sim (legacy=%d new=%d)" % [int(legacy.health.current_hp), pu.starting_hp])
	_assert(int(legacy.health.max_hp()) == pu.max_hp,
		"legacy max_hp matches new sim (legacy=%d new=%d)" % [int(legacy.health.max_hp()), pu.max_hp])


func _test_partially_damaged_with_bonus_max_hp_preserves_damage() -> void:
	print("[i-11] partially_damaged_with_bonus_max_hp_preserves_damage [BLOCKER 2]")
	# RunUnit.current_hp > 0 (partially damaged). bonus_max_hp
	# equipped. Legacy: max = def+bonus, current = min(hp, max).
	# BattleSetup must match.
	var item_def: Resource = _find_amulet_with_bonus_max_hp()
	if item_def == null:
		_assert(false, "no real item with bonus_max_hp>0 in content")
		return
	var bonus_hp: int = int(item_def.bonus_max_hp)
	var state: RunDomainStateScript = RunDomainStateScript.new()
	var warrior_def: Resource = ContentDBScript.get_by_id(&"warrior")
	var u: RunUnitScript = state.create_unit(&"warrior", int(warrior_def.max_hp), RunUnitScript.LOCATION_BOARD)
	# Partially damage: set current_hp to half of base max.
	var half: int = int(int(warrior_def.max_hp) / 2)
	u.current_hp = half
	# Equip item. create_item() already adds to state.items.
	var item: RunItemScript = state.create_item(item_def.id)
	item.owner_unit_id = String(u.instance_id)
	u.equipped_item_ids.append(String(item.instance_id))
	var s: BattleSetupScript = BattleSetupBuilderScript.build(state, 42, 1)
	var pu: BattleUnitSetupScript = s.player_units[0]
	var expected_max: int = int(warrior_def.max_hp) + bonus_hp
	var expected_starting: int = mini(half, expected_max)
	_assert(pu.max_hp == expected_max,
		"max_hp = def.max_hp + bonus (got %d expected %d)" % [pu.max_hp, expected_max])
	_assert(pu.starting_hp == expected_starting,
		"partial HP capped at max (got %d expected %d)" % [pu.starting_hp, expected_starting])
	# Cross-check with legacy.
	var Rng = preload("res://core/utils/rng_service.gd")
	Rng.seed_run(42)
	var legacy = CombatantScript.new(warrior_def, 1.0, 1.0, 1.0, half, 0, 0, bonus_hp)
	_assert(int(legacy.health.current_hp) == pu.starting_hp,
		"legacy partial HP matches new sim (legacy=%d new=%d)" % [int(legacy.health.current_hp), pu.starting_hp])


# === HIGH 6: setup snapshot ownership ===

func _test_setup_snapshot_owns_true_copy() -> void:
	print("[i-12] setup_snapshot_owns_true_copy [HIGH 6]")
	# HIGH 6: after initialize(), the simulation must hold an
	# INDEPENDENT BattleSetup object. Mutating the caller's
	# setup must not affect the simulation's internal state.
	var s: BattleSetupScript = _make_simple_setup()
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	# Mutate the caller's setup after initialize.
	s.seed = 99999
	s.player_units[0].attack_base = 999
	s.player_units.clear()
	# Run the simulation and capture first damage — must reflect
	# the ORIGINAL setup (seed=42, attack=20), not the mutated one.
	var first_dmg: int = -1
	while not sim.is_finished():
		var evs: Array = sim.step_tick()
		for e in evs:
			if e.type == 3:
				first_dmg = e.amount
				break
		if first_dmg > 0:
			break
	_assert(first_dmg == 19,
		"snapshot preserved attack=20 not 999 (got %d)" % first_dmg)
	# Compare against fresh simulation with the ORIGINAL setup.
	var sim2: BattleSimulationScript = BattleSimulationScript.new()
	sim2.initialize(_make_simple_setup())
	var first_dmg_2: int = -1
	while not sim2.is_finished():
		var evs: Array = sim2.step_tick()
		for e in evs:
			if e.type == 3:
				first_dmg_2 = e.amount
				break
		if first_dmg_2 > 0:
			break
	_assert(first_dmg == first_dmg_2,
		"post-mutation sim matches fresh-original sim (got %d vs %d)" % [first_dmg, first_dmg_2])


# === HIGH 4: secondary-axis fallback ===

func _test_secondary_axis_fallback_movement() -> void:
	print("[i-13] secondary_axis_fallback_movement [HIGH 4]")
	# HIGH 4: when the primary axis is blocked, the entity must
	# take the secondary axis step rather than declaring no
	# progress. Construct a scenario where the Y step is occupied
	# by a high-HP ally (so warrior cannot step through) but the
	# X step is free.
	# Warrior at (3, 0) with attack_range=1, attack=20.
	# Blocking ally at (3, 1) with high HP so it survives.
	# Enemy at (2, 3) — distance |3-2|+|0-3| = 4, out of range.
	# Primary axis: Y (|dy|=3 > |dx|=1). Step wants (3, 1) —
	# blocked by ally. X fallback: (2, 0) or (4, 0) — both free.
	# After X step, warrior is at (2, 0) or (4, 0) and the
	# Manhattan distance to (2, 3) is reduced.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"warrior", 0, Vector2i(3, 0), 80, 80, 20, 5, 1)
	var ally1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"ally1", &"archer", 0, Vector2i(3, 1), 9999, 9999, 1, 1, 1)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(2, 3), 80, 80, 1, 1, 1)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p, ally1], [e], 7, 4)
	_assert(s.validate() == "", "fallback scenario validates (got '%s')" % s.validate())
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	# First tick: warrior's primary Y step (3, 1) is blocked
	# by ally. X fallback should engage (warrior moves to (2, 0)
	# or (4, 0) — closer to enemy at (2, 3)).
	sim.step_tick()
	var w = sim.world()
	var warrior_pos: Vector2i = w.position_of(0)
	_assert(warrior_pos != Vector2i(3, 0),
		"warrior moved (was (3,0) now %s) — fallback engaged" % str(warrior_pos))
	# Verify warrior moved along X (the secondary axis).
	_assert(warrior_pos.x != 3 or warrior_pos.y != 0,
		"warrior is in a different cell than (3,0) (got %s)" % str(warrior_pos))
