class_name RunUnitState extends RefCounted
## S5.4: per-unit state живёт между боями внутри одного рана.
## Combatant пересоздаётся каждый battle — поэтому baseline HP и buff'ы
## хранятся здесь и пробрасываются в Combatant._init через hp_override.

## ID юнита (соответствует UnitDef.id).
var unit_id: StringName = &""

## Текущий HP. -1 = sentinel "use max_hp".
var current_hp: int = -1

## Max HP на момент спавна (для проверки cap в heal/rest).
var max_hp: int = -1

## Накопленный attack bonus (от REST/SHRINE). Суммируется в start_battle().
var bonus_attack: int = 0


func _init(p_unit_id: StringName = &"", p_max_hp: int = -1, p_current_hp: int = -1) -> void:
	unit_id = p_unit_id
	max_hp = p_max_hp
	current_hp = p_current_hp


## Возвращает effective HP (current_hp если установлен, иначе max_hp).
func effective_hp() -> int:
	if current_hp > 0:
		return current_hp
	return max_hp


## Применяет урон. Возвращает фактически нанесённый урон.
func take_damage(amount: int) -> int:
	if current_hp <= 0:
		current_hp = max_hp
	if amount <= 0:
		return 0
	var dealt: int = mini(current_hp, amount)
	current_hp -= dealt
	return dealt


## Применяет хил. Возвращает фактически восстановленное.
func heal(amount: int) -> int:
	if current_hp <= 0:
		return 0  # мёртвые не хиливаются
	var pre: int = current_hp
	current_hp = mini(max_hp, current_hp + amount)
	return current_hp - pre


## Помечает как мёртвого (current_hp = 0).
func kill() -> void:
	current_hp = 0


## True если юнит жив (current_hp > 0).
func is_alive() -> bool:
	return current_hp > 0


## True если юнит мёртв.
func is_dead() -> bool:
	return current_hp <= 0


## Сериализация для SaveService (через Dictionary).
func to_dict() -> Dictionary:
	return {
		"unit_id": String(unit_id),
		"current_hp": current_hp,
		"max_hp": max_hp,
		"bonus_attack": bonus_attack,
	}


func from_dict(d: Dictionary) -> void:
	unit_id = StringName(String(d.get("unit_id", "")))
	current_hp = int(d.get("current_hp", -1))
	max_hp = int(d.get("max_hp", -1))
	bonus_attack = int(d.get("bonus_attack", 0))
