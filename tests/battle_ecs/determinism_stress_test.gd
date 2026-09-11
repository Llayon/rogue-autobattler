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
	await _test_sequential_battles_no_state_leak()
	print("\n=== determinism stress: %d passed, %d failed ===\n" % [_passed, _failed])
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


func _run_full(seed: int) -> Array:
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	sim.initialize(_make_setup(seed))
	var evs: Array = []
	while not sim.is_finished():
		var step_evs: Array = sim.step_tick()
		for e in step_evs:
			evs.append(e)
	return evs


func _normalize_event(e) -> Dictionary:
	# Strip event_id (monotonic but starts at 0 each run) from
	# the normalization comparison — event_id is verified
	# separately as a monotonic invariant. Keep type, tick,
	# source/target entities, source/target run ids, amount,
	# movement coordinates.
	return {
		"type": e.type,
		"tick": e.tick,
		"source_entity": e.source_entity,
		"target_entity": e.target_entity,
		"source_run_unit_id": e.source_run_unit_id,
		"target_run_unit_id": e.target_run_unit_id,
		"amount": e.amount,
		"from_cell": e.from_cell,
		"to_cell": e.to_cell,
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
			# Field-by-field comparison (HIGH 3 fix — Dictionary
			# equality in Godot 4 uses randomized hash, so we
			# cannot rely on `a == b`). Includes tick (HIGH 2
			# fix — same seed must produce same logical event
			# tick).
			if a.type != b.type \
					or a.tick != b.tick \
					or a.source_entity != b.source_entity \
					or a.target_entity != b.target_entity \
					or a.source_run_unit_id != b.source_run_unit_id \
					or a.target_run_unit_id != b.target_run_unit_id \
					or a.amount != b.amount \
					or a.from_cell != b.from_cell \
					or a.to_cell != b.to_cell:
				_assert(false, "run %d event[%d] differs: a=%s b=%s" % [i, j, str(a), str(b)])
				return
	_assert(true, "20 same-seed runs produce identical normalized event traces (%d events)" % first_normalized.size())


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
