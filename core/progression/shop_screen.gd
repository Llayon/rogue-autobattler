class_name ShopScreen extends RefCounted
## Генерирует shop offer для MERCHANT encounter (S7.4).
## 3 случайных ItemDef с discounted price (MAP_MERCHANT_DISCOUNT).

const OFFER_SIZE: int = 3

var _offered_item_ids: Array[StringName] = []
var _discount: float = 0.5


## Заполняет _offered_item_ids случайными ItemDef id из ContentDB.
## Optional unlocked_units параметр (для compat с reward_screen.refresh сигнатурой).
func refresh(_unlocked_units: Array = []) -> void:
	_offered_item_ids.clear()
	var item_ids: Array = ContentDB_static.get_all_ids_for_type("items")
	if item_ids.is_empty():
		return
	var pool: Array = item_ids.duplicate()
	for i in OFFER_SIZE:
		if pool.is_empty():
			break
		var idx: int = int(Rng.randf_range(0.0, float(pool.size())))
		if idx >= pool.size():
			idx = pool.size() - 1
		_offered_item_ids.append(pool[idx])
		pool.remove_at(idx)


## Кол-во items в текущем предложении.
func get_offered_count() -> int:
	return _offered_item_ids.size()


## ItemDef id по slot или &"".
func get_item_id(slot: int) -> StringName:
	if slot < 0 or slot >= _offered_item_ids.size():
		return &""
	return _offered_item_ids[slot]


## Возвращает ItemDef для slot или null.
func get_item_def(slot: int) -> Resource:
	var id: StringName = get_item_id(slot)
	if id == &"":
		return null
	return ContentDB_static.get_by_id(id)


## Цена со скидкой (cost * _discount).
func get_discounted_price(slot: int) -> int:
	var def: Resource = get_item_def(slot)
	if def == null:
		return 0
	return int(round(float(def.cost) * _discount))


## Возвращает массив StringName всех offered item ids (для тестов).
func get_offered_ids() -> Array:
	return _offered_item_ids.duplicate()


## Set discount (тест helper).
func set_discount(d: float) -> void:
	_discount = d


## Get discount.
func get_discount() -> float:
	return _discount
