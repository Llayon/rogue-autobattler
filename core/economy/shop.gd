class_name Shop extends RefCounted
## Магазин между раундами.
##
## v1 — простой: выдаёт N случайных юнитов из доступного пула,
## игрок покупает за gold. Refresh между раундами.
##
## Идеи для v2:
##   - тир-ап при 3 одинаковых,
##   - специальные предложения,
##   - reroll за золото,
##   - "заинтересованность" в определённых типах.


const SHOP_SLOTS: int = 5


var _offered_ids: Array[StringName] = []


## Заполняет магазин N случайными id-ами из pool (например, unlocked_units).
func refresh(pool: Array[StringName]) -> void:
	_offered_ids.clear()
	if pool.is_empty():
		return
	var unique_picks: Array = Rng.pick_unique(pool, SHOP_SLOTS)
	for id in unique_picks:
		_offered_ids.append(StringName(String(id)))


## Возвращает текущие предложения.
func offered_ids() -> Array[StringName]:
	return _offered_ids.duplicate()


## Возвращает UnitDef по индексу слота, или null.
func offer_at(slot: int) -> Resource:
	if slot < 0 or slot >= _offered_ids.size():
		return null
	var id: StringName = _offered_ids[slot]
	return ContentDB_static.get_by_id(id)


## Покупает юнита из слота: возвращает UnitDef или null.
## Не списывает золото — это делает caller (RunController) чтобы
## Shop не зависел от RunState.
func take_at(slot: int) -> Resource:
	if slot < 0 or slot >= _offered_ids.size():
		return null
	var res: Resource = offer_at(slot)
	if res != null:
		_offered_ids.remove_at(slot)
	return res


## Продаёт юнита обратно (например, чтобы пополнить магазин после покупки).
## В v1 магазин не пополняется до следующего refresh.
func refund(unit_def_id: StringName) -> bool:
	if unit_def_id in _offered_ids:
		_offered_ids.erase(unit_def_id)
	return false  # v1: refund не возвращает в магазин