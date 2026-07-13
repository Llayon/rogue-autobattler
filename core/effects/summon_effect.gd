class_name SummonEffect extends "res://core/effects/effect.gd"
## Спавнит юнита рядом с кастером. unit_def_id должен быть валидным id в ContentDB_static.

@export var unit_def_id: StringName = &""


func _init() -> void:
	kind = EffectKind.SUMMON


func apply(ctx, source, targets: Array) -> Array:
	var results: Array = []
	if unit_def_id == &"":
		GameLog.warn("effects", "SummonEffect has no unit_def_id")
		return results
	if ctx == null:
		return results
	var def: Resource = ContentDB_static.get_by_id(unit_def_id)
	if def == null:
		GameLog.warn("effects", "SummonEffect references unknown unit_def_id", {"id": unit_def_id})
		return results
	# Спавним рядом с кастером.
	var spawned = ctx.summon_near(source, def)
	if spawned != null:
		results.append({"target": spawned, "applied": true, "summoned_from": unit_def_id})
	return results