class_name Rng extends RefCounted
## Детерминированный сервис случайных чисел.
## Использовать ВЕЗДЕ вместо randf()/randi() в логике.
##
## В project.godot также зарегистрирован autoload "RngService" (Node-обёртка),
## чтобы иметь instance-интерфейс.

static var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
static var current_seed: int = 0
static var _is_seeded: bool = false


static func _static_init() -> void:
	_rng.randomize()
	current_seed = _rng.seed


## Инициализирует генератор заданным seed-ом.
static func seed_run(seed_value: int) -> void:
	current_seed = seed_value
	_rng.seed = seed_value
	_is_seeded = true


## Возвращает [0.0, 1.0).
static func randf() -> float:
	return _rng.randf()


## Возвращает [from, to].
static func randf_range(from: float, to: float) -> float:
	return _rng.randf_range(from, to)


## Возвращает [from, to].
static func randi_range(from: int, to: int) -> int:
	return _rng.randi_range(from, to)


## Возвращает true с вероятностью chance (0.0..1.0).
static func chance(chance: float) -> bool:
	return Rng.randf() < chance


## Возвращает случайный элемент массива (или null если пустой).
static func pick(arr: Array) -> Variant:
	if arr.is_empty():
		return null
	return arr[randi_range(0, arr.size() - 1)]


## Возвращает массив длиной count из уникальных элементов arr (без повторов).
## Детерминировано: Fisher-Yates через Rng.randf (НЕ использует Array.shuffle()).
static func pick_unique(arr: Array, count: int) -> Array:
	var pool: Array = arr.duplicate()
	# Fisher-Yates shuffle через seeded Rng.
	for i in range(pool.size() - 1, 0, -1):
		var j: int = int(Rng.randf() * float(i + 1))
		var tmp: Variant = pool[i]
		pool[i] = pool[j]
		pool[j] = tmp
	var n: int = mini(count, pool.size())
	return pool.slice(0, n)


static func snapshot() -> Dictionary:
	return {"seed": _rng.seed, "state": _rng.state}


static func restore(snap: Dictionary) -> void:
	_rng.seed = snap.get("seed", 0)
	_rng.state = snap.get("state", 0)


static func is_seeded() -> bool:
	return _is_seeded