class_name RewardScreen extends RefCounted
## Генерирует offer для reward screen между раундами (S3.1.5).
##
## Offer = N случайных юнитов, tier-weighted по round_index.
## Не учитывает unlocked_units — reward может предложить нового юнита.
##
## v1: без анимаций, без UI — только core-логика.
## UI подключается в S4.x через GameBus.reward_offered.

var _offered_ids: Array[StringName] = []
var _round_index: int = 0


## Вычисляет target tier для reward на этом раунде.
## Формула: clamp(round_index / 3, 1, 3).
static func target_tier_for_round(round_index: int) -> int:
	return clampi(round_index / 3, 1, 3)


## Генерирует offer из REWARD_SLOTS юнитов.
## Tier-weighted: 60% target, 30% target-1 (если >1), 10% target+1 (если <3).
## Записывает результат в self._offered_ids и возвращает копию.
func generate_offer(round_index: int) -> Array[StringName]:
	_round_index = round_index
	_offered_ids.clear()
	var target_tier: int = target_tier_for_round(round_index)
	var pool: Array[StringName] = []
	var attempts: int = 0
	while pool.size() < Balance.REWARD_SLOTS and attempts < 50:
		attempts += 1
		var tier: int = _pick_tier(target_tier)
		var tier_pool: Array = UnitsMeta.ids_by_tier(tier)
		if tier_pool.is_empty():
			continue
		var pick: StringName = tier_pool[Rng.randi_range(0, tier_pool.size() - 1)]
		if pick not in pool:
			pool.append(pick)
	_offered_ids = pool.duplicate()
	return _offered_ids.duplicate()


## Возвращает текущий offer (read-only copy).
func offered_ids() -> Array[StringName]:
	return _offered_ids.duplicate()


## Возвращает UnitDef по индексу слота, или null.
func offer_at(slot: int) -> Resource:
	if slot < 0 or slot >= _offered_ids.size():
		return null
	return ContentDB_static.get_by_id(_offered_ids[slot])


## Выбирает tier с вероятностями из Balance.
## 60% — target tier, 30% — target-1 (если >1), 10% — target+1 (если <3).
func _pick_tier(target: int) -> int:
	var r: float = Rng.randf()
	if r < Balance.REWARD_TIER_BASE_WEIGHT:
		return target
	elif r < Balance.REWARD_TIER_BASE_WEIGHT + Balance.REWARD_TIER_MINUS_WEIGHT:
		return maxi(1, target - 1)
	else:
		return mini(3, target + 1)
