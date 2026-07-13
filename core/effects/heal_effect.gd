class_name HealEffect extends "res://core/effects/effect.gd"
## Эффект лечения. Не может поднять HP выше max_hp.

@export var amount: int = 10
@export var variance: float = 0.1


func _init() -> void:
	kind = EffectKind.HEAL


func apply(ctx, source, targets: Array) -> Array:
	var results: Array = []
	if not has_valid_targets(targets):
		return results
	for t in targets:
		if t == null or not t.is_alive():
			continue
		var variance_factor: float = 1.0 + Rng.randf_range(-variance, variance)
		var raw: int = int(round(float(amount) * variance_factor))
		var actual: int = t.heal(raw)
		results.append({
			"target": t,
			"applied": actual > 0,
			"healed": actual,
		})
	return results