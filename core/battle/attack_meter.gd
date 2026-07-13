class_name AttackMeter extends RefCounted
## Аккумулятор для автоатак. Копится dt каждый кадр, при достижении порога — ready.
## Хранит состояние "готов к удару" и сбрасывается после удара.

var _attack_acc: float = 0.0


func accumulate(dt: float) -> void:
	_attack_acc += dt


func reset() -> void:
	_attack_acc = 0.0


## Готов ли к удару. attack_speed — модифицированная скорость атаки юнита.
func is_ready(attack_speed: float) -> bool:
	return _attack_acc >= Balance.attack_interval(attack_speed)


## Возвращает прогресс 0..1 (для UI).
func progress(attack_speed: float) -> float:
	var interval: float = Balance.attack_interval(attack_speed)
	return clampf(_attack_acc / interval, 0.0, 1.0)


func to_dict() -> Dictionary:
	return {"acc": _attack_acc}


func from_dict(d: Dictionary) -> void:
	_attack_acc = float(d.get("acc", 0.0))