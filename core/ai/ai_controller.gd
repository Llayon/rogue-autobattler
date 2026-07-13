class_name AiController extends RefCounted
## Базовый AI-контроллер. tick(c, ctx, dt) вызывается каждый тик боя.
## Конкретные AI (Default, Aggressive, Defensive, ...) наследуют этот класс.


func tick(c, ctx, dt: float) -> void:
	pass


## Возвращает true, если AI решил применить способность ability сейчас.
## Базовая стратегия — применить сразу, как только кулдаун кончился
## и есть цель в радиусе.
func should_cast(c, ctx, ability: Resource) -> bool:
	return not c.is_on_cooldown(ability) and _has_target_in_range(c, ctx, ability)


func _has_target_in_range(c, ctx, ability: Resource) -> bool:
	var targets: Array = TargetingResolver.resolve(ability.targeting, c, ctx, c.cell, ability)
	return not targets.is_empty()