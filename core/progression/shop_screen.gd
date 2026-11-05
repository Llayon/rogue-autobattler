class_name ShopScreen extends RefCounted
const BalanceScript = preload("res://core/balance.gd")
## Генерирует shop offer для MERCHANT encounter (S7.4).
## 3 случайных ItemDef с discounted price (MAP_MERCHANT_DISCOUNT).

const OFFER_SIZE: int = 3

var _offered_item_ids: Array[StringName] = []
## The discount comes from the balance, not from a literal: the v5
## checkpoint PERSISTS the discount, so a literal here would silently
## diverge from the persisted offer when the balance changes.
var _discount: float = BalanceScript.MAP_MERCHANT_DISCOUNT


## Заполняет _offered_item_ids случайными ItemDef id из ContentDB.
## Optional unlocked_units параметр (для compat с reward_screen.refresh сигнатурой).
## Clears the offer.
##
## RI-07: the offer belongs to the run. A new run must not carry the
## merchant offer of the previous one: it leaked into the new run and
## into its checkpoint, and it broke the determinism of the checkpoint
## for a fixed seed.
func reset_offer() -> void:
	# Only the offer is run-scoped. The discount is the balance
	# constant, so it stays.
	_offered_item_ids.clear()


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
## Возвращает чистый снимок предложений торговца.
##
## The snapshot carries the offered item ids, their order and the
## discount. It is a plain Dictionary of primitives.
func snapshot() -> Dictionary:
	var ids: Array = []
	for id in _offered_item_ids:
		ids.append(String(id))
	return {
		"offered_item_ids": ids,
		"discount": float(_discount),
	}


## Восстанавливает предложения торговца из снимка.
##
## The restore is ATOMIC: the snapshot is validated first and the live
## offer is only replaced when every check passed. Returns true on
## success.
func restore_snapshot(data: Dictionary) -> bool:
	if not data.has("offered_item_ids") or not data.has("discount"):
		return false
	var raw: Variant = data["offered_item_ids"]
	if not (raw is Array):
		return false
	var raw_discount: Variant = data["discount"]
	if not (raw_discount is int) and not (raw_discount is float):
		return false
	var ids: Array[StringName] = []
	for v in raw as Array:
		if not (v is String) and not (v is StringName):
			return false
		ids.append(StringName(String(v)))
	var discount: float = float(raw_discount)
	if discount < 0.0 or discount > 1.0:
		return false
	_offered_item_ids = ids
	_discount = discount
	return true


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
