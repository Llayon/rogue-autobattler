class_name DispelEffect extends "res://core/effects/effect.gd"
## Снимает N статусов с целей. Если dispel_harmful=true — снимает дебаффы,
## иначе — баффы. Если count=-1 — снимает все подходящие.

@export var count: int = -1
@export var dispel_harmful: bool = true


func _init() -> void:
	kind = EffectKind.DISPEL


func apply(ctx, source, targets: Array) -> Array:
	var results: Array = []
	if not has_valid_targets(targets):
		return results
	for t in targets:
		if t == null or not t.is_alive():
			continue
		var removed: Array = t.dispel_statuses(count, dispel_harmful)
		results.append({"target": t, "applied": true, "removed": removed})
	return results