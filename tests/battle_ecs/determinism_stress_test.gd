extends SceneTree
## Phase 2 / Gauntlet 4 (deep) — determinism stress pass.

const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const BattleResultScript = preload("res://core/battle_ecs/battle_result.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_same_seed_twenty_runs_identical_result()
	await _test_same_seed_twenty_runs_identical_event_trace()
	await _test_event_id_strictly_monotonic_within_one_run()
	await _test_event_id_starts_at_one_and_increments_by_one()
	await _test_event_id_identical_across_same_seed_runs()
	await _test_interleaved_two_independent_simulations()
	await _test_same_seed_movement_trace_identical()
	await _test_sequential_battles_no_state_leak()
	print("\n=== determinism stress: %d passed, %d failed ===\n" % [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  [OK]   %s" % label)
	else:
		_failed += 1
		print("  [FAIL] %s" % label)


func _make_setup(seed: int) -> BattleSetupScript:
	var p1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p1", &"warrior", 0, Vector2i(0, 1), 80, 80, 20, 5, 5)
	var p2: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p2", &"warrior", 0, Vector2i(2, 1), 80, 80, 20, 5, 5)
	var e1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var e2: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(2, 0), 80, 80, 20, 5, 5)
	return BattleSetupScript.new(seed, [p1, p2], [e1, e2], 7, 4)


## Movement-REQUIRED fixture for the determinism proof.
##
## The combat fixture above uses attack_range = 5, so every unit
## already starts within range of its nearest opponent and the
## scheduler NEVER moves: no UNIT_MOVE_STARTED and no UNIT_MOVED
## are ever emitted. The event-trace determinism check therefore
## never exercised a movement coordinate.
##
## This fixture forces movement:
##   grid 7x4
##   p1 = (0, 3)  p2 = (2, 3)   (player)
##   e1 = (0, 0)  e2 = (2, 0)   (enemy)
##   attack_range = 1
##
## Manhattan distance p1 -> e1 is 3, so both sides start OUT of
## range and the scheduler must step toward each other. All four
## cells are distinct.
func _make_movement_setup(seed: int) -> BattleSetupScript:
	var p1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p1", &"warrior", 0, Vector2i(0, 3), 80, 80, 20, 5, 1)
	var p2: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p2", &"warrior", 0, Vector2i(2, 3), 80, 80, 20, 5, 1)
	var e1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 1)
	var e2: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(2, 0), 80, 80, 20, 5, 1)
	return BattleSetupScript.new(seed, [p1, p2], [e1, e2], 7, 4)


## Second movement fixture with a DIAGONAL offset.
##
## The first fixture is purely axial in Y: every mover shares a
## column with its nearest enemy, so the trace never contains an
## X step and never observes the axis priority.
##
## This fixture gives p1 the offset dx = 1, dy = -3 towards e1,
## so |dy| > |dx| and the canonical planner steps Y. An X-first
## planner would step X instead (the cell (1, 3) is free), so
## this fixture makes the movement trace sensitive to the axis
## priority. The trace also contains genuine X steps later in the
## battle, so both axes are exercised.
func _make_diagonal_movement_setup(seed: int) -> BattleSetupScript:
	var p1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p1", &"warrior", 0, Vector2i(0, 3), 80, 80, 20, 5, 1)
	var p2: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"p2", &"warrior", 0, Vector2i(4, 3), 80, 80, 20, 5, 1)
	var e1: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(1, 0), 80, 80, 20, 5, 1)
	var e2: BattleUnitSetupScript = BattleUnitSetupScript.new(
		"", &"orc", 1, Vector2i(5, 0), 80, 80, 20, 5, 1)
	return BattleSetupScript.new(seed, [p1, p2], [e1, e2], 7, 4)


## Runs a full battle with the movement fixture and returns the
## events.
func _run_movement_full(seed: int) -> Array:
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(_make_movement_setup(seed))
	var evs: Array = []
	var ticks: int = 0
	while not sim.is_finished() and ticks < 400:
		ticks += 1
		var step_evs: Array = sim.step_tick()
		for e in step_evs:
			evs.append(e)
	return evs


## Same runner for the diagonal fixture.
func _run_diagonal_movement_full(seed: int) -> Array:
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(_make_diagonal_movement_setup(seed))
	var evs: Array = []
	var ticks: int = 0
	while not sim.is_finished() and ticks < 400:
		ticks += 1
		var step_evs: Array = sim.step_tick()
		for e in step_evs:
			evs.append(e)
	return evs


func _run_full(seed: int) -> Array:
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(_make_setup(seed))
	var evs: Array = []
	while not sim.is_finished():
		var step_evs: Array = sim.step_tick()
		for e in step_evs:
			evs.append(e)
	return evs


## B2.1 normalizes the full BattleEvent shape including
## ancestry. Same-seed runs MUST produce identical normalized
## output. event_id starts at 1 (per B2.1 emitter contract);
## root_action_id is the canonical root identifier (starts at
## 1); parent_event_id / chain_depth establish ancestry.
func _normalize_event(e) -> Dictionary:
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
		"from_cell": Vector2i(int(e.from_cell.x), int(e.from_cell.y)),
		"to_cell": Vector2i(int(e.to_cell.x), int(e.to_cell.y)),
		"parent_event_id": int(e.parent_event_id),
		"root_action_id": int(e.root_action_id),
		"chain_depth": int(e.chain_depth),
	}


# === Tests ===

func _test_same_seed_twenty_runs_identical_result() -> void:
	print("[d-1] same_seed_twenty_runs_identical_result")
	var seed: int = 12345
	var first_outcome: int = -999
	var first_winner: int = -999
	var first_ticks: int = -1
	for i in 20:
		var sim: BattleSimulationScript = BattleSimulationScript.new()
		sim.initialize(_make_setup(seed))
		var ticks: int = 0
		while not sim.is_finished():
			sim.step_tick()
			ticks += 1
		var r = sim.get_result()
		if i == 0:
			first_outcome = r.outcome
			first_winner = r.winner_team
			first_ticks = ticks
		else:
			if r.outcome != first_outcome:
				_assert(false, "run %d outcome differs (got %d expected %d)" % [i, r.outcome, first_outcome])
				return
			if r.winner_team != first_winner:
				_assert(false, "run %d winner differs (got %d expected %d)" % [i, r.winner_team, first_winner])
				return
			if ticks != first_ticks:
				_assert(false, "run %d ticks differs (got %d expected %d)" % [i, ticks, first_ticks])
				return
	_assert(true, "20 same-seed runs produce identical (outcome, winner, ticks)")


func _test_same_seed_twenty_runs_identical_event_trace() -> void:
	print("[d-2] same_seed_twenty_runs_identical_event_trace")
	var seed: int = 12345
	var first_events: Array = _run_full(seed)
	var first_normalized: Array = []
	for e in first_events:
		first_normalized.append(_normalize_event(e))
	for i in 20:
		var events: Array = _run_full(seed)
		var normalized: Array = []
		for e in events:
			normalized.append(_normalize_event(e))
		if normalized.size() != first_normalized.size():
			_assert(false, "run %d event count differs (got %d expected %d)" % [i, normalized.size(), first_normalized.size()])
			return
		for j in normalized.size():
			var a = first_normalized[j]
			var b = normalized[j]
			# B2.2: field-by-field comparison of ALL 14 normalized
			# fields. Dictionary equality in Godot 4 uses
			# randomized hash so `a == b` is forbidden.
			var diff: String = _normalized_events_field_diff(a, b)
			if diff != "":
				_assert(false, "run %d event[%d] differs: %s" % [i, j, diff])
				return
	_assert(true, "20 same-seed runs produce identical normalized event traces (all 14 fields, %d events)" % first_normalized.size())


## B2.2: returns the empty string if a and b are field-for-field
## equal on every normalized field. Returns a human-readable
## diff string on the first mismatch.
func _normalized_events_field_diff(a, b) -> String:
	var fields: Array = [
		"event_id", "type", "tick",
		"source_entity", "target_entity",
		"source_run_unit_id", "target_run_unit_id",
		"amount", "tag",
		"from_cell", "to_cell",
		"parent_event_id", "root_action_id", "chain_depth",
	]
	for f in fields:
		if not b.has(f):
			return "missing field '%s' in b" % f
		var av = a.get(f)
		var bv = b.get(f)
		if typeof(av) != typeof(bv):
			return "field '%s' type differs (a=%s b=%s)" % [f, str(av), str(bv)]
		if av is Vector2i:
			if int(av.x) != int(bv.x) or int(av.y) != int(bv.y):
				return "field '%s' differs (a=%s b=%s)" % [f, str(av), str(bv)]
		else:
			if av != bv:
				return "field '%s' differs (a=%s b=%s)" % [f, str(av), str(bv)]
	return ""


# === HIGH 2 / event_id monotonic invariant ===

func _test_event_id_strictly_monotonic_within_one_run() -> void:
	print("[d-3] event_id_strictly_monotonic_within_one_run")
	# Within a single simulation run, event_id must be strictly
	# increasing. Each event_id is unique and greater than the
	# previous event's id.
	var events: Array = _run_full(42)
	_assert(events.size() > 0, "run produced events (got %d)" % events.size())
	var prev_id: int = -1
	var monotonic: bool = true
	for e in events:
		var eid: int = int(e.event_id)
		if eid <= prev_id:
			monotonic = false
			_assert(false, "event_id not strictly increasing at idx %d (got %d after %d)" % [events.find(e), eid, prev_id])
			return
		prev_id = eid
	_assert(monotonic, "event_id strictly monotonic across %d events" % events.size())


func _test_event_id_starts_at_one_and_increments_by_one() -> void:
	print("[d-4] event_id_starts_at_one_and_increments_by_one")
	# First event must have event_id == 1. Each subsequent
	# event_id must equal the previous event_id + 1 (no gaps).
	var events: Array = _run_full(42)
	_assert(events.size() > 0, "run produced events (got %d)" % events.size())
	_assert(int(events[0].event_id) == 1,
		"first event_id == 1 (got %d)" % int(events[0].event_id))
	for j in range(1, events.size()):
		var prev: int = int(events[j - 1].event_id)
		var cur: int = int(events[j].event_id)
		_assert(cur == prev + 1,
			"event[%d].event_id == event[%d].event_id + 1 (got %d vs %d)" % [j, j - 1, cur, prev])


func _test_event_id_identical_across_same_seed_runs() -> void:
	print("[d-5] event_id_identical_across_same_seed_runs")
	# Same seed must produce event_ids that are identical at
	# every position across runs (proves event_id allocation
	# is deterministic, not just monotonic).
	var first_events: Array = _run_full(42)
	for i in range(1, 20):
		var events: Array = _run_full(42)
		_assert(events.size() == first_events.size(),
			"run %d event count matches (got %d vs %d)" % [i, events.size(), first_events.size()])
		for j in events.size():
			if int(events[j].event_id) != int(first_events[j].event_id):
				_assert(false, "run %d event[%d].event_id differs (got %d vs %d)" % [i, j, int(events[j].event_id), int(first_events[j].event_id)])
				return
	_assert(true, "20 same-seed runs produce identical event_id sequence")


func _test_interleaved_two_independent_simulations() -> void:
	print("[d-3] interleaved_two_independent_simulations")
	# Run sim A and sim B interleaved, one tick at a time.
	# Results must equal running each alone.
	var sim_a: BattleSimulationScript = BattleSimulationScript.new()
	sim_a.initialize(_make_setup(111))
	var sim_b: BattleSimulationScript = BattleSimulationScript.new()
	sim_b.initialize(_make_setup(222))
	var evs_a: Array = []
	var evs_b: Array = []
	var ticks: int = 0
	while (not sim_a.is_finished() or not sim_b.is_finished()) and ticks < 1000:
		if not sim_a.is_finished():
			for e in sim_a.step_tick():
				evs_a.append(e)
		if not sim_b.is_finished():
			for e in sim_b.step_tick():
				evs_b.append(e)
		ticks += 1
	# Now run each alone for comparison.
	var sim_a2: BattleSimulationScript = BattleSimulationScript.new()
	sim_a2.initialize(_make_setup(111))
	var evs_a2: Array = []
	while not sim_a2.is_finished():
		for e in sim_a2.step_tick():
			evs_a2.append(e)
	var sim_b2: BattleSimulationScript = BattleSimulationScript.new()
	sim_b2.initialize(_make_setup(222))
	var evs_b2: Array = []
	while not sim_b2.is_finished():
		for e in sim_b2.step_tick():
			evs_b2.append(e)
	# Normalize and compare.
	var norm_a: Array = []
	for e in evs_a:
		norm_a.append(_normalize_event(e))
	var norm_a2: Array = []
	for e in evs_a2:
		norm_a2.append(_normalize_event(e))
	var norm_b: Array = []
	for e in evs_b:
		norm_b.append(_normalize_event(e))
	var norm_b2: Array = []
	for e in evs_b2:
		norm_b2.append(_normalize_event(e))
	if norm_a.size() != norm_a2.size():
		_assert(false, "A: interleaved event count %d != alone %d" % [norm_a.size(), norm_a2.size()])
		return
	for i in norm_a.size():
		var a = norm_a[i]
		var b = norm_a2[i]
		if a.type != b.type or a.amount != b.amount or a.source_entity != b.source_entity:
			_assert(false, "A: event[%d] differs" % i)
			return
	if norm_b.size() != norm_b2.size():
		_assert(false, "B: interleaved event count %d != alone %d" % [norm_b.size(), norm_b2.size()])
		return
	for i in norm_b.size():
		var a = norm_b[i]
		var b = norm_b2[i]
		if a.type != b.type or a.amount != b.amount or a.source_entity != b.source_entity:
			_assert(false, "B: event[%d] differs" % i)
			return
	_assert(true, "interleaved A and B match alone A and alone B")


func _test_sequential_battles_no_state_leak() -> void:
	print("[d-4] sequential_battles_no_state_leak")
	# Run 5 battles with DIFFERENT seeds. The 5th should not
	# leak state from the first 4.
	var first_sim: BattleSimulationScript = BattleSimulationScript.new()
	first_sim.initialize(_make_setup(99999))
	while not first_sim.is_finished():
		first_sim.step_tick()
	var first_outcome: int = first_sim.get_result().outcome
	var first_ticks: int = first_sim.get_result().tick_count
	# Now run several intermediate sims.
	for i in 10:
		var sim: BattleSimulationScript = BattleSimulationScript.new()
		sim.initialize(_make_setup(50000 + i))
		while not sim.is_finished():
			sim.step_tick()
	# Run the same setup as first again.
	var repeat_sim: BattleSimulationScript = BattleSimulationScript.new()
	repeat_sim.initialize(_make_setup(99999))
	while not repeat_sim.is_finished():
		repeat_sim.step_tick()
	var repeat_outcome: int = repeat_sim.get_result().outcome
	var repeat_ticks: int = repeat_sim.get_result().tick_count
	_assert(repeat_outcome == first_outcome,
		"repeat outcome matches (got %d expected %d)" % [repeat_outcome, first_outcome])
	_assert(repeat_ticks == first_ticks,
		"repeat ticks matches (got %d expected %d)" % [repeat_ticks, first_ticks])

# === Movement determinism ===

## Same seed + same movement-REQUIRED setup must produce an
## identical ordered UNIT_MOVED trace.
##
## The existing d-2 trace comparison already compares every
## normalized field, but its fixture never moves, so it never
## compared a movement coordinate. This test runs a dedicated
## movement fixture and compares the UNIT_MOVED subset field by
## field, reusing the existing _normalized_events_field_diff()
## comparator (no second comparator is introduced).
func _test_same_seed_movement_trace_identical() -> void:
	print("[d-8] same_seed_movement_trace_identical")
	var seed: int = 12345

	# --- fixture sanity: no duplicate cells ---------------------
	var setup: BattleSetupScript = _make_movement_setup(seed)
	_assert(setup.validate() == "",
		"d-8: the movement setup is valid ('%s')" % setup.validate())
	var cells: Array = [
		Vector2i(0, 3), Vector2i(2, 3), Vector2i(0, 0), Vector2i(2, 0),
		Vector2i(4, 3), Vector2i(1, 0), Vector2i(5, 0)]
	var unique_cells: Dictionary = {}
	for c in cells:
		unique_cells[c] = true
	_assert(unique_cells.size() == cells.size(),
		"d-8: the movement fixtures have no duplicate cells")

	# --- the vertical fixture ------------------------------------
	var first_events: Array = _run_movement_full(seed)
	var first_moves: Array = _collect_moves(first_events)
	var first_starts: int = _count_starts(first_events)

	# --- anti-vacuity: the fixture MUST really move --------------
	_assert(first_moves.size() > 0,
		"d-8: the movement fixture emits UNIT_MOVED (got %d)"
			% first_moves.size())
	_assert(first_starts > 0,
		"d-8: the movement fixture emits UNIT_MOVE_STARTED (got %d)"
			% first_starts)

	# --- 20 same-seed runs must agree on the movement trace ------
	var same: bool = _assert_same_seed_movement_trace(
		seed, first_moves, _run_movement_full)
	_assert(same,
		"d-8: 20 same-seed runs produce an identical ordered UNIT_MOVED trace (%d moves; tick, from_cell, to_cell, order and ancestry all compared)" % first_moves.size())
	if not same:
		return

	# --- the diagonal fixture: the same contract, both axes ---
	var h_events: Array = _run_diagonal_movement_full(seed)
	var h_moves: Array = _collect_moves(h_events)
	var h_starts: int = _count_starts(h_events)
	_assert(h_moves.size() > 0,
		"d-8: the diagonal movement fixture emits UNIT_MOVED (got %d)"
			% h_moves.size())
	_assert(h_starts > 0,
		"d-8: the diagonal movement fixture emits UNIT_MOVE_STARTED (got %d)"
			% h_starts)
	if h_moves.is_empty():
		return

	var h_same: bool = _assert_same_seed_movement_trace(
		seed, h_moves, _run_diagonal_movement_full)
	_assert(h_same,
		"d-8: 20 same-seed runs of the diagonal fixture produce an identical ordered UNIT_MOVED trace (%d moves)" % h_moves.size())
	if not h_same:
		return

	# --- the compared fields are explicitly non-trivial ----------
	# A trace where every movement shared one tick and one
	# coordinate would prove nothing about tick / from_cell /
	# to_cell sensitivity. Require real variation.
	var distinct_ticks: Dictionary = {}
	var distinct_from: Dictionary = {}
	var distinct_to: Dictionary = {}
	for m in first_moves:
		distinct_ticks[int(m["tick"])] = true
		distinct_from[m["from_cell"]] = true
		distinct_to[m["to_cell"]] = true
	_assert(distinct_ticks.size() > 1,
		"d-8: the movement trace spans more than one tick (got %d)"
			% distinct_ticks.size())
	_assert(distinct_from.size() > 1,
		"d-8: the movement trace has more than one from_cell (got %d)"
			% distinct_from.size())
	_assert(distinct_to.size() > 1,
		"d-8: the movement trace has more than one to_cell (got %d)"
			% distinct_to.size())

	# --- the diagonal fixture really exercises the X axis ------
	var x_steps: int = 0
	var y_steps: int = 0
	for m in h_moves:
		var dx: int = int(m["to_cell"].x) - int(m["from_cell"].x)
		var dy: int = int(m["to_cell"].y) - int(m["from_cell"].y)
		if dx != 0:
			x_steps += 1
		if dy != 0:
			y_steps += 1
	_assert(x_steps > 0,
		"d-8: the diagonal fixture produces X-axis steps (got %d)" % x_steps)
	_assert(y_steps > 0,
		"d-8: the diagonal fixture produces Y-axis steps (got %d)" % y_steps)

	# --- the trace is SENSITIVE to the axis priority ------------
	# The first move of the diagonal fixture starts at (0, 3)
	# towards e1 at (1, 0): dx = 1, dy = -3, so |dy| > |dx| and
	# the canonical planner steps Y. The X neighbour (1, 3) is
	# free, so an X-first planner would step there instead. The
	# trace therefore depends on the axis priority, and a
	# comparator that only compared the event COUNT could not
	# see a priority inversion.
	var first_diagonal = h_moves[0]
	_assert(int(first_diagonal["from_cell"].x) == 0
			and int(first_diagonal["from_cell"].y) == 3,
		"d-8: the diagonal trace starts at (0, 3) (got %s)"
			% str(first_diagonal["from_cell"]))
	_assert(int(first_diagonal["to_cell"].x) == 0
			and int(first_diagonal["to_cell"].y) == 2,
		"d-8: the canonical planner takes the Y step (0, 3) -> (0, 2) (got %s)"
			% str(first_diagonal["to_cell"]))

	# --- every UNIT_MOVED is a CHILD of a UNIT_MOVE_STARTED ----
	var orphan_moves: int = _count_orphans(first_events, first_moves)
	_assert(orphan_moves == 0,
		"d-8: every UNIT_MOVED is a child of a UNIT_MOVE_STARTED (orphans: %d)" % orphan_moves)

## Collects the normalized UNIT_MOVED events.
func _collect_moves(events: Array) -> Array:
	var moves: Array = []
	for e in events:
		if int(e.type) == int(BattleEventTypeScript.UNIT_MOVED):
			moves.append(_normalize_event(e))
	return moves


## Counts the UNIT_MOVE_STARTED events.
func _count_starts(events: Array) -> int:
	var n: int = 0
	for e in events:
		if int(e.type) == int(BattleEventTypeScript.UNIT_MOVE_STARTED):
			n += 1
	return n


## Counts UNIT_MOVED events whose parent is not a
## UNIT_MOVE_STARTED.
func _count_orphans(events: Array, moves: Array) -> int:
	var start_ids: Dictionary = {}
	for e in events:
		if int(e.type) == int(BattleEventTypeScript.UNIT_MOVE_STARTED):
			start_ids[int(e.event_id)] = true
	var orphans: int = 0
	for m in moves:
		if not start_ids.has(int(m["parent_event_id"])):
			orphans += 1
	return orphans


## Runs the movement battle 20 times with the same seed and
## asserts that every UNIT_MOVED field matches the first run.
## Returns false on the first divergence (the assertion has
## already been reported).
func _assert_same_seed_movement_trace(seed: int, first_moves: Array, runner) -> bool:
	for i in range(1, 20):
		var events: Array = runner.call(seed)
		var moves: Array = _collect_moves(events)
		if moves.size() != first_moves.size():
			_assert(false,
				"d-8: run %d UNIT_MOVED count differs (got %d expected %d)"
					% [i, moves.size(), first_moves.size()])
			return false
		for j in moves.size():
			var diff: String = _normalized_events_field_diff(
				first_moves[j], moves[j])
			if diff != "":
				_assert(false,
					"d-8: run %d UNIT_MOVED[%d] differs: %s"
						% [i, j, diff])
				return false
	return true
