class_name ShieldEffect extends "res://core/effects/effect.gd"
## Эффект временного щита, поглощающего урон.

@export var amount: int = 20


func _init() -> void:
	kind = EffectKind.SHIELD


func apply(ctx, source, targets: Array) -> Array:
	var results: Array = []
	if not has_valid_targets(targets):
		return results
	for t in targets:
		if t == null or not t.is_alive():
			continue
		t.add_shield(amount)
		results.append({"target": t, "applied": true, "shield": amount})
	return results