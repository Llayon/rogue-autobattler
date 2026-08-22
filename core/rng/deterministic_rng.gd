class_name DeterministicRng extends RefCounted
## Phase 1 / T12 — explicit deterministic RNG owner.
##
## Every call consumes a documented number of internal draws.
## Same seed + same call order => same sequence.
## Reseed resets the draw counter.
## No global randomness, no time seed, no randomize().
##
## Use this from any code that needs future simulation parity
## (battle determinism, replay, balance verification, AI
## determinism). Legacy code can still use the global `Rng`
## facade which delegates to an owned instance of this class.
##
## Draw contract (consumes from internal counter):
##   randi_range(min, max)    = +1
##   randf_range(min, max)    = +1
##   randf()                  = +1
##   pick(non_empty_array)    = +1
##   shuffle_in_place(arr)    = arr.size() - 1  (Fisher-Yates via randi_range)
##   chance(p)                = +1  (delegates to randf)
##
## Note on naming: Godot 4 ships global `randi_range` / `randf_range`
## / `randf` in @GlobalScope. When our helpers share those names,
## GDScript's name resolution inside our own methods prefers the
## global and silently calls the wrong function (one that does not
## advance `draw_count`). We therefore expose the API under the
## short, conventional names but always invoke them through
## `self.` from inside the class. External callers should also
## use `self.randf_range(...)` when calling from a subclass or
## a context where the global could shadow.

var seed_value: int = 0
var draw_count: int = 0
var _rng: RandomNumberGenerator = null


func _init(seed: int = 0) -> void:
	_rng = RandomNumberGenerator.new()
	seed_with(seed)


## Reseed and reset draw counter. Same seed + same call order
## always reproduces the same sequence.
func seed_with(seed: int) -> void:
	seed_value = seed
	_rng.seed = seed
	draw_count = 0


## Inclusive integer in [min_value, max_value]. +1 draw.
func randi_range(min_value: int, max_value: int) -> int:
	if min_value > max_value:
		var tmp: int = min_value
		min_value = max_value
		max_value = tmp
	draw_count += 1
	return _rng.randi_range(min_value, max_value)


## Random float in [min_value, max_value). +1 draw.
func randf_range(min_value: float, max_value: float) -> float:
	draw_count += 1
	return _rng.randf_range(min_value, max_value)


## Random float in [0.0, 1.0). +1 draw.
func randf() -> float:
	draw_count += 1
	return _rng.randf()


## Coin-flip helper: true with probability `p` (clamped to [0,1]).
## ALWAYS consumes exactly one draw, including the boundary cases
## `chance(0.0)` and `chance(1.0)`. This matches the legacy facade
## `Rng.chance` topology so that compound sequences (e.g. combat
## chance → crit chance → variance) keep their draw positions.
## Use `self.randf()` (qualified) to avoid the @GlobalScope shadow.
## `self.randf()` already increments draw_count, so chance does NOT
## increment it again.
func chance(p: float) -> bool:
	return self.randf() < clampf(p, 0.0, 1.0)


## Pick one element from `arr`. Empty array => null, no draw.
## Non-empty => +1 draw.
func pick(arr: Array) -> Variant:
	if arr.is_empty():
		return null
	# Explicit `self.` to bypass the @GlobalScope `randi_range`.
	var idx: int = self.randi_range(0, arr.size() - 1)
	return arr[idx]

## In-place Fisher-Yates shuffle using this object's randi_range so
## every swap is explicit and counted. Consumes (arr.size() - 1) draws.
## Empty / 1-element arrays consume 0 draws.
func shuffle_in_place(arr: Array) -> void:
	var n: int = arr.size()
	if n <= 1:
		return
	for i in range(n - 1, 0, -1):
		# Explicit `self.` for the same reason as in `pick`.
		var j: int = self.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


## Return a new array containing `count` distinct elements drawn
## from `arr` (or all of `arr` if count >= arr.size()).
##
## Algorithm: reservoir sampling.
##
## ACTUAL draw semantics:
## - empty arr or count <= 0: 0 draws
## - count >= arr.size():      0 draws (returns full duplicate)
## - 0 < count < arr.size():   arr.size() - count draws
##   (reservoir sampling: the first `count` items are taken for free;
##    each subsequent index i >= count consumes one randi_range draw
##    to decide inclusion, replacing a reservoir slot if chosen)
##
## Note: the FACADE legacy `Rng.pick_unique` preserves its own
## Fisher-Yates algorithm for legacy compatibility. The
## `DeterministicRng` helper here is the new-owner API and uses
## reservoir sampling; the facade adapter bridges the difference.
func pick_unique(arr: Array, count: int) -> Array:
	if arr.is_empty() or count <= 0:
		return []
	var n: int = mini(count, arr.size())
	if n >= arr.size():
		return arr.duplicate()
	# Reservoir: walk arr once, decide inclusion per index.
	var reservoir: Array = []
	for i in arr.size():
		if reservoir.size() < n:
			reservoir.append(arr[i])
		else:
			# Standard reservoir sampling using this object's RNG.
			var j: int = self.randi_range(0, i)
			if j < n:
				reservoir[j] = arr[i]
	return reservoir


## Snapshot the deterministic state. Useful for save/resume
## integration that does not need to persist PRNG internals
## through the save schema: a snapshot can be captured in
## transient in-memory state and used during a single session.
func snapshot() -> Dictionary:
	return {"seed": seed_value, "draw_count": draw_count, "state": _rng.state}


## Restore from a snapshot. After restore the stream resumes exactly
## at the captured mid-stream position — the next draw returns the
## same value it would have returned at snapshot time.
##
## Godot 4 `RandomNumberGenerator` contract:
##   `seed` initializes the PRNG state
##   `state` is the current generator position
##   save/restore `state` restores the generator to that position
##   when restoring both, initialize seed BEFORE setting state
##
## Ordering: seed_with first (re-initializes), then assign state
## (writes the captured PRNG machine state directly), then restore
## draw_count so it reflects the captured position.
func restore(snap: Dictionary) -> void:
	var restored_seed: int = int(snap.get("seed", 0))
	var restored_count: int = int(snap.get("draw_count", 0))
	var restored_state: Variant = snap.get("state", 0)
	seed_with(restored_seed)
	_rng.state = restored_state
	draw_count = restored_count