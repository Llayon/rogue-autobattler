class_name RegenComponent extends RefCounted
## Регенерация HP/mana вне статус-системы.
## Тикает dt секунд, восстанавливает health_regen HP и (опционально) mana_regen mana.
##
## Сейчас дублирует mana_regen из ManaComponent — это намеренно, чтобы
## характеристика regen была отделена от детальной механики маны.
## Если понадобится — объединим.

var health_regen: float = 0.0   # HP/sec


func configure(hp_regen: float) -> void:
	health_regen = hp_regen


## Тикает реген. Возвращает сколько HP реально восстановлено.
func tick(dt: float, health: HealthComponent) -> int:
	if health_regen <= 0.0 or not health.is_alive():
		return 0
	var amount: int = int(round(health_regen * dt))
	if amount <= 0:
		return 0
	return health.heal(amount)


func to_dict() -> Dictionary:
	return {"health_regen": health_regen}


func from_dict(d: Dictionary) -> void:
	health_regen = float(d.get("health_regen", 0.0))