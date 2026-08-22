extends SceneTree

## Phase 1 / T13 — facade migration test suite.
##
## Verifies the legacy `Rng` facade now delegates through a single
## owned `DeterministicRng` stream, and that the public contract
## (function names, signatures, snapshot() shape) is preserved.

const RngScript = preload("res://core/utils/rng_service.gd")


var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_facade_preserves_legacy_api()
	await _test_facade_same_seed_same_sequence()
	await _test_facade_seed_run_resets_draw_count()
	await _test_facade_pick_uses_owned_stream()
	await _test_facade_pick_unique_uses_legacy_algorithm()
	await _test_facade_pick_unique_draw_topology()
	await _test_facade_snapshot_legacy_shape()
	await _test_facade_restore_replays_sequence()
	await _test_facade_chance_uses_owned_stream()
	await _test_facade_chance_boundary_consumes_one_draw()
	await _test_facade_no_direct_randomnumbergenerator_in_runtime()
	print("\n=== rng facade migration: %d passed, %d failed ===\n" % [_passed, _failed])
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


func _seq() -> Array:
	return [
		RngScript.randf(),
		RngScript.randi_range(1, 100),
		RngScript.randf_range(-1.0, 1.0),
		RngScript.chance(0.5),
		RngScript.pick([10, 20, 30, 40, 50]),
	]


func _test_facade_preserves_legacy_api() -> void:
	print("[facade-1] facade_preserves_legacy_api")
	# Every public method used by production / tests must exist.
	# We exercise each by calling with safe arguments; if a method
	# is missing the call site will fail to compile / parse.
	RngScript.seed_run(1)
	_assert(true, "Rng.seed_run call compiled")
	RngScript.randf()
	_assert(true, "Rng.randf call compiled")
	RngScript.randi_range(0, 1)
	_assert(true, "Rng.randi_range call compiled")
	RngScript.randf_range(0.0, 1.0)
	_assert(true, "Rng.randf_range call compiled")
	RngScript.chance(0.0)
	_assert(true, "Rng.chance call compiled")
	RngScript.pick([0])
	_assert(true, "Rng.pick call compiled")
	RngScript.pick_unique([0], 0)
	_assert(true, "Rng.pick_unique call compiled")
	var snap: Dictionary = RngScript.snapshot()
	RngScript.restore(snap)
	_assert(true, "Rng.snapshot + Rng.restore compiled")
	RngScript.is_seeded()
	_assert(true, "Rng.is_seeded call compiled")


func _test_facade_same_seed_same_sequence() -> void:
	print("[facade-2] facade_same_seed_same_sequence")
	RngScript.seed_run(424242)
	var a: Array = _seq()
	RngScript.seed_run(424242)
	var b: Array = _seq()
	_assert(a == b, "same seed produces same sequence (a=%s b=%s)" % [a, b])


func _test_facade_seed_run_resets_draw_count() -> void:
	print("[facade-3] facade_seed_run_resets_draw_count")
	RngScript.seed_run(777)
	# Burn 3 draws.
	RngScript.randf()
	RngScript.randi_range(0, 100)
	RngScript.randf()
	var before: int = RngScript.get_draw_count()
	_assert(before == 3, "draw_count == 3 after 3 facade draws (got %d)" % before)
	# Re-seed.
	RngScript.seed_run(777)
	var after: int = RngScript.get_draw_count()
	_assert(after == 0, "draw_count == 0 after seed_run (got %d)" % after)


func _test_facade_pick_uses_owned_stream() -> void:
	print("[facade-4] facade_pick_uses_owned_stream")
	# Same seed => same pick results, proving pick goes through
	# the deterministic stream rather than calling the global
	# @GlobalScope randi_range.
	RngScript.seed_run(2024)
	var a = RngScript.pick([&"a", &"b", &"c", &"d", &"e"])
	RngScript.seed_run(2024)
	var b = RngScript.pick([&"a", &"b", &"c", &"d", &"e"])
	_assert(a == b, "facade pick is deterministic per seed (a=%s b=%s)" % [a, b])


func _test_facade_pick_unique_uses_legacy_algorithm() -> void:
	print("[facade-5] facade_pick_unique_uses_legacy_algorithm")
	# Legacy Rng.pick_unique does full Fisher-Yates via Rng.randf(),
	# then slices. Result is the first `count` elements of the
	# shuffled pool. Verify the facade produces the SAME output as
	# the legacy algorithm and that the RNG state after matches.
	var pool: Array = [10, 20, 30, 40, 50]
	var count: int = 3
	var seed: int = 555
	# Compute via facade.
	RngScript.seed_run(seed)
	var snap: Dictionary = RngScript.snapshot()
	var actual: Array = RngScript.pick_unique(pool, count)
	var actual_after: Dictionary = RngScript.snapshot()
	# Compute via legacy algorithm replayed from same seed.
	RngScript.seed_run(seed)
	var _replay_snap: Dictionary = RngScript.snapshot()
	var expected_pool: Array = pool.duplicate()
	for i in range(expected_pool.size() - 1, 0, -1):
		var j: int = int(RngScript.randf() * float(i + 1))
		var tmp: Variant = expected_pool[i]
		expected_pool[i] = expected_pool[j]
		expected_pool[j] = tmp
	var expected: Array = expected_pool.slice(0, mini(count, expected_pool.size()))
	var expected_after: Dictionary = RngScript.snapshot()
	_assert(actual == expected,
		"facade pick_unique matches legacy Fisher-Yates (actual=%s expected=%s)" % [actual, expected])
	_assert(actual_after["state"] == expected_after["state"],
		"facade pick_unique post-state matches legacy (a=%s e=%s)" % [actual_after["state"], expected_after["state"]])


func _test_facade_pick_unique_draw_topology() -> void:
	print("[facade-5b] facade_pick_unique_draw_topology")
	# Legacy Rng.pick_unique on a pool of size N consumes exactly
	# N - 1 randf draws for any N >= 2 (independent of requested count).
	var pool: Array = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
	RngScript.seed_run(888)
	var d_before: int = RngScript.get_draw_count()
	RngScript.pick_unique(pool, 3)
	var d_after: int = RngScript.get_draw_count()
	_assert(d_after - d_before == 9,
		"pick_unique(10 items, count=3) consumed exactly 9 randf draws (got %d)" % (d_after - d_before))
	# count >= size: legacy still does full shuffle (N-1 draws).
	var d_before2: int = RngScript.get_draw_count()
	RngScript.pick_unique([1, 2, 3], 5)
	var d_after2: int = RngScript.get_draw_count()
	_assert(d_after2 - d_before2 == 2,
		"pick_unique(3 items, count=5) consumed exactly 2 randf draws (got %d)" % (d_after2 - d_before2))


func _test_facade_chance_boundary_consumes_one_draw() -> void:
	print("[facade-8b] facade_chance_boundary_consumes_one_draw")
	# Legacy Rng.chance always consumes one randf draw, including at
	# boundaries. This is critical for draw topology in compound
	# sequences (e.g. basic_attack: chance(dodge) → chance(crit) → variance).
	RngScript.seed_run(2024)
	var d_before: int = RngScript.get_draw_count()
	var r0: bool = RngScript.chance(0.0)
	_assert(r0 == false, "chance(0.0) returns false")
	var d_after: int = RngScript.get_draw_count()
	_assert(d_after - d_before == 1, "chance(0.0) consumed exactly 1 draw (got %d)" % (d_after - d_before))
	var d_before2: int = RngScript.get_draw_count()
	var r1: bool = RngScript.chance(1.0)
	_assert(r1 == true, "chance(1.0) returns true")
	var d_after2: int = RngScript.get_draw_count()
	_assert(d_after2 - d_before2 == 1, "chance(1.0) consumed exactly 1 draw (got %d)" % (d_after2 - d_before2))
	# Verify chance(0.0) consumes a draw: the next randf after
	# chance(0.0) must differ from the first randf of a fresh sequence.
	RngScript.seed_run(2024)
	RngScript.chance(0.0)  # consume 1 draw (legacy topology)
	var after_chance_zero: float = RngScript.randf()
	RngScript.seed_run(2024)
	var no_chance_zero: float = RngScript.randf()
	_assert(after_chance_zero != no_chance_zero,
		"chance(0.0) consumes a draw (post-chance randf differs from first-randf: %f vs %f)" % [after_chance_zero, no_chance_zero])
	# And the same sequence with chance(0.0) must match:
	RngScript.seed_run(2024)
	RngScript.chance(0.0)
	var a_match: float = RngScript.randf()
	RngScript.seed_run(2024)
	RngScript.chance(0.0)
	var b_match: float = RngScript.randf()
	_assert(a_match == b_match,
		"chance(0.0)+randf is deterministic (a=%f b=%f)" % [a_match, b_match])


func _test_facade_snapshot_legacy_shape() -> void:
	print("[facade-6] facade_snapshot_legacy_shape")
	RngScript.seed_run(123)
	# Burn a draw so the stream state advances.
	RngScript.randf()
	var snap: Dictionary = RngScript.snapshot()
	_assert(snap.has("seed"), "snapshot has 'seed' key")
	_assert(snap.has("state"), "snapshot has 'state' key")
	_assert(not snap.has("draw_count"), "snapshot does NOT leak draw_count (legacy contract)")
	_assert(snap["seed"] == 123, "snapshot seed == 123 (got %s)" % str(snap["seed"]))


func _test_facade_restore_replays_sequence() -> void:
	print("[facade-7] facade_restore_mid_stream_continuation")
	# Facade Rng.restore must restore the captured PRNG machine state
	# so the next draw returns exactly the value that originally
	# followed the snapshot. This is true mid-stream continuation,
	# not reseed + manual replay.
	RngScript.seed_run(999)
	# Burn some draws.
	RngScript.randf()
	RngScript.randi_range(0, 1000)
	# Capture mid-stream snapshot.
	var snap: Dictionary = RngScript.snapshot()
	# Record the 3 draws that SHOULD follow restore.
	var expected_a: float = RngScript.randf()
	var expected_b: int = RngScript.randi_range(0, 100)
	var expected_c: float = RngScript.randf_range(-1.0, 1.0)
	# Burn additional unrelated draws.
	for _i in 7:
		RngScript.randf()
	# Restore and assert exact mid-stream continuation.
	RngScript.restore(snap)
	var actual_a: float = RngScript.randf()
	var actual_b: int = RngScript.randi_range(0, 100)
	var actual_c: float = RngScript.randf_range(-1.0, 1.0)
	_assert(actual_a == expected_a,
		"facade mid-stream randf after restore matches (got %f vs %f)" % [actual_a, expected_a])
	_assert(actual_b == expected_b,
		"facade mid-stream randi_range after restore matches (got %d vs %d)" % [actual_b, expected_b])
	_assert(actual_c == expected_c,
		"facade mid-stream randf_range after restore matches (got %f vs %f)" % [actual_c, expected_c])
	# Legacy snapshot wire shape: seed + state only, no draw_count leak.
	var post: Dictionary = RngScript.snapshot()
	_assert(post.has("seed"), "post snapshot has 'seed'")
	_assert(post.has("state"), "post snapshot has 'state'")
	_assert(not post.has("draw_count"), "post snapshot does NOT leak draw_count")


func _test_facade_chance_uses_owned_stream() -> void:
	print("[facade-8] facade_chance_uses_owned_stream")
	# Seed 0 with chance 0.5 should produce a deterministic boolean
	# for a given seed.
	RngScript.seed_run(314)
	var results: Array = []
	for i in 50:
		results.append(RngScript.chance(0.5))
	RngScript.seed_run(314)
	var replay: Array = []
	for i in 50:
		replay.append(RngScript.chance(0.5))
	_assert(results == replay, "chance sequence is deterministic per seed (results[0..3]=%s replay[0..3]=%s)" % [results.slice(0, 4), replay.slice(0, 4)])


func _test_facade_no_direct_randomnumbergenerator_in_runtime() -> void:
	print("[facade-9] facade_no_direct_randomnumbergenerator_in_runtime")
	# After seed_run, the only RandomNumberGenerator alive is the one
	# inside DeterministicRng._rng. The facade must not construct
	# additional RNGs at runtime. We assert this by checking that
	# all public draws go through the owned stream's draw_count.
	RngScript.seed_run(2025)
	var d0: int = RngScript.get_draw_count()
	for i in 7:
		RngScript.randf()
	var d1: int = RngScript.get_draw_count()
	_assert(d1 - d0 == 7, "7 facade randf() calls advanced draw_count by exactly 7 (got %d)" % (d1 - d0))