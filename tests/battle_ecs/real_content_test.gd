extends SceneTree
## Phase 2 / BLOCKER 1 — real-content end-to-end melee battle.
##
## Verifies that the new BattleSimulation can complete real battles
## with REAL content (warrior vs orc_warrior, both melee with
## default attack_range=1) using the BattleSetupBuilder.
##
## Before movement is implemented, these tests FAIL (false
## stalemate after 2 ticks — melee units cannot engage at
## distance 3 with attack_range=1).

const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleSetupBuilderScript = preload("res://core/battle_ecs/battle_setup_builder.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const BattleResultScript = preload("res://core/battle_ecs/battle_result.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const ContentDBScript = preload("res://core/utils/content_db.gd")
const RunDomainStateScript = preload("res://core/progression/run_domain_state.gd")
const RunUnitScript = preload("res://core/progression/run_unit.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	await _test_warrior_vs_orc_warrior_real_content()
	await _test_warrior_archer_vs_tier1_wave_real_content()
	await _test_real_content_does_not_false_stalemate()
	await _test_real_content_emits_unit_moved_before_melee()
	await _test_real_content_no_cell_overlap_after_movement()
	await _test_real_content_same_seed_deterministic()
	await _test_real_content_battle_terminates_naturally()
	await _test_real_content_with_pure_tier2_wave()
	await _test_real_pure_melee_1v1()
	print("\n=== real content end-to-end: %d passed, %d failed ===\n" % [_passed, _failed])
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


func _make_state_with(player_def_ids: Array) -> RunDomainStateScript:
	var state: RunDomainStateScript = RunDomainStateScript.new()
	for def_id in player_def_ids:
		var def: Resource = ContentDBScript.get_by_id(def_id)
		if def == null:
			continue
		state.create_unit(def_id, int(def.max_hp), RunUnitScript.LOCATION_BOARD)
	return state


# Find a seed that produces an orc_warrior as a relevant enemy.
# Tier-2 enemies include orc_warrior. round_index=4 -> tier-2 pool.
func _find_seed_for_orc_warrior() -> int:
	for seed in range(1, 200):
		var state: RunDomainStateScript = _make_state_with([&"warrior"])
		var s: BattleSetupScript = BattleSetupBuilderScript.build(state, seed, 4)
		for e in s.enemy_units:
			if e.definition_id == &"orc_warrior":
				return seed
	return -1


func _run_battle(seed: int, p_def_ids: Array, round_index: int) -> Dictionary:
	var state: RunDomainStateScript = _make_state_with(p_def_ids)
	var s: BattleSetupScript = BattleSetupBuilderScript.build(state, seed, round_index)
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	var events: Array = []
	# Safety cap to avoid infinite loops; 500 ticks is well above
	# any real-content battle length for the vertical slice.
	var ticks: int = 0
	while not sim.is_finished() and ticks < 500:
		var evs: Array = sim.step_tick()
		for e in evs:
			events.append(e)
		ticks += 1
	return {"sim": sim, "events": events, "setup": s}


func _test_warrior_vs_orc_warrior_real_content() -> void:
	print("[real-1] warrior_vs_orc_warrior_real_content")
	var seed: int = _find_seed_for_orc_warrior()
	_assert(seed > 0, "found seed for orc_warrior (seed=%d)" % seed)
	if seed < 0:
		return
	var d: Dictionary = _run_battle(seed, [&"warrior"], 4)
	var sim = d.sim
	var setup = d.setup
	_assert(setup.validate() == "", "real setup validates (msg='%s')" % setup.validate())
	# Real warrior has default attack_range=1, real orc_warrior
	# has default attack_range=1. They start at distance 3.
	_assert(sim.is_finished(), "real warrior vs orc_warrior terminates")
	var r = sim.get_result()
	_assert(r != null, "result non-null")
	# Must NOT be a forced draw by stalemate — must be natural
	# termination (one side eliminated).
	_assert(r.termination_reason == BattleResultScript.TERMINATION_NATURAL,
		"real melee terminates NATURALLY (got reason=%d)" % r.termination_reason)
	_assert(r.outcome != BattleResultScript.OUTCOME_DRAW
			or r.surviving_player_ids.is_empty() != r.surviving_enemy_ids.is_empty(),
		"real melee produces natural winner (not forced draw)")
	print("  [INFO] seed=%d outcome=%d winner=%d tick_count=%d"
		% [seed, r.outcome, r.winner_team, r.tick_count])


func _test_warrior_archer_vs_tier1_wave_real_content() -> void:
	print("[real-2] warrior_archer_vs_tier1_wave_real_content")
	# ROUND 1 (tier 1 pool = goblin, goblin_archer). Warrior + archer
	# vs whatever tier-1 wave is built.
	var d: Dictionary = _run_battle(42, [&"warrior", &"archer"], 1)
	var sim = d.sim
	_assert(sim.is_finished(), "round-1 tier-1 wave terminates")
	var r = sim.get_result()
	_assert(r.termination_reason == BattleResultScript.TERMINATION_NATURAL,
		"tier-1 terminates NATURALLY (got reason=%d)" % r.termination_reason)


func _test_real_content_does_not_false_stalemate() -> void:
	print("[real-3] real_content_does_not_false_stalemate")
	# Find a real-content scenario where the warrior would
	# false-stalemate WITHOUT movement.
	var seed: int = _find_seed_for_orc_warrior()
	if seed < 0:
		_assert(false, "could not find orc_warrior seed")
		return
	var d: Dictionary = _run_battle(seed, [&"warrior"], 4)
	var r = d.sim.get_result()
	_assert(r.termination_reason != BattleResultScript.TERMINATION_STALEMATE,
		"real content does not false-stalemate (got STALEMATE)")


func _test_real_content_emits_unit_moved_before_melee() -> void:
	print("[real-4] real_content_emits_unit_moved_before_melee")
	# For a melee-on-melee scenario, at least one UNIT_MOVED event
	# must occur BEFORE the first DAMAGE_APPLIED event.
	var seed: int = _find_seed_for_orc_warrior()
	if seed < 0:
		_assert(false, "could not find orc_warrior seed")
		return
	var d: Dictionary = _run_battle(seed, [&"warrior"], 4)
	var events: Array = d.events
	var first_moved: int = -1
	var first_dmg: int = -1
	for i in events.size():
		var e = events[i]
		if e.type == BattleEventTypeScript.UNIT_MOVED and first_moved < 0:
			first_moved = i
		if e.type == BattleEventTypeScript.DAMAGE_APPLIED and first_dmg < 0:
			first_dmg = i
	_assert(first_moved >= 0, "UNIT_MOVED event emitted (first idx=%d)" % first_moved)
	if first_dmg >= 0 and first_moved >= 0:
		_assert(first_moved < first_dmg,
			"UNIT_MOVED precedes first DAMAGE_APPLIED (moved=%d dmg=%d)" % [first_moved, first_dmg])


func _test_real_content_no_cell_overlap_after_movement() -> void:
	print("[real-5] real_content_no_cell_overlap_after_movement")
	# BLOCKER 1A fix: drive simulation TICK BY TICK using the LIVE
	# simulation's world (sim2.world()), not a stale world from a
	# previously completed simulation. After every step_tick,
	# inspect the current world state and the just-emitted
	# events to prove no cell overlap and UNIT_MOVED payload
	# integrity.
	var seed: int = _find_seed_for_orc_warrior()
	if seed < 0:
		_assert(false, "could not find orc_warrior seed")
		return
	# Set up a single live simulation.
	var state: RunDomainStateScript = _make_state_with([&"warrior"])
	var s: BattleSetupScript = BattleSetupBuilderScript.build(state, seed, 4)
	var sim2: BattleSimulationScript = BattleSimulationScript.new()
	sim2.initialize(s)
	var w2: BattleWorldScript = sim2.world()
	var ticks_checked: int = 0
	var overlaps: int = 0
	# (1) Tick-by-tick: after every step, build a cell -> id
	# dict from the LIVE world's alive positions.
	while not sim2.is_finished() and ticks_checked < 200:
		var step_events: Array = sim2.step_tick()
		var seen: Dictionary = {}
		var all_alive: Array = w2.alive_ids_by_team(0) + w2.alive_ids_by_team(1)
		for id in all_alive:
			var cell: Vector2i = w2.position_of(int(id))
			if seen.has(cell):
				overlaps += 1
				_assert(false,
					"tick %d: cells overlap at %s (entities %s and %s)" \
					% [ticks_checked, str(cell), str(seen[cell]), str(id)])
			else:
				seen[cell] = int(id)
		# (2) Validate every UNIT_MOVED event in this tick.
		for e in step_events:
			if e.type == BattleEventTypeScript.UNIT_MOVED:
				_assert(e.from_cell != Vector2i(-1, -1),
					"UNIT_MOVED event has from_cell at tick %d" % ticks_checked)
				_assert(e.to_cell != Vector2i(-1, -1),
					"UNIT_MOVED event has to_cell at tick %d" % ticks_checked)
				# Right after this tick, the moving entity's
				# world position must equal e.to_cell.
				var after_pos: Vector2i = w2.position_of(e.source_entity)
				_assert(after_pos == e.to_cell,
					"UNIT_MOVED to_cell=%s but world position after tick=%s (entity %d)" % [str(e.to_cell), str(after_pos), e.source_entity])
				# The from_cell must be where the entity was
				# BEFORE this tick — but the simulation hasn't
				# moved yet, so it's the previous-tick world
				# position. We've already inspected this tick's
				# events so we can't reliably go back; instead
				# assert that e.from_cell is in bounds and that
				# e.from_cell + e.to_cell are adjacent (one
				# Manhattan step apart).
				var dx: int = absi(int(e.to_cell.x) - int(e.from_cell.x))
				var dy: int = absi(int(e.to_cell.y) - int(e.from_cell.y))
				_assert(dx + dy == 1,
					"UNIT_MOVED from/to must be 1 Manhattan step (from=%s to=%s)" % [str(e.from_cell), str(e.to_cell)])
		ticks_checked += 1
	_assert(overlaps == 0, "no cell overlap across all %d ticks (overlaps=%d)" % [ticks_checked, overlaps])
	_assert(sim2.is_finished(), "live simulation reached natural finish")
	_assert(ticks_checked > 0, "live simulation ran at least 1 tick (got %d)" % ticks_checked)


func _test_real_content_same_seed_deterministic() -> void:
	print("[real-6] real_content_same_seed_deterministic")
	var seed: int = _find_seed_for_orc_warrior()
	if seed < 0:
		_assert(false, "could not find orc_warrior seed")
		return
	# Run twice with same seed — same outcome, same tick_count.
	var r1: Dictionary = _run_battle(seed, [&"warrior"], 4)
	var r2: Dictionary = _run_battle(seed, [&"warrior"], 4)
	var res1 = r1.sim.get_result()
	var res2 = r2.sim.get_result()
	_assert(res1.outcome == res2.outcome, "same outcome (got %d vs %d)" % [res1.outcome, res2.outcome])
	_assert(res1.tick_count == res2.tick_count, "same tick count (got %d vs %d)" % [res1.tick_count, res2.tick_count])
	_assert(res1.winner_team == res2.winner_team, "same winner (got %d vs %d)" % [res1.winner_team, res2.winner_team])


func _test_real_content_battle_terminates_naturally() -> void:
	print("[real-7] real_content_battle_terminates_naturally")
	var seed: int = _find_seed_for_orc_warrior()
	if seed < 0:
		_assert(false, "could not find orc_warrior seed")
		return
	var d: Dictionary = _run_battle(seed, [&"warrior"], 4)
	var r = d.sim.get_result()
	# Result must have a defined winner (or both sides eliminated,
	# which counts as natural).
	_assert(r.termination_reason == BattleResultScript.TERMINATION_NATURAL,
		"natural termination (got reason=%d)" % r.termination_reason)
	# Tick count must be bounded and reasonable.
	_assert(r.tick_count < 200, "tick count bounded (got %d)" % r.tick_count)


func _test_real_content_with_pure_tier2_wave() -> void:
	print("[real-8] real_content_with_pure_tier2_wave")
	# Real warrior vs real tier-2 wave (which includes
	# orc_warrior). Wave may include other tier-2 units
	# (skeleton_mage) — that is fine. This is the integration
	# test against the real builder.
	var seed: int = _find_seed_for_orc_warrior()
	if seed < 0:
		_assert(false, "could not find orc_warrior seed")
		return
	var d: Dictionary = _run_battle(seed, [&"warrior"], 4)
	var has_orc: bool = false
	for e in d.setup.enemy_units:
		if e.definition_id == &"orc_warrior":
			has_orc = true
			break
	_assert(has_orc, "tier-2 wave contains orc_warrior (seed=%d)" % seed)
	_assert(d.sim.is_finished(), "real warrior vs tier-2 wave completes")


func _test_real_pure_melee_1v1() -> void:
	print("[real-9] real_pure_melee_1v1 [HIGH 5]")
	# HIGH 5: build an EXACT 1v1 pure-melee setup from REAL
	# UnitDefs (warrior and orc_warrior) with actual content
	# attack_range. No builder; no enemy-wave generation.
	# Proves: real warrior vs real orc_warrior closes range
	# and terminates naturally.
	ContentDBScript.load_all()
	var warrior_def: Resource = ContentDBScript.get_by_id(&"warrior")
	var orc_def: Resource = ContentDBScript.get_by_id(&"orc_warrior")
	_assert(warrior_def != null, "warrior UnitDef loaded from content")
	_assert(orc_def != null, "orc_warrior UnitDef loaded from content")
	_assert(int(warrior_def.attack_range) == 1,
		"real warrior attack_range=1 (got %d)" % int(warrior_def.attack_range))
	_assert(int(orc_def.attack_range) == 1,
		"real orc_warrior attack_range=1 (got %d)" % int(orc_def.attack_range))
	# Build exact 1v1 pure-melee setup at legacy deployment
	# (player at y=3, enemy at y=0).
	var warrior: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"warrior_1", &"warrior", 0, Vector2i(0, 3),
		int(warrior_def.max_hp), int(warrior_def.max_hp),
		int(warrior_def.attack), int(warrior_def.defense), 1)
	var orc: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc_warrior", 1, Vector2i(0, 0),
		int(orc_def.max_hp), int(orc_def.max_hp),
		int(orc_def.attack), int(orc_def.defense), 1)
	var s: BattleSetupScript = BattleSetupScript.new(42, [warrior], [orc], 7, 4)
	_assert(s.validate() == "", "pure-melee 1v1 setup validates (got '%s')" % s.validate())
	# Run the battle once to check natural termination.
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(s)
	var ticks: int = 0
	while not sim.is_finished() and ticks < 500:
		sim.step_tick()
		ticks += 1
	_assert(sim.is_finished(), "pure-melee 1v1 terminates (ticks=%d)" % ticks)
	var r = sim.get_result()
	_assert(r.termination_reason == BattleResultScript.TERMINATION_NATURAL,
		"pure-melee 1v1 terminates NATURALLY (got reason=%d)" % r.termination_reason)
	# Run again to capture events and assert UNIT_MOVED.
	var sim2: BattleSimulationScript = BattleSimulationScript.new()
	sim2.initialize(s)
	var events: Array = []
	while not sim2.is_finished():
		var step_evs: Array = sim2.step_tick()
		for ev in step_evs:
			events.append(ev)
	var saw_movement: bool = false
	for ev in events:
		if ev.type == BattleEventTypeScript.UNIT_MOVED:
			saw_movement = true
			break
	_assert(saw_movement,
		"pure-melee 1v1 emits UNIT_MOVED (movement closed range)")
	# Verify cell-state integrity (tick-by-tick).
	var sim3: BattleSimulationScript = BattleSimulationScript.new()
	sim3.initialize(s)
	var ticks_checked: int = 0
	var overlaps: int = 0
	while not sim3.is_finished() and ticks_checked < 500:
		sim3.step_tick()
		var seen: Dictionary = {}
		for id in sim3.world().alive_ids_by_team(0) + sim3.world().alive_ids_by_team(1):
			var cell: Vector2i = sim3.world().position_of(int(id))
			if seen.has(cell):
				overlaps += 1
			else:
				seen[cell] = int(id)
		ticks_checked += 1
	_assert(overlaps == 0, "no cell overlap in pure-melee 1v1 (overlaps=%d)" % overlaps)
