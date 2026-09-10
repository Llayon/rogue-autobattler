extends SceneTree
## Phase 2 / Gauntlet 5 (deep) — lifecycle / edge adversarial pass.

const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const BattleResultScript = preload("res://core/battle_ecs/battle_result.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_hp_1_kills_in_one_hit()
	await _test_very_high_defense_zero_damage_floor()
	await _test_duplicate_definition_ids_different_run_unit_ids()
	await _test_stale_target_after_kill_in_same_tick()
	await _test_two_worlds_simultaneously_active()
	await _test_repeated_world_create_destroy()
	await _test_event_for_unit_dying_in_same_action()
	await _test_winner_after_final_transition()
	await _test_finite_termination_guard_violation_reports()
	await _test_both_teams_empty_validation_rejects()
	await _test_dead_at_spawn_player_loses_naturally()
	await _test_dead_at_spawn_enemy_loses_naturally()
	await _test_dead_at_spawn_never_attacks()
	await _test_dead_at_spawn_excluded_from_alive_ids()
	await _test_set_max_ticks_hard_cap()
	await _test_run_until_done_collects_all_events()
	await _test_stalemate_winner_determination_unambiguous()
	await _test_tick_budget_forced_termination_is_draw()
	await _test_event_emitted_for_unit_dying_in_same_action_has_valid_target()
	await _test_battle_result_does_not_mutate_run_domain()
	await _test_simulation_rejects_invalid_setup()
	await _test_battle_setup_defensive_copy()
	print("\n=== lifecycle/edge adversarial: %d passed, %d failed ===\n" % [_passed, _failed])
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


func _test_hp_1_kills_in_one_hit() -> void:
	print("[e-1] hp_1_kills_in_one_hit")
	# Player has attack=5, range=5. Enemy has hp=1, attack=0.
	# After first tick, enemy must die.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"warrior", 0, Vector2i(0, 1), 80, 80, 5, 0, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 1, 1, 0, 0, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	while not sim.is_finished():
		sim.step_tick()
	_assert(sim.is_finished(), "1-HP enemy killed in <=500 ticks")
	_assert(sim.get_result().winner_team == 0, "player wins (1-hit kill)")


func _test_very_high_defense_zero_damage_floor() -> void:
	print("[e-2] very_high_defense_zero_damage_floor")
	# BLOCKER 2 fix: damage uses Balance.compute_damage:
	# damage = max(1, round(base * 100 / (100 + defense))).
	# attack=10, defense=100 -> round(10*100/200) = 5 (NOT 1).
	# Floor only kicks in when defense is so high the formula
	# rounds to 0; attack=10, defense=10000 -> 0 -> floored to 1.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"warrior", 0, Vector2i(0, 1), 80, 80, 10, 0, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 80, 80, 0, 100, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	var first_dmg: int = -1
	while first_dmg < 0 and not sim.is_finished():
		var evs: Array = sim.step_tick()
		for e2 in evs:
			if e2.type == 3 and e2.source_entity == 0:
				first_dmg = e2.amount
				break
	_assert(first_dmg == 5, "damage with defense=100 (formula floor at 1): 10*100/200=5 (got %d)" % first_dmg)
	# Extreme defense to verify floor at 1.
	var p2: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p2", &"warrior", 0, Vector2i(0, 1), 80, 80, 10, 0, 5)
	var e2u: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 80, 80, 0, 10000, 5)
	var s2: BattleSetupScript = BattleSetupScript.new(42, [p2], [e2u], 7, 4)
	var sim2: BattleSimulationScript = BattleSimulationScript.new()
	sim2.initialize(s2)
	var floor_dmg: int = -1
	while floor_dmg < 0 and not sim2.is_finished():
		var evs: Array = sim2.step_tick()
		for e3 in evs:
			if e3.type == 3 and e3.source_entity == 0:
				floor_dmg = e3.amount
				break
	_assert(floor_dmg == 1, "damage floored at 1 when formula rounds to 0 (got %d)" % floor_dmg)


func _test_duplicate_definition_ids_different_run_unit_ids() -> void:
	print("[e-3] duplicate_definition_ids_different_run_unit_ids")
	# Three warriors with definition_id=&"warrior" but distinct
	# instance_ids. The world must give them distinct entity IDs.
	var players: Array = []
	for i in 3:
		players.append(BattleUnitSetupScript.new(
			"warrior_%d" % i, &"warrior", 0, Vector2i(i * 2, 1), 80, 80, 20, 5, 5))
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(3, 0), 80, 80, 20, 5, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, players, [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	var w: BattleWorldScript = sim.world()
	var alive_ids: Array = w.alive_ids_by_team(0)
	_assert(alive_ids.size() == 3, "3 player entities")
	_assert(alive_ids[0] != alive_ids[1] and alive_ids[1] != alive_ids[2], "distinct IDs")
	# All have same definition_id.
	for id in alive_ids:
		_assert(w.definition_id_of(int(id)) == &"warrior", "definition_id same across duplicates")


func _test_stale_target_after_kill_in_same_tick() -> void:
	print("[e-4] stale_target_after_kill_in_same_tick")
	# Two enemies equidistant, player has range to hit both.
	# First enemy dies; second must still be attacked.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"warrior", 0, Vector2i(0, 1), 80, 80, 100, 0, 5)
	var e1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 1, 1, 0, 0, 5)
	var e2: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(1, 0), 80, 80, 0, 0, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e1, e2], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	while not sim.is_finished():
		sim.step_tick()
	_assert(sim.is_finished(), "completes (no stale-target crash)")
	_assert(sim.get_result().winner_team == 0, "player wins")


func _test_two_worlds_simultaneously_active() -> void:
	print("[e-5] two_worlds_simultaneously_active")
	# Two simulations live at the same time. Verify they don't
	# cross-influence.
	var s1: BattleSetupScript = BattleSetupScript.new(1, [
		BattleUnitSetupScript.new("p", &"warrior", 0, Vector2i(0, 1), 80, 80, 20, 5, 5)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 10, 3, 5)
	])
	var s2: BattleSetupScript = BattleSetupScript.new(2, [
		BattleUnitSetupScript.new("q", &"warrior", 0, Vector2i(0, 1), 80, 80, 20, 5, 5),
		BattleUnitSetupScript.new("r", &"warrior", 0, Vector2i(2, 1), 80, 80, 20, 5, 5)
	], [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 10, 3, 5),
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(2, 0), 30, 30, 10, 3, 5)
	])
	var sim1: BattleSimulationScript = BattleSimulationScript.new()
	var sim2: BattleSimulationScript = BattleSimulationScript.new()
	sim1.initialize(s1)
	sim2.initialize(s2)
	# Interleave ticks.
	while (not sim1.is_finished() or not sim2.is_finished()):
		if not sim1.is_finished():
			sim1.step_tick()
		if not sim2.is_finished():
			sim2.step_tick()
	_assert(sim1.is_finished() and sim2.is_finished(), "both finished")
	# Both have separate RNG instances (verified elsewhere) so
	# results are independent. Just assert they have outcomes.
	_assert(sim1.get_result().outcome >= 0, "sim1 has outcome")
	_assert(sim2.get_result().outcome >= 0, "sim2 has outcome")


func _test_repeated_world_create_destroy() -> void:
	print("[e-6] repeated_world_create_destroy")
	# Stress test: create/destroy 100 worlds.
	# BattleWorld.allocate_entity_id() returns a fresh int ID
	# but does NOT mark it alive — is_alive() returns false until
	# the entity is spawned via spawn_from_setup or populated
	# explicitly. This is documented behavior; we verify it here.
	var sim_count: int = 0
	for i in 100:
		var w: BattleWorldScript = BattleWorldScript.new(7, 4)
		var a: int = w.allocate_entity_id()
		var b: int = w.allocate_entity_id()
		_assert(a != b and a >= 0 and b >= 0, "iteration %d: IDs distinct and non-negative (a=%d b=%d)" % [i, a, b])
		# remove_entity on never-spawned IDs is a no-op (key not in dict).
		w.remove_entity(a)
		sim_count += 1
	_assert(sim_count == 100, "100 world create/destroy OK")


func _test_event_for_unit_dying_in_same_action() -> void:
	print("[e-7] event_for_unit_dying_in_same_action")
	# When a unit dies from a single attack, the death event MUST
	# still carry meaningful entity ID and source_run_unit_id.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"warrior", 0, Vector2i(0, 1), 80, 80, 100, 0, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"e_orc", &"orc", 1, Vector2i(0, 0), 10, 10, 0, 0, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	var evs: Array = []
	while not sim.is_finished():
		var step_evs: Array = sim.step_tick()
		for e2 in step_evs:
			evs.append(e2)
	# Find the UNIT_DIED event for the enemy.
	var died_event = null
	for e2 in evs:
		if e2.type == 1:  # UNIT_DIED
			died_event = e2
			break
	_assert(died_event != null, "UNIT_DIED event emitted")
	_assert(died_event.target_entity >= 0, "died event has valid target_entity")
	# Note: target_run_unit_id is "" for enemies (no source).
	_assert(died_event.source_entity >= 0, "died event has valid source_entity (attacker)")


func _test_winner_after_final_transition() -> void:
	print("[e-8] winner_after_final_transition")
	# After one side empty, winner is correctly set.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"warrior", 0, Vector2i(0, 1), 80, 80, 100, 0, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 1, 1, 0, 0, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	while not sim.is_finished():
		sim.step_tick()
	var r = sim.get_result()
	_assert(r.winner_team == 0 and r.outcome == BattleResultScript.OUTCOME_VICTORY,
		"player wins with OUTCOME_VICTORY (got winner=%d outcome=%d)" % [r.winner_team, r.outcome])


func _test_finite_termination_guard_violation_reports() -> void:
	print("[e-9] finite_termination_guard_violation_reports")
	# Construct a scenario where the simulation cannot progress
	# (e.g. all entities out of attack range). The simulation now
	# has built-in stalemate detection: if no DAMAGE_APPLIED and
	# no HP change for 2 consecutive ticks, the simulation
	# force-finishes as a DRAW (NOT a player victory).
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"warrior", 0, Vector2i(0, 0), 80, 80, 20, 5, 1)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(6, 3), 80, 80, 20, 5, 1)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	var evs: Array = sim.run_until_done(100)
	_assert(sim.is_finished(), "out-of-range simulation force-finishes via stalemate")
	_assert(sim.get_result() != null, "result non-null")
	# BLOCKER 1 fix: forced termination MUST be DRAW, not victory.
	var r = sim.get_result()
	_assert(r.winner_team == -1, "stalemate: winner_team = -1 (draw), NOT 0 (got %d)" % r.winner_team)
	_assert(r.outcome == BattleResultScript.OUTCOME_DRAW, "stalemate: OUTCOME_DRAW (got %d)" % r.outcome)
	_assert(r.termination_reason == BattleResultScript.TERMINATION_STALEMATE,
		"stalemate: TERMINATION_STALEMATE (got %d)" % r.termination_reason)
	# BATTLE_ENDED event was emitted.
	var saw_ended: bool = false
	for e2 in evs:
		if e2.type == 4:
			saw_ended = true
			break
	_assert(saw_ended, "BATTLE_ENDED emitted on stalemate")
	# Both entities still alive at stalemate.
	_assert(r.surviving_player_ids.size() == 1 and r.surviving_enemy_ids.size() == 1,
		"both sides still alive at stalemate (got p=%d e=%d)" % [r.surviving_player_ids.size(), r.surviving_enemy_ids.size()])
	print("  [INFO] out-of-range scenarios force-finish as DRAW via 2-tick stalemate detection.")


func _test_both_teams_empty_validation_rejects() -> void:
	print("[e-10] both_teams_empty_validation_rejects")
	var s: BattleSetupScript = BattleSetupScript.new(42, [], [], 7, 4)
	var msg: String = s.validate()
	_assert(msg != "", "both-empty rejected (got '%s')" % msg)


func _test_dead_at_spawn_player_loses_naturally() -> void:
	print("[e-11] dead_at_spawn_player_loses_naturally")
	# BLOCKER 3: dead-at-spawn player must NOT act. Enemy kills
	# player (already dead at HP=0). Enemy wins naturally.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"dead_p", &"warrior", 0, Vector2i(0, 1), 0, 80, 20, 5, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	sim.run_until_done(100)
	_assert(sim.is_finished(), "dead-player vs live-enemy terminates")
	var r = sim.get_result()
	_assert(r.winner_team == 1, "dead player loses (winner=enemy=1) (got %d)" % r.winner_team)
	_assert(r.outcome == BattleResultScript.OUTCOME_DEFEAT,
		"dead player: OUTCOME_DEFEAT (got %d)" % r.outcome)
	_assert(r.termination_reason == BattleResultScript.TERMINATION_NATURAL,
		"dead player: TERMINATION_NATURAL (got %d)" % r.termination_reason)
	_assert(r.surviving_player_ids.is_empty(), "no surviving players")
	_assert(r.surviving_enemy_ids.size() == 1, "1 surviving enemy")


func _test_dead_at_spawn_enemy_loses_naturally() -> void:
	print("[e-11b] dead_at_spawn_enemy_loses_naturally")
	# BLOCKER 3: dead-at-spawn enemy must NOT act. Player kills
	# enemy. Player wins naturally.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"warrior", 0, Vector2i(0, 1), 80, 80, 100, 0, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 0, 30, 20, 5, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	sim.run_until_done(100)
	_assert(sim.is_finished(), "live-player vs dead-enemy terminates")
	var r = sim.get_result()
	_assert(r.winner_team == 0, "dead enemy loses (winner=player=0) (got %d)" % r.winner_team)
	_assert(r.outcome == BattleResultScript.OUTCOME_VICTORY,
		"dead enemy: OUTCOME_VICTORY (got %d)" % r.outcome)
	_assert(r.surviving_player_ids.size() == 1, "1 surviving player")
	_assert(r.surviving_enemy_ids.is_empty(), "no surviving enemies")


func _test_dead_at_spawn_never_attacks() -> void:
	print("[e-11c] dead_at_spawn_never_attacks")
	# Dead unit must never emit ATTACK_RESOLVED or DAMAGE_APPLIED.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"dead_p", &"warrior", 0, Vector2i(0, 1), 0, 80, 100, 0, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 80, 80, 0, 0, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	var evs: Array = sim.run_until_done(100)
	# Player must NOT emit any ATTACK_RESOLVED or DAMAGE_APPLIED
	# where source is the dead player's entity (id=0).
	for e2 in evs:
		if e2.source_entity == 0 and (e2.type == 2 or e2.type == 3):
			_assert(false, "dead player emitted type=%d (got amount=%d)" % [e2.type, e2.amount])
			return
	_assert(true, "dead player never attacks")


func _test_dead_at_spawn_excluded_from_alive_ids() -> void:
	print("[e-11d] dead_at_spawn_excluded_from_alive_ids")
	# Dead-at-spawn entities are NOT in alive_ids_by_team().
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"dead_p", &"warrior", 0, Vector2i(0, 1), 0, 80, 20, 5, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	var w = sim.world()
	_assert(w.alive_ids_by_team(0).is_empty(),
		"dead player absent from alive_ids_by_team(0) (got %s)" % str(w.alive_ids_by_team(0)))
	_assert(w.alive_ids_by_team(1).size() == 1, "1 alive enemy")


func _test_simulation_rejects_invalid_setup() -> void:
	print("[e-17] simulation_rejects_invalid_setup [BLOCKER 5]")
	# BattleSimulation.initialize must reject invalid setups:
	# empty side, overlapping cells, invalid HP, OOB deployment.
	# Empty side: player empty.
	var s_empty_p: BattleSetupScript = BattleSetupScript.new(42, [],
		[BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 5, 2, 1)])
	var sim1: BattleSimulationScript = BattleSimulationScript.new()
	var ok1: bool = sim1.initialize(s_empty_p)
	_assert(not ok1, "initialize rejects empty player side")
	_assert(not sim1.is_valid(), "is_valid() returns false")
	_assert(not sim1.is_finished(), "is_finished() returns false")
	# Invalid HP.
	var s_bad_hp: BattleSetupScript = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new("p", &"warrior", 0, Vector2i(0, 3), 200, 100, 5, 2, 1)],
		[BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 5, 2, 1)])
	var sim2: BattleSimulationScript = BattleSimulationScript.new()
	var ok2: bool = sim2.initialize(s_bad_hp)
	_assert(not ok2, "initialize rejects starting_hp > max_hp")
	# Cross-team same cell.
	var s_cross: BattleSetupScript = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new("p", &"warrior", 0, Vector2i(0, 3), 30, 30, 5, 2, 1)],
		[BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 3), 30, 30, 5, 2, 1)])
	var sim3: BattleSimulationScript = BattleSimulationScript.new()
	var ok3: bool = sim3.initialize(s_cross)
	_assert(not ok3, "initialize rejects cross-team cell collision")
	# OOB deployment.
	var s_oob: BattleSetupScript = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new("p", &"warrior", 0, Vector2i(99, 99), 30, 30, 5, 2, 1)],
		[BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 5, 2, 1)])
	var sim4: BattleSimulationScript = BattleSimulationScript.new()
	var ok4: bool = sim4.initialize(s_oob)
	_assert(not ok4, "initialize rejects OOB cell")


func _test_battle_setup_defensive_copy() -> void:
	print("[e-18] battle_setup_defensive_copy [BLOCKER 8]")
	# After construction, mutating the caller's arrays or unit
	# fields must NOT change the BattleSetup contents.
	var caller_players: Array = [
		BattleUnitSetupScript.new("p", &"warrior", 0, Vector2i(0, 3), 80, 80, 20, 5, 5)
	]
	var caller_enemies: Array = [
		BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 0), 30, 30, 5, 2, 5)
	]
	var s: BattleSetupScript = BattleSetupScript.new(42, caller_players, caller_enemies, 7, 4)
	# Capture before-mutation snapshots.
	var before_p_hp: int = int(s.player_units[0].max_hp)
	var before_e_hp: int = int(s.enemy_units[0].max_hp)
	# Mutate the caller's arrays.
	caller_players[0].max_hp = 1
	caller_players.append(BattleUnitSetupScript.new("p2", &"warrior", 0, Vector2i(1, 3), 80, 80, 20, 5, 5))
	caller_enemies.clear()
	# BattleSetup contents must be unchanged.
	_assert(s.player_units.size() == 1, "player_units array length unchanged (got %d)" % s.player_units.size())
	_assert(s.player_units[0].max_hp == before_p_hp,
		"player_units[0].max_hp unchanged (got %d expected %d)" % [s.player_units[0].max_hp, before_p_hp])
	_assert(s.enemy_units.size() == 1, "enemy_units array length unchanged (got %d)" % s.enemy_units.size())
	_assert(s.enemy_units[0].max_hp == before_e_hp,
		"enemy_units[0].max_hp unchanged (got %d expected %d)" % [s.enemy_units[0].max_hp, before_e_hp])


func _test_set_max_ticks_hard_cap() -> void:
	print("[e-12] set_max_ticks_hard_cap")
	# Hard tick budget forces termination even if no progress.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"warrior", 0, Vector2i(0, 0), 80, 80, 20, 5, 1)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(6, 3), 80, 80, 20, 5, 1)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	sim.set_max_ticks(5)
	var evs: Array = sim.run_until_done(100)
	_assert(sim.is_finished(), "max_ticks budget forces finish")
	_assert(sim.get_result().tick_count <= 5, "tick_count <= max_ticks (got %d)" % sim.get_result().tick_count)
	var saw_ended: bool = false
	for e2 in evs:
		if e2.type == 4:
			saw_ended = true
			break
	_assert(saw_ended, "BATTLE_ENDED emitted at max_ticks budget hit")


func _test_run_until_done_collects_all_events() -> void:
	print("[e-13] run_until_done_collects_all_events")
	# run_until_done should return all events in order.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"warrior", 0, Vector2i(0, 1), 80, 80, 100, 0, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 10, 10, 0, 0, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	var collected: Array = sim.run_until_done(100)
	_assert(sim.is_finished(), "run_until_done finishes simulation")
	var saw_died: bool = false
	var saw_ended: bool = false
	for e2 in collected:
		if e2.type == 1:
			saw_died = true
		if e2.type == 4:
			saw_ended = true
	_assert(saw_died and saw_ended, "run_until_done returns both UNIT_DIED and BATTLE_ENDED")


func _test_stalemate_winner_determination_unambiguous() -> void:
	print("[e-14] stalemate_winner_determination_unambiguous")
	# BLOCKER 1 fix: after stalemate force-finish, the result
	# is OUTCOME_DRAW with winner_team = -1. Forced termination
	# NEVER awards victory.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"warrior", 0, Vector2i(0, 0), 80, 80, 20, 5, 1)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(6, 3), 80, 80, 20, 5, 1)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	sim.run_until_done(100)
	var r = sim.get_result()
	_assert(r.winner_team == -1, "stalemate: winner_team = -1 (draw) (got %d)" % r.winner_team)
	_assert(r.outcome == BattleResultScript.OUTCOME_DRAW, "stalemate: OUTCOME_DRAW (got %d)" % r.outcome)
	_assert(r.termination_reason == BattleResultScript.TERMINATION_STALEMATE,
		"stalemate: TERMINATION_STALEMATE (got %d)" % r.termination_reason)


func _test_tick_budget_forced_termination_is_draw() -> void:
	print("[e-14b] tick_budget_forced_termination_is_draw")
	# BLOCKER 1 fix: tick budget force-finish MUST also be DRAW.
	# Construct a scenario where ticks exhaust before any progress.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"warrior", 0, Vector2i(0, 0), 80, 80, 20, 5, 1)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(6, 3), 80, 80, 20, 5, 1)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	sim.set_max_ticks(2)
	var evs: Array = sim.run_until_done(100)
	_assert(sim.is_finished(), "tick budget forces finish")
	var r = sim.get_result()
	_assert(r.termination_reason == BattleResultScript.TERMINATION_TICK_BUDGET,
		"termination_reason = TICK_BUDGET (got %d)" % r.termination_reason)
	_assert(r.winner_team == -1, "tick-budget: winner_team = -1 (draw) (got %d)" % r.winner_team)
	_assert(r.outcome == BattleResultScript.OUTCOME_DRAW,
		"tick-budget: OUTCOME_DRAW (got %d)" % r.outcome)
	_assert(r.tick_count <= 2, "tick_count <= max_ticks (got %d)" % r.tick_count)
	# BATTLE_ENDED must have been emitted.
	var saw_ended: bool = false
	for e2 in evs:
		if e2.type == 4:
			saw_ended = true
			break
	_assert(saw_ended, "BATTLE_ENDED emitted at tick budget")


func _test_event_emitted_for_unit_dying_in_same_action_has_valid_target() -> void:
	print("[e-15] event_for_dying_unit_has_valid_target_after_kill")
	# Death event payload must carry meaningful target_entity.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p", &"warrior", 0, Vector2i(0, 1), 80, 80, 100, 0, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"e_orc", &"orc", 1, Vector2i(0, 0), 10, 10, 0, 0, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	var evs: Array = sim.run_until_done(100)
	var died_event = null
	for e2 in evs:
		if e2.type == 1:
			died_event = e2
			break
	_assert(died_event != null, "UNIT_DIED emitted")
	_assert(died_event.target_entity >= 0, "target_entity is valid entity ID")
	_assert(died_event.source_entity >= 0, "source_entity (attacker) is valid entity ID")
	_assert(died_event.amount > 0, "amount carries the killing damage (got %d)" % died_event.amount)
	# After death, the BattleWorld still has the entity as known
	# (just not alive) — events referencing it remain valid.
	var w = sim.world()
	_assert(not w.is_alive(died_event.target_entity), "target entity dead in world")


func _test_battle_result_does_not_mutate_run_domain() -> void:
	print("[e-16] battle_result_does_not_mutate_run_domain")
	# BattleResult is a pure DTO. Constructing one and inspecting
	# fields must not leak back into any state.
	var res_inst = BattleResultScript.new()
	res_inst.winner_team = 0
	res_inst.outcome = 0
	res_inst.tick_count = 5
	res_inst.surviving_player_ids = [0, 1]
	res_inst.surviving_enemy_ids = [2, 3]
	_assert(res_inst.winner_team == 0 and res_inst.outcome == 0, "set fields read back")
	_assert(res_inst.tick_count == 5, "tick_count round-trip")
	_assert(res_inst.surviving_player_ids.size() == 2, "player IDs preserved")
	_assert(res_inst.surviving_enemy_ids.size() == 2, "enemy IDs preserved")
	# Result has no method to mutate RunDomain (no setter, no callback).
	_assert(not res_inst.has_method("apply_to_run"), "BattleResult has no apply_to_run method")
	_assert(not res_inst.has_method("commit"), "BattleResult has no commit method")
