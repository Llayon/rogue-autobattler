extends SceneTree

## Phase 1 / T14 — DeterministicRng test suite.
##
## Required assertions per work order:
## 1. same seed -> same sequence
## 2. different seed -> different meaningful sample
## 3. reseed same seed -> same sequence again
## 4. draw_count starts 0
## 5. randi_range increments draw_count
## 6. randf_range increments draw_count
## 7. range boundaries valid
## 8. deterministic pick
## 9. deterministic shuffle
## 10. facade same seed -> same sequence
## 11. facade reseed resets draw_count
## 12. no randomize in deterministic layer
## 13. legacy characterization still green (separate file)

const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")


var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_same_seed_same_sequence()
	await _test_different_seed_different_sample()
	await _test_reseed_reproduces_sequence()
	await _test_draw_count_starts_at_zero()
	await _test_randi_range_increments_draw_count()
	await _test_randf_range_increments_draw_count()
	await _test_range_boundaries_valid()
	await _test_deterministic_pick()
	await _test_deterministic_shuffle()
	await _test_pick_unique_determinism()
	await _test_snapshot_restore_round_trip()
	await _test_no_randomize_in_deterministic_layer()
	await _test_chance_zero_consumes_one_draw()
	await _test_chance_one_consumes_one_draw()
	await _test_chance_half_consumes_one_draw()
	await _test_pick_unique_actual_draw_contract()
	print("\n=== deterministic rng: %d passed, %d failed ===\n" % [_passed, _failed])
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


func _seq(rng: DeterministicRngScript) -> Array:
	return [
		rng.randi_range(1, 1000),
		rng.randi_range(-50, 50),
		rng.randf(),
		rng.randf_range(-1.0, 1.0),
		rng.chance(0.5),
		rng.pick([&"a", &"b", &"c", &"d", &"e"]),
	]


func _test_same_seed_same_sequence() -> void:
	print("[rng-1] same_seed_same_sequence")
	var a: DeterministicRngScript = DeterministicRngScript.new(12345)
	var b: DeterministicRngScript = DeterministicRngScript.new(12345)
	var sa: Array = _seq(a)
	var sb: Array = _seq(b)
	_assert(sa == sb, "identical seed produces identical sequence (a=%s b=%s)" % [sa, sb])


func _test_different_seed_different_sample() -> void:
	print("[rng-2] different_seed_different_sample")
	var a: DeterministicRngScript = DeterministicRngScript.new(12345)
	var b: DeterministicRngScript = DeterministicRngScript.new(67890)
	var sa: Array = _seq(a)
	var sb: Array = _seq(b)
	_assert(sa != sb, "different seeds produce different sequences (a=%s b=%s)" % [sa, sb])


func _test_reseed_reproduces_sequence() -> void:
	print("[rng-3] reseed_reproduces_sequence")
	var a: DeterministicRngScript = DeterministicRngScript.new(424242)
	var sa: Array = _seq(a)
	# Burn extra draws to advance state.
	for _i in 20:
		a.randf()
	# Re-seed and re-draw.
	a.seed_with(424242)
	var sb: Array = _seq(a)
	_assert(sa == sb, "reseed reproduces sequence (a=%s b=%s)" % [sa, sb])


func _test_draw_count_starts_at_zero() -> void:
	print("[rng-4] draw_count_starts_at_zero")
	var rng: DeterministicRngScript = DeterministicRngScript.new(1)
	_assert(rng.draw_count == 0, "fresh draw_count == 0 (got %d)" % rng.draw_count)
	rng.randi_range(1, 2)
	_assert(rng.draw_count == 1, "draw_count == 1 after one randi_range (got %d)" % rng.draw_count)


func _test_randi_range_increments_draw_count() -> void:
	print("[rng-5] randi_range_increments_draw_count")
	var rng: DeterministicRngScript = DeterministicRngScript.new(7)
	for i in 10:
		rng.randi_range(0, 100)
	_assert(rng.draw_count == 10, "10 randi_range -> draw_count == 10 (got %d)" % rng.draw_count)


func _test_randf_range_increments_draw_count() -> void:
	print("[rng-6] randf_range_increments_draw_count")
	var rng: DeterministicRngScript = DeterministicRngScript.new(7)
	for i in 5:
		rng.randf_range(0.0, 1.0)
	_assert(rng.draw_count == 5, "5 randf_range -> draw_count == 5 (got %d)" % rng.draw_count)
	# randf() also increments.
	rng.randf()
	_assert(rng.draw_count == 6, "1 randf -> draw_count == 6 (got %d)" % rng.draw_count)


func _test_range_boundaries_valid() -> void:
	print("[rng-7] range_boundaries_valid")
	var rng: DeterministicRngScript = DeterministicRngScript.new(99)
	for i in 200:
		var v: int = rng.randi_range(10, 20)
		_assert(v >= 10 and v <= 20, "randi_range(10,20) in [10,20] (got %d)" % v)
		var f: float = rng.randf_range(0.0, 1.0)
		_assert(f >= 0.0 and f < 1.0, "randf_range(0,1) in [0,1) (got %f)" % f)


func _test_deterministic_pick() -> void:
	print("[rng-8] deterministic_pick")
	var a: DeterministicRngScript = DeterministicRngScript.new(42)
	var b: DeterministicRngScript = DeterministicRngScript.new(42)
	var pool: Array = [&"a", &"b", &"c", &"d", &"e"]
	var pa: Array = []
	var pb: Array = []
	for i in 5:
		pa.append(a.pick(pool))
		pb.append(b.pick(pool))
	_assert(pa == pb, "pick sequences identical (a=%s b=%s)" % [pa, pb])
	# Empty pool -> null, no draw.
	var empty: Array = []
	_assert(a.pick(empty) == null, "pick on empty array returns null")
	_assert(a.draw_count == 5, "pick on empty array does not consume draw (draw_count == 5)")


func _test_deterministic_shuffle() -> void:
	print("[rng-9] deterministic_shuffle")
	var a: DeterministicRngScript = DeterministicRngScript.new(7)
	var b: DeterministicRngScript = DeterministicRngScript.new(7)
	var sa: Array = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
	var sb: Array = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
	a.shuffle_in_place(sa)
	b.shuffle_in_place(sb)
	_assert(sa == sb, "shuffle_in_place produces identical permutation (a=%s b=%s)" % [sa, sb])
	# Draw count: n - 1 swaps, each +1 draw.
	_assert(a.draw_count == 9, "shuffle(10 items) consumed 9 draws (got %d)" % a.draw_count)
	# Empty / 1-element arrays consume 0 draws.
	var empty: Array = []
	var one: Array = [42]
	a.shuffle_in_place(empty)
	a.shuffle_in_place(one)
	_assert(a.draw_count == 9, "empty / 1-element shuffle does not consume draw (draw_count still 9)")


func _test_pick_unique_determinism() -> void:
	print("[rng-10] pick_unique_determinism")
	var a: DeterministicRngScript = DeterministicRngScript.new(11)
	var b: DeterministicRngScript = DeterministicRngScript.new(11)
	var pool: Array = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
	var pa: Array = a.pick_unique(pool, 5)
	var pb: Array = b.pick_unique(pool, 5)
	_assert(pa == pb, "pick_unique identical (a=%s b=%s)" % [pa, pb])
	# 5 unique elements drawn from a 15-element pool.
	_assert(pa.size() == 5, "picked 5 elements (got %d)" % pa.size())
	# All picked elements are distinct.
	for i in pa.size():
		for j in range(i + 1, pa.size()):
			_assert(pa[i] != pa[j], "picked elements are distinct (i=%d j=%d)" % [i, j])


func _test_snapshot_restore_round_trip() -> void:
	print("[rng-11] snapshot_restore_round_trip")
	var rng: DeterministicRngScript = DeterministicRngScript.new(123)
	var snap: Dictionary = rng.snapshot()
	# Burn draws.
	for _i in 5:
		rng.randi_range(0, 100)
	# Restore.
	rng.restore(snap)
	_assert(rng.draw_count == 0, "draw_count == 0 after restore (got %d)" % rng.draw_count)
	_assert(rng.seed_value == 123, "seed_value == 123 after restore (got %d)" % rng.seed_value)
	# The next draws after restore should equal the first draws of a
	# fresh instance with the same seed.
	var fresh: DeterministicRngScript = DeterministicRngScript.new(123)
	var a: Array = []
	var b: Array = []
	for i in 5:
		a.append(rng.randi_range(0, 100))
		b.append(fresh.randi_range(0, 100))
	_assert(a == b, "post-restore draws match fresh-seed draws (a=%s b=%s)" % [a, b])


func _test_no_randomize_in_deterministic_layer() -> void:
	print("[rng-12] no_randomize_in_deterministic_layer")
	# Read the source file and assert that the file does not call
	# `randomize()`. Source-level guard so future edits to the
	# deterministic layer can't silently introduce non-determinism.
	var f: FileAccess = FileAccess.open(
		"res://core/rng/deterministic_rng.gd", FileAccess.READ)
	_assert(f != null, "core/rng/deterministic_rng.gd is readable")
	if f == null:
		return
	var src: String = f.get_as_text()
	f.close()
	# Check that the class does not call randomize() in executable code.
	# We strip lines that are pure comments/docstrings to avoid false
	# positives on documentation that mentions the word.
	var executable: String = ""
	for line in src.split("\n"):
		var stripped: String = line.strip_edges()
		if stripped.begins_with("#") or stripped.begins_with("##"):
			continue
		executable += line + "\n"
	_assert(not executable.contains("randomize("),
		"deterministic_rng.gd does NOT call randomize() in executable code")
	# The RNG is owned by the script and constructed in _init.
	_assert(src.contains("_rng = RandomNumberGenerator.new()") or src.contains("_rng=RandomNumberGenerator.new()"),
		"deterministic_rng.gd constructs the owned RNG in _init")
	_assert(src.contains("var _rng: RandomNumberGenerator"),
		"deterministic_rng.gd owns a single _rng field")

func _test_chance_zero_consumes_one_draw() -> void:
	print("[rng-chance-0] chance_zero_consumes_one_draw")
	var rng: DeterministicRngScript = DeterministicRngScript.new(42)
	var before: int = rng.draw_count
	var result: bool = rng.chance(0.0)
	_assert(result == false, "chance(0.0) returns false")
	_assert(rng.draw_count == before + 1, "chance(0.0) consumed exactly +1 draw (before=%d after=%d)" % [before, rng.draw_count])


func _test_chance_one_consumes_one_draw() -> void:
	print("[rng-chance-1] chance_one_consumes_one_draw")
	var rng: DeterministicRngScript = DeterministicRngScript.new(42)
	var before: int = rng.draw_count
	var result: bool = rng.chance(1.0)
	_assert(result == true, "chance(1.0) returns true")
	_assert(rng.draw_count == before + 1, "chance(1.0) consumed exactly +1 draw (before=%d after=%d)" % [before, rng.draw_count])


func _test_chance_half_consumes_one_draw() -> void:
	print("[rng-chance-05] chance_half_consumes_one_draw")
	var rng: DeterministicRngScript = DeterministicRngScript.new(42)
	var before: int = rng.draw_count
	var ignored: bool = rng.chance(0.5)
	_assert(rng.draw_count == before + 1, "chance(0.5) consumed exactly +1 draw (before=%d after=%d)" % [before, rng.draw_count])


func _test_pick_unique_actual_draw_contract() -> void:
	print("[rng-pick-unique-draws] pick_unique_actual_draw_contract")
	# empty / count<=0: 0 draws
	var rng: DeterministicRngScript = DeterministicRngScript.new(7)
	var d0: int = rng.draw_count
	rng.pick_unique([], 3)
	_assert(rng.draw_count == d0, "pick_unique([], 3) consumed 0 draws")
	rng.pick_unique([1, 2, 3], 0)
	_assert(rng.draw_count == d0, "pick_unique([1,2,3], 0) consumed 0 draws")
	# count >= size: 0 draws (returns full duplicate)
	var d1: int = rng.draw_count
	rng.pick_unique([1, 2, 3], 5)
	_assert(rng.draw_count == d1, "pick_unique([1,2,3], 5) consumed 0 draws (count>=size)")
	# 0 < count < size: size - count draws (reservoir sampling)
	var d2: int = rng.draw_count
	rng.pick_unique([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 3)
	_assert(rng.draw_count - d2 == 7, "pick_unique(10 items, count=3) consumed 7 draws (got %d)" % (rng.draw_count - d2))
	# Same seed produces same pick_unique result.
	var a: DeterministicRngScript = DeterministicRngScript.new(2025)
	var b: DeterministicRngScript = DeterministicRngScript.new(2025)
	var pa: Array = a.pick_unique([10, 20, 30, 40, 50], 3)
	var pb: Array = b.pick_unique([10, 20, 30, 40, 50], 3)
	_assert(pa == pb, "pick_unique same seed same result (a=%s b=%s)" % [pa, pb])
