class_name Rng extends RefCounted
## Детерминированный сервис случайных чисел.
## Использовать ВЕЗДЕ вместо randf()/randi() в логике.
##
## В project.godot также зарегистрирован autoload "RngService" (Node-обёртка),
## чтобы иметь instance-интерфейс.
##
## Phase 1 / T13: facade routes every draw through a single owned
## DeterministicRng instance (`_stream`). The legacy public contract
## (function names, signatures, snapshot() shape `{"seed","state"}`) is
## preserved so no production callsite needs to change.

const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")

static var _stream: DeterministicRngScript = DeterministicRngScript.new(0)
static var current_seed: int = 0
static var _is_seeded: bool = false


## Boot-time initialization. The stream is constructed with seed 0
## (deterministic). Production never reaches the pre-seed draw
## window: every meaningful draw is gated by `seed_run`, which
## fully resets the stream via `_stream.seed_with`. No production
## callers exist in the pre-seed window, so the initial seed 0 is
## safe. This means rng_service.gd no longer owns a separate
## `RandomNumberGenerator` — the owned `DeterministicRng` is the
## sole RNG owner.
static func _static_init() -> void:
	_is_seeded = false


## Инициализирует генератор заданным seed-ом.
static func seed_run(seed_value: int) -> void:
	current_seed = seed_value
	_stream.seed_with(seed_value)
	_is_seeded = true


## Возвращает [0.0, 1.0).
static func randf() -> float:
	return _stream.randf()


## Возвращает [from, to].
static func randf_range(from: float, to: float) -> float:
	return _stream.randf_range(from, to)


## Возвращает [from, to].
static func randi_range(from: int, to: int) -> int:
	return _stream.randi_range(from, to)


## Returns true with probability chance (0.0..1.0).
## Legacy topology: ALWAYS consumes exactly one `randf()` draw,
## including chance(0.0) and chance(1.0). This preserves the
## draw positions in compound sequences (e.g. combat chance → crit
## chance → variance) that relied on the unconditional draw.
## Delegates to the owned stream which enforces this contract.
static func chance(chance: float) -> bool:
	return _stream.chance(chance)


## Returns a random element from `arr` (or null if empty).
## Legacy topology: consumes exactly one `randi_range` draw via
## the owned stream.
static func pick(arr: Array) -> Variant:
	return _stream.pick(arr)


## Returns an array of length `count` of unique elements from `arr`
## (without repeats).
## Legacy algorithm: duplicate pool, full Fisher-Yates shuffle via
## `Rng.randf()` (which routes to the owned stream), then slice.
## This consumes `pool.size() - 1` randf draws for any non-trivial
## pool (independent of requested `count`). The legacy topology
## MUST be preserved here; the new `DeterministicRng.pick_unique`
## uses reservoir sampling and has a different draw topology.
static func pick_unique(arr: Array, count: int) -> Array:
	var pool: Array = arr.duplicate()
	for i in range(pool.size() - 1, 0, -1):
		var j: int = int(Rng.randf() * float(i + 1))
		var tmp: Variant = pool[i]
		pool[i] = pool[j]
		pool[j] = tmp
	var n: int = mini(count, pool.size())
	return pool.slice(0, n)


## Legacy snapshot shape: `{"seed": int, "state": int}`.
## `DeterministicRng.snapshot()` has an extra `draw_count` field;
## we deliberately do NOT leak that into the legacy facade contract.
static func snapshot() -> Dictionary:
	var inner: Dictionary = _stream.snapshot()
	return {"seed": inner.get("seed", 0), "state": inner.get("state", 0)}


## Restore from a legacy snapshot. The facade accepts the legacy
## shape `{"seed","state"}`. The stream's PRNG is re-initialized
## from `snap.seed`, then the captured `snap.state` is assigned so
## the next draw resumes exactly at the captured mid-stream position.
##
## Legacy snapshot does not contain `draw_count`; the facade
## observable stream counter restarts at 0 (this is observable only
## through `get_draw_count()` debug helper, not the legacy wire).
## Godot 4 contract: assign `seed` first (re-initializes the PRNG),
## then assign `state` (writes the captured machine position).
static func restore(snap: Dictionary) -> void:
	var seed_val: int = int(snap.get("seed", 0))
	var state_val: Variant = snap.get("state", 0)
	_stream.restore({"seed": seed_val, "state": state_val, "draw_count": 0})
	current_seed = seed_val


static func is_seeded() -> bool:
	return _is_seeded


## Debug / test helper: total draws consumed by the underlying stream.
## Not part of the legacy public contract; tests may rely on it.
static func get_draw_count() -> int:
	return _stream.draw_count