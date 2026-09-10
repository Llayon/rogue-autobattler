extends SceneTree
## Phase 2 / Gauntlet 12 — performance sanity benchmark.
##
## Runs 100-entity and 500-entity battles against the new
## BattleSimulation. Measures wall time for setup and ticks,
## event count, termination guarantee.
##
## This is INFORMATIONAL. Failures are limited to PATHOlogical
## behavior (non-termination, explosive event growth, O(N^3)
## collapse, repeated-run state leak). No optimization tonight.

const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	# Warm-up with a small VALID battle (HIGH 5 fix: previous warmup
	# used (20, 0, ...) which is invalid).
	_run_scenario(2, 2, 0, true)

	await _test_100_entity_simulation()
	await _test_500_entity_simulation()
	await _test_100_entity_repeated_resets()
	await _test_no_event_explosion()
	print("\n=== performance benchmark: %d passed, %d failed ===\n" % [_passed, _failed])
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


# === Helpers ===

func _run_scenario(player_count: int, enemy_count: int, seed: int, warmup: bool = false) -> Dictionary:
	# Build setup with player_count players on the bottom rows
	# and enemy_count enemies on the top rows. Both sides spread
	# OUTWARD from row 0 (top) / row gh-1 (bottom) so they never
	# collide.
	# Reserve enough rows: ceil(N/7) for players + ceil(N/7) for
	# enemies + 1 separator.
	var ph: int = 1 + (player_count / 7) if player_count > 0 else 1
	var eh: int = 1 + (enemy_count / 7) if enemy_count > 0 else 1
	var gw: int = 7
	var gh: int = ph + eh + 1
	# Benchmark uses a large attack_range so entities engage
	# without movement (which is deferred per Gauntlet 7).
	var benchmark_range: int = maxi(50, gh + 10)
	var players: Array = []
	for i in player_count:
		var col: int = i % 7
		# Players fill bottom-up: lowest row index 0 is enemy territory.
		# Players occupy rows (gh - 1) down to (gh - 1 - ph + 1).
		var row: int = (gh - 1) - (i / 7)
		var hp: int = 80
		var atk: int = 20
		var dfs: int = 5
		players.append(BattleUnitSetupScript.new(
			"p%d" % i, &"warrior", 0, Vector2i(col, row),
			hp, hp, atk, dfs, benchmark_range))
	var enemies: Array = []
	for i in enemy_count:
		var col: int = i % 7
		# Enemies fill top-down: rows 0 to (eh - 1).
		var row: int = (i / 7)
		var hp: int = 30
		var atk: int = 5
		var dfs: int = 2
		enemies.append(BattleUnitSetupScript.new(
			"e%d" % i, &"orc", 1, Vector2i(col, row),
			hp, hp, atk, dfs, benchmark_range))
	# Setup validation may fail if grid too small. Caller should
	# size grid appropriately.
	var s: BattleSetupScript = BattleSetupScript.new(seed, players, enemies, gw, gh)
	var validate_msg: String = s.validate()
	if validate_msg != "":
		return {"valid": false, "msg": validate_msg}
	var sim: BattleSimulationScript = BattleSimulationScript.new()
	var setup_t0: int = Time.get_ticks_usec()
	sim.initialize(s)
	var setup_t1: int = Time.get_ticks_usec()
	var event_count: int = 0
	var ticks: int = 0
	var tick_t0: int = Time.get_ticks_usec()
	while not sim.is_finished() and ticks < 10000:
		var evs: Array = sim.step_tick()
		event_count += evs.size()
		ticks += 1
	var tick_t1: int = Time.get_ticks_usec()
	var finished: bool = sim.is_finished()
	var result = sim.get_result() if finished else null
	return {
		"valid": true,
		"warmup": warmup,
		"setup_us": setup_t1 - setup_t0,
		"tick_us": tick_t1 - tick_t0,
		"ticks": ticks,
		"events": event_count,
		"finished": finished,
		"winner_team": result.winner_team if result != null else -1,
		"outcome": result.outcome if result != null else -1,
		"player_count": player_count,
		"enemy_count": enemy_count,
		"seed": seed,
		"gh": gh,
	}


# === Scenarios ===

func _test_100_entity_simulation() -> void:
	print("[p-1] 100_entity_simulation")
	# 50 players vs 50 enemies.
	var r: Dictionary = _run_scenario(50, 50, 42, false)
	_assert(r.valid, "scenario valid")
	_assert(r.finished, "100-entity simulation terminates (ticks=%d)" % r.ticks)
	# Pathological detection.
	_assert(r.ticks < 5000, "100-entity ticks < 5000 (got %d)" % r.ticks)
	# Event explosion: max 4 events per tick (attack + damage + die + end)
	# → max 4 * ticks events.
	_assert(r.events < r.ticks * 5, "no event explosion (events=%d ticks=%d)" % [r.events, r.ticks])
	print("  [INFO] 100-entity: setup=%.2fms ticks=%d tick_total=%.2fms events=%d winner=%d"
		% [r.setup_us / 1000.0, r.ticks, r.tick_us / 1000.0, r.events, r.winner_team])


func _test_500_entity_simulation() -> void:
	print("[p-2] 500_entity_simulation")
	# 250 players vs 250 enemies.
	var r: Dictionary = _run_scenario(250, 250, 42, false)
	_assert(r.valid, "scenario valid")
	_assert(r.finished, "500-entity simulation terminates (ticks=%d)" % r.ticks)
	_assert(r.ticks < 20000, "500-entity ticks < 20000 (got %d)" % r.ticks)
	_assert(r.events < r.ticks * 5, "no event explosion (events=%d ticks=%d)" % [r.events, r.ticks])
	print("  [INFO] 500-entity: setup=%.2fms ticks=%d tick_total=%.2fms events=%d winner=%d"
		% [r.setup_us / 1000.0, r.ticks, r.tick_us / 1000.0, r.events, r.winner_team])


func _test_100_entity_repeated_resets() -> void:
	print("[p-3] 100_entity_repeated_resets")
	# HIGH 5 fix: previous gate was `min(last_five) <= max(first_five) * 2`
	# which missed worst-case degradation. New gate: max(last_five)
	# MUST NOT exceed max(first_five) by more than 3x.
	var sig_ticks: Array = []
	var sig_events: Array = []
	for i in 30:
		var r: Dictionary = _run_scenario(50, 50, 42 + i, false)
		if not r.finished or not r.valid:
			_assert(false, "reset %d failed to terminate (ticks=%d)" % [i, r.ticks])
			return
		sig_ticks.append(r.ticks)
		sig_events.append(r.events)
	var max_ticks: int = 0
	var max_events: int = 0
	for t in sig_ticks:
		if t > max_ticks:
			max_ticks = t
	for ev in sig_events:
		if ev > max_events:
			max_events = ev
	var first_five: Array = sig_ticks.slice(0, 5)
	var last_five: Array = sig_ticks.slice(sig_ticks.size() - 5, sig_ticks.size())
	var max_first: int = 0
	var max_last: int = 0
	for t in first_five:
		if t > max_first:
			max_first = t
	for t in last_five:
		if t > max_last:
			max_last = t
	_assert(max_ticks < 1000, "all 30 runs terminated with ticks<1000 (max=%d)" % max_ticks)
	_assert(max_events < 5000, "no event explosion across 30 runs (max events=%d)" % max_events)
	# HIGH 5 fix: max-based growth gate. If max_last > max_first * 3
	# the last-5 worst-case is significantly degraded vs first-5.
	var max_threshold: int = maxi(50, max_first * 3)
	_assert(max_last <= max_threshold,
		"last-5 max (%d) <= first-5 max * 3 (threshold=%d)" % [max_last, max_threshold])
	print("  [INFO] 30 sequential resets: ticks range %d-%d, events range %d-%d, last-5 max=%d vs first-5 max=%d (threshold=%d)"
		% [sig_ticks[0], max_ticks, sig_events[0], max_events, max_last, max_first, max_threshold])


func _test_no_event_explosion() -> void:
	print("[p-4] no_event_explosion")
	# Run several 100-entity battles and verify event count
	# stays roughly proportional to ticks (not O(N^2)).
	var max_ratio: float = 0.0
	for i in 5:
		var r: Dictionary = _run_scenario(50, 50, 100 + i, false)
		var ratio: float = float(r.events) / float(maxi(1, r.ticks))
		if ratio > max_ratio:
			max_ratio = ratio
	_assert(max_ratio < 10.0, "events-per-tick stays bounded (max ratio %.2f)" % max_ratio)
	print("  [INFO] max events-per-tick ratio across 5 runs = %.2f" % max_ratio)
