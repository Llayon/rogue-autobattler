class_name HealthComponent extends RefCounted
## Компонент здоровья. Владеет HP и shield, делегирует damage/heal.

var max_hp_base: int = 100
var current_hp: int = 100
var shield: int = 0


func configure(max_hp: int) -> void:
	max_hp_base = max_hp
	current_hp = max_hp


func max_hp() -> int:
	return max_hp_base


func is_alive() -> bool:
	return current_hp > 0


## Применяет урон сначала к щиту, потом к HP. Возвращает реально нанесённый урон.
func take_damage(amount: int) -> int:
	var absorbed: int = mini(shield, amount)
	shield -= absorbed
	var hp_damage: int = amount - absorbed
	current_hp = maxi(0, current_hp - hp_damage)
	return amount


## Хилит. Возвращает сколько реально восстановлено.
func heal(amount: int) -> int:
	if not is_alive():
		return 0
	var pre: int = current_hp
	current_hp = mini(max_hp_base, current_hp + amount)
	return current_hp - pre


func add_shield(amount: int) -> void:
	shield += amount


## Возвращает сериализуемое представление для save/load.
func to_dict() -> Dictionary:
	return {"max_hp_base": max_hp_base, "current_hp": current_hp, "shield": shield}


func from_dict(d: Dictionary) -> void:
	max_hp_base = int(d.get("max_hp_base", 100))
	current_hp = int(d.get("current_hp", max_hp_base))
	shield = int(d.get("shield", 0))