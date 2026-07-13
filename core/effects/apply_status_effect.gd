class_name ApplyStatusEffect extends "res://core/effects/effect.gd"
## Эффект наложения статуса. Требует StatusDef в поле status_def.

@export var status_def: Resource  # StatusDef
@export var duration_override: float = -1.0  # -1 = использовать из status_def
@export var max_stacks_override: int = -1    # -1 = использовать из status_def


func _init() -> void:
	kind = EffectKind.APPLY_STATUS


func apply(ctx, source, targets: Array) -> Array:
	var results: Array = []
	if status_def == null:
		GameLog.warn("effects", "ApplyStatusEffect has no status_def")
		return results
	if not has_valid_targets(targets):
		return results
	for t in targets:
		if t == null or not t.is_alive():
			continue
		var dur: float = duration_override if duration_override >= 0.0 else status_def.duration
		var stacks: int = max_stacks_override if max_stacks_override >= 0 else status_def.max_stacks
		t.apply_status(status_def, dur, stacks, source)
		GameBus.emit_status_changed(t, status_def.id, true)
		results.append({
			"target": t,
			"applied": true,
			"status_id": status_def.id,
		})
	return results