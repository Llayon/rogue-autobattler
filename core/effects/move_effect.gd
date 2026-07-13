class_name MoveEffect extends "res://core/effects/effect.gd"
## Перемещает цель на N клеток в направлении (target_cell - current_cell).
## v1 — безразмерно, без учёта препятствий (юниты проходят сквозь других).
## Реальное столкновение появится когда будем делать подвижные юниты
## с фокусом на движение.

@export var distance: int = 1


func _init() -> void:
	kind = EffectKind.MOVE


func apply(ctx, source, targets: Array) -> Array:
	var results: Array = []
	if not has_valid_targets(targets):
		return results
	for t in targets:
		if t == null or not t.is_alive():
			continue
		if ctx == null or not ctx.has_method("try_move_along_line"):
			continue
		var moved: bool = ctx.try_move_along_line(t, source.cell if source else null, distance)
		results.append({"target": t, "applied": moved})
	return results