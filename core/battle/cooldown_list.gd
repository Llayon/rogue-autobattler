class_name CooldownList extends RefCounted
## Контейнер кулдаунов способностей. ability.id → оставшееся время.

var _cooldowns: Dictionary = {}


func put(ability: Resource) -> void:
	if ability == null:
		return
	_cooldowns[ability.id] = ability.cooldown


## Прямая установка кулдауна по id (используется с CDR в Combatant).
func _put_raw(ability_id: StringName, seconds: float) -> void:
	_cooldowns[ability_id] = seconds


func remaining(ability: Resource) -> float:
	if ability == null:
		return 0.0
	return float(_cooldowns.get(ability.id, 0.0))


func is_on_cooldown(ability: Resource) -> bool:
	return remaining(ability) > 0.0


func tick(dt: float) -> void:
	for id in _cooldowns.keys():
		var v: float = float(_cooldowns[id]) - dt
		if v <= 0.0:
			_cooldowns.erase(id)
		else:
			_cooldowns[id] = v


func clear() -> void:
	_cooldowns.clear()


func to_dict() -> Dictionary:
	return _cooldowns.duplicate()


func from_dict(d: Dictionary) -> void:
	_cooldowns.clear()
	for k in d.keys():
		_cooldowns[k] = float(d[k])