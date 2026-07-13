class_name ManaComponent extends RefCounted
## Мана-ресурс для способностей. Регенерирует по mana_regen/sec.
## Каждый тик: current_mana += mana_regen * dt, cap = max_mana.
##
## Расходуется через spend(cost). Если не хватает — возвращает false.

var max_mana_base: int = 100
var current_mana: int = 100
var mana_regen: float = 1.0  # per second


func configure(max_mana: int, regen: float) -> void:
	max_mana_base = max_mana
	current_mana = max_mana
	mana_regen = regen


func max_mana() -> int:
	return max_mana_base


func has_mana(cost: int) -> bool:
	return current_mana >= cost


## Тратит mana. Возвращает true если успешно.
func spend(cost: int) -> bool:
	if not has_mana(cost):
		return false
	current_mana -= cost
	return true


## Регенерирует dt секунд. Вызывается из BattleRunner каждый тик.
func regen_tick(dt: float) -> void:
	if mana_regen <= 0.0:
		return
	current_mana = mini(max_mana_base, current_mana + int(round(mana_regen * dt)))


## Возвращает % заполненности (0..1) для UI.
func fill_ratio() -> float:
	if max_mana_base == 0:
		return 1.0
	return float(current_mana) / float(max_mana_base)


func to_dict() -> Dictionary:
	return {"max_mana_base": max_mana_base, "current_mana": current_mana, "mana_regen": mana_regen}


func from_dict(d: Dictionary) -> void:
	max_mana_base = int(d.get("max_mana_base", 100))
	current_mana = int(d.get("current_mana", max_mana_base))
	mana_regen = float(d.get("mana_regen", 1.0))