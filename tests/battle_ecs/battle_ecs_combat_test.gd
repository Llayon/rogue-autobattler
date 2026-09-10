extends SceneTree
## Phase 2 / Gauntlet 5+6+8+9 — combat / scheduling / events / result tests.

const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const BattleResultScript = preload("res://core/battle_ecs/battle_result.gd")
const BattleEventScript = preload("res://core/battle_ecs/battle_event.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_attack_applies_expected_damage()
	await _test_defense_changes_damage()
	await _test_unit_dies_correctly()
	await _test_winner_determined()
	await _test_dead_unit_cannot_act()
	await _test_dead_target_not_selected()
	await _test_same_definition_units_remain_separate()
	await _test_no_hp_below_zero()
	await _test_deterministic_same_seed()
	await _test_deterministic_same_seed_independent_rng()
	await _test_bounded_termination_2v2()
	await _test_event_sequence_logical_types()
	await _test_event_id_monotonic()
	await _test_event_source_run_unit_id_preserved()
	await _test_battle_result_winner_team_player()
	await _test_battle_result_winner_team_enemy()
	await _test_battle_result_surviving_ids()
	await _test_battle_result_source_run_unit_mapping()
	await _test_battle_result_tick_count_matches()
	print("\n=== battle_ecs combat/events/result: %d passed, %d failed ===\n" % [_passed, _failed])
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


func _run_battle(p1: Dictionary, e1: Dictionary, p_seed: int) -> Dictionary:
	# p1 / e1 = {attack: int, defense: int, max_hp: int, range: int, cell: Vector2i}
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p1", &"warrior", 0, p1.cell,
		p1.max_hp, p1.max_hp, p1.attack, p1.defense, p1.range)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, e1.cell,
		e1.max_hp, e1.max_hp, e1.attack, e1.defense, e1.range)
	var s: BattleSetupScript = BattleSetupScript.new(p_seed, [p], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	var all_events: Array = []
	var ticks: int = 0
	while not sim.is_finished() and ticks < 200:
		var evs: Array = sim.step_tick()
		for e2 in evs:
			all_events.append(e2)
		ticks += 1
	return {"sim": sim, "events": all_events, "ticks": ticks}


func _test_attack_applies_expected_damage() -> void:
	print("[k-1] attack_applies_expected_damage")
	# BLOCKER 2 fix: damage uses Balance.compute_damage formula:
	# damage = max(1, round(base * 100 / (100 + defense)))
	# attack=20, defense=0 -> 20*100/100 = 20.
	var d: Dictionary = _run_battle(
		{"attack": 20, "defense": 0, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 0, "defense": 0, "max_hp": 30, "range": 5, "cell": Vector2i(0, 0)},
		42)
	_assert(d.ticks <= 10, "battle terminates in <= 10 ticks (got %d)" % d.ticks)
	var first_dmg: BattleEventScript = null
	for e in d.events:
		if e.type == BattleEventTypeScript.DAMAGE_APPLIED:
			first_dmg = e
			break
	_assert(first_dmg != null, "DAMAGE_APPLIED event emitted")
	_assert(first_dmg.amount == 20, "first damage = 20 (got %d)" % first_dmg.amount)


func _test_defense_changes_damage() -> void:
	print("[k-2] defense_changes_damage")
	# BLOCKER 2 fix: damage = max(1, round(base * 100 / (100 + defense))).
	# attack=20, defense=10 -> round(20*100/110) = 18.
	var d: Dictionary = _run_battle(
		{"attack": 20, "defense": 0, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 0, "defense": 10, "max_hp": 30, "range": 5, "cell": Vector2i(0, 0)},
		42)
	var first_dmg: BattleEventScript = null
	for e in d.events:
		if e.type == BattleEventTypeScript.DAMAGE_APPLIED:
			first_dmg = e
			break
	_assert(first_dmg != null and first_dmg.amount == 18,
		"damage reduced by defense (got %d expected 18)" % (first_dmg.amount if first_dmg != null else -1))


func _test_unit_dies_correctly() -> void:
	print("[k-3] unit_dies_correctly")
	var d: Dictionary = _run_battle(
		{"attack": 100, "defense": 0, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 0, "defense": 0, "max_hp": 10, "range": 5, "cell": Vector2i(0, 0)},
		42)
	# Enemy has 10 hp, player one-shots -> UNIT_DIED emitted for enemy.
	var saw_died: bool = false
	for e in d.events:
		if e.type == BattleEventTypeScript.UNIT_DIED:
			saw_died = true
			break
	_assert(saw_died, "UNIT_DIED emitted")
	_assert(d.sim.is_finished(), "simulation finished")


func _test_winner_determined() -> void:
	print("[k-4] winner_determined")
	var d: Dictionary = _run_battle(
		{"attack": 100, "defense": 0, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 0, "defense": 0, "max_hp": 10, "range": 5, "cell": Vector2i(0, 0)},
		42)
	var r: BattleResultScript = d.sim.get_result()
	_assert(r != null, "result is non-null")
	_assert(r.outcome == BattleResultScript.OUTCOME_VICTORY, "player wins (got %d)" % r.outcome)
	_assert(r.winner_team == 0, "winner_team = 0 (got %d)" % r.winner_team)


func _test_dead_unit_cannot_act() -> void:
	print("[k-5] dead_unit_cannot_act")
	# Strong enemy, weak player. Player should die first.
	var d: Dictionary = _run_battle(
		{"attack": 5, "defense": 0, "max_hp": 10, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 100, "defense": 0, "max_hp": 80, "range": 5, "cell": Vector2i(0, 0)},
		42)
	var r: BattleResultScript = d.sim.get_result()
	_assert(r.outcome == BattleResultScript.OUTCOME_DEFEAT, "player loses (got %d)" % r.outcome)
	_assert(r.winner_team == 1, "winner_team = 1 (got %d)" % r.winner_team)
	# After player dies, no further DAMAGE_APPLIED events for player->enemy.
	# (enemy might continue attacking but player is dead)
	var last_player_alive_tick: int = -1
	var tick: int = 0
	for e in d.events:
		if e.type == BattleEventTypeScript.UNIT_DIED and e.target_run_unit_id == "p1":
			last_player_alive_tick = e.tick
	# After the player dies, the player should NOT emit further ATTACK_RESOLVED.
	for e in d.events:
		if e.tick > last_player_alive_tick and e.source_run_unit_id == "p1":
			if e.type == BattleEventTypeScript.ATTACK_RESOLVED:
				_assert(false, "dead player emitted ATTACK_RESOLVED at tick %d" % e.tick)
				return
	_assert(true, "no ATTACK_RESOLVED from dead player")


func _test_dead_target_not_selected() -> void:
	print("[k-6] dead_target_not_selected")
	# Two enemies equidistant. After killing one, must target the other.
	var p: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p1", &"warrior", 0, Vector2i(0, 1), 80, 80, 100, 0, 5)
	var e1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 10, 10, 0, 0, 5)
	var e2: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(1, 0), 10, 10, 0, 0, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p], [e1, e2], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	while not sim.is_finished():
		sim.step_tick()
	# Player must have attacked BOTH enemies (one dies, then other dies).
	var r: BattleResultScript = sim.get_result()
	_assert(r != null, "result non-null")
	_assert(r.outcome == BattleResultScript.OUTCOME_VICTORY, "player wins")
	# Both e1 and e2 entity IDs are NOT in surviving_enemy_ids.
	_assert(r.surviving_enemy_ids.is_empty(), "no surviving enemies (got %s)" % str(r.surviving_enemy_ids))


func _test_same_definition_units_remain_separate() -> void:
	print("[k-7] same_definition_units_remain_separate")
	# Two warriors on player side, one orc.
	var p1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"warrior_A", &"warrior", 0, Vector2i(0, 1), 80, 80, 20, 5, 5)
	var p2: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"warrior_B", &"warrior", 0, Vector2i(2, 1), 80, 80, 20, 5, 5)
	var e: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(1, 0), 30, 30, 5, 2, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p1, p2], [e], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	while not sim.is_finished():
		sim.step_tick()
	var r: BattleResultScript = sim.get_result()
	_assert(r.outcome == BattleResultScript.OUTCOME_VICTORY, "players win")
	# Both warrior_A and warrior_B survive (orc dies first).
	_assert(r.source_run_unit_mapping.size() == 2, "both warriors mapped (got %d)" % r.source_run_unit_mapping.size())
	_assert(r.source_run_unit_mapping.values().has("warrior_A"), "warrior_A mapped")
	_assert(r.source_run_unit_mapping.values().has("warrior_B"), "warrior_B mapped")


func _test_no_hp_below_zero() -> void:
	print("[k-8] no_hp_below_zero")
	# Massive overkill.
	var d: Dictionary = _run_battle(
		{"attack": 1000, "defense": 0, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 0, "defense": 0, "max_hp": 10, "range": 5, "cell": Vector2i(0, 0)},
		42)
	# Damage is capped at remaining HP (10). The DAMAGE_APPLIED event
	# should record dealt <= 10, not 1000.
	for e in d.events:
		if e.type == BattleEventTypeScript.DAMAGE_APPLIED:
			_assert(e.amount <= 10, "damage capped at remaining HP (got %d)" % e.amount)


func _test_deterministic_same_seed() -> void:
	print("[k-9] deterministic_same_seed")
	var run_a: Dictionary = _run_battle(
		{"attack": 20, "defense": 5, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 10, "defense": 2, "max_hp": 30, "range": 5, "cell": Vector2i(0, 0)},
		12345)
	var run_b: Dictionary = _run_battle(
		{"attack": 20, "defense": 5, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 10, "defense": 2, "max_hp": 30, "range": 5, "cell": Vector2i(0, 0)},
		12345)
	_assert(run_a.ticks == run_b.ticks, "tick count equal (got %d vs %d)" % [run_a.ticks, run_b.ticks])
	_assert(run_a.events.size() == run_b.events.size(),
		"event count equal (got %d vs %d)" % [run_a.events.size(), run_b.events.size()])
	for i in run_a.events.size():
		var ea: BattleEventScript = run_a.events[i]
		var eb: BattleEventScript = run_b.events[i]
		_assert(ea.type == eb.type and ea.amount == eb.amount and ea.source_entity == eb.source_entity and ea.target_entity == eb.target_entity,
			"event[%d] identical (got type=%d amount=%d vs type=%d amount=%d)" % [i, ea.type, ea.amount, eb.type, eb.amount])


func _test_deterministic_same_seed_independent_rng() -> void:
	print("[k-10] deterministic_same_seed_independent_rng")
	# Run same battle with same seed twice — RNG stream consumed
	# inside sim1 must not affect sim2.
	var run_a: Dictionary = _run_battle(
		{"attack": 20, "defense": 5, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 10, "defense": 2, "max_hp": 30, "range": 5, "cell": Vector2i(0, 0)},
		999)
	var run_b: Dictionary = _run_battle(
		{"attack": 20, "defense": 5, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 10, "defense": 2, "max_hp": 30, "range": 5, "cell": Vector2i(0, 0)},
		999)
	for i in run_a.events.size():
		var ea: BattleEventScript = run_a.events[i]
		var eb: BattleEventScript = run_b.events[i]
		if ea.amount != eb.amount or ea.type != eb.type:
			_assert(false, "event[%d] differs between independent runs" % i)
			return
	_assert(true, "two independent runs with same seed are identical")


func _test_bounded_termination_2v2() -> void:
	print("[k-11] bounded_termination_2v2")
	# 2 vs 2, balanced stats. Must terminate in bounded ticks.
	var p1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p1", &"warrior", 0, Vector2i(0, 1), 80, 80, 20, 5, 5)
	var p2: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p2", &"warrior", 0, Vector2i(2, 1), 80, 80, 20, 5, 5)
	var e1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var e2: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(2, 0), 80, 80, 20, 5, 5)
	var s: BattleSetupScript = BattleSetupScript.new(42, [p1, p2], [e1, e2], 7, 4)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	var ticks: int = 0
	while not sim.is_finished() and ticks < 500:
		sim.step_tick()
		ticks += 1
	_assert(sim.is_finished(), "2v2 terminates within 500 ticks (got %d)" % ticks)
	_assert(ticks < 500, "bounded termination (got %d)" % ticks)


func _test_event_sequence_logical_types() -> void:
	print("[k-12] event_sequence_logical_types")
	var d: Dictionary = _run_battle(
		{"attack": 100, "defense": 0, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 0, "defense": 0, "max_hp": 10, "range": 5, "cell": Vector2i(0, 0)},
		42)
	# Expected: ATTACK_RESOLVED, DAMAGE_APPLIED, UNIT_DIED, BATTLE_ENDED.
	var saw_attack: bool = false
	var saw_dmg: bool = false
	var saw_died: bool = false
	var saw_ended: bool = false
	for e in d.events:
		match e.type:
			BattleEventTypeScript.ATTACK_RESOLVED: saw_attack = true
			BattleEventTypeScript.DAMAGE_APPLIED: saw_dmg = true
			BattleEventTypeScript.UNIT_DIED: saw_died = true
			BattleEventTypeScript.BATTLE_ENDED: saw_ended = true
	_assert(saw_attack, "ATTACK_RESOLVED seen")
	_assert(saw_dmg, "DAMAGE_APPLIED seen")
	_assert(saw_died, "UNIT_DIED seen")
	_assert(saw_ended, "BATTLE_ENDED seen")


func _test_event_id_monotonic() -> void:
	print("[k-13] event_id_monotonic")
	var d: Dictionary = _run_battle(
		{"attack": 100, "defense": 0, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 0, "defense": 0, "max_hp": 10, "range": 5, "cell": Vector2i(0, 0)},
		42)
	var last_id: int = -1
	for e in d.events:
		if e.event_id <= last_id:
			_assert(false, "event_id not monotonic (got %d after %d)" % [e.event_id, last_id])
			return
		last_id = e.event_id
	_assert(true, "event_id strictly increasing across %d events" % d.events.size())


func _test_event_source_run_unit_id_preserved() -> void:
	print("[k-14] event_source_run_unit_id_preserved")
	var d: Dictionary = _run_battle(
		{"attack": 100, "defense": 0, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 0, "defense": 0, "max_hp": 10, "range": 5, "cell": Vector2i(0, 0)},
		42)
	var saw_player_attack: bool = false
	for e in d.events:
		if e.type == BattleEventTypeScript.ATTACK_RESOLVED and e.source_run_unit_id == "p1":
			saw_player_attack = true
	_assert(saw_player_attack, "ATTACK_RESOLVED with source_run_unit_id='p1' seen")


func _test_battle_result_winner_team_player() -> void:
	print("[r-1] battle_result_winner_team_player")
	var d: Dictionary = _run_battle(
		{"attack": 100, "defense": 0, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 0, "defense": 0, "max_hp": 10, "range": 5, "cell": Vector2i(0, 0)},
		42)
	var r: BattleResultScript = d.sim.get_result()
	_assert(r.winner_team == 0, "winner_team=0")
	_assert(r.outcome == BattleResultScript.OUTCOME_VICTORY, "outcome=victory")


func _test_battle_result_winner_team_enemy() -> void:
	print("[r-2] battle_result_winner_team_enemy")
	var d: Dictionary = _run_battle(
		{"attack": 5, "defense": 0, "max_hp": 10, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 100, "defense": 0, "max_hp": 80, "range": 5, "cell": Vector2i(0, 0)},
		42)
	var r: BattleResultScript = d.sim.get_result()
	_assert(r.winner_team == 1, "winner_team=1 (got %d)" % r.winner_team)
	_assert(r.outcome == BattleResultScript.OUTCOME_DEFEAT, "outcome=defeat")


func _test_battle_result_surviving_ids() -> void:
	print("[r-3] battle_result_surviving_ids")
	var d: Dictionary = _run_battle(
		{"attack": 100, "defense": 0, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 0, "defense": 0, "max_hp": 10, "range": 5, "cell": Vector2i(0, 0)},
		42)
	var r: BattleResultScript = d.sim.get_result()
	_assert(r.surviving_player_ids.size() == 1, "1 surviving player (got %d)" % r.surviving_player_ids.size())
	_assert(r.surviving_enemy_ids.is_empty(), "0 surviving enemies (got %s)" % str(r.surviving_enemy_ids))


func _test_battle_result_source_run_unit_mapping() -> void:
	print("[r-4] battle_result_source_run_unit_mapping")
	var d: Dictionary = _run_battle(
		{"attack": 100, "defense": 0, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 0, "defense": 0, "max_hp": 10, "range": 5, "cell": Vector2i(0, 0)},
		42)
	var r: BattleResultScript = d.sim.get_result()
	_assert(r.source_run_unit_mapping.size() == 1, "1 player mapped")
	var mapped_id: String = String(r.source_run_unit_mapping.values()[0])
	_assert(mapped_id == "p1", "mapped id = p1 (got '%s')" % mapped_id)


func _test_battle_result_tick_count_matches() -> void:
	print("[r-5] battle_result_tick_count_matches")
	var d: Dictionary = _run_battle(
		{"attack": 100, "defense": 0, "max_hp": 80, "range": 5, "cell": Vector2i(0, 1)},
		{"attack": 0, "defense": 0, "max_hp": 10, "range": 5, "cell": Vector2i(0, 0)},
		42)
	var r: BattleResultScript = d.sim.get_result()
	_assert(r.tick_count == d.ticks, "result.tick_count == observed ticks (%d vs %d)" % [r.tick_count, d.ticks])
