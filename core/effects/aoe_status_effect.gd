class_name AoeStatusEffect extends "res://core/effects/apply_status_effect.gd"
## AOE версия ApplyStatusEffect: накладывает status на цель + всех в радиусе.
## Используется для Stun Bomb, Slow Wave, и других AOE debuff.

@export var aoe_radius: int = 1
@export var enemy_team_only: bool = true


func apply(ctx, source, targets: Array) -> Array:
	var results: Array = []
	if status_def == null:
		GameLog.warn("effects", "AoeStatusEffect has no status_def")
		return results
	if not has_valid_targets(targets):
		return results
	if ctx == null:
		# Без ctx — fallback на обычный ApplyStatusEffect.
		return super.apply(ctx, source, targets)
	var seen: Array = []
	for primary in targets:
		if primary == null or not primary.is_alive():
			continue
		var team_filter: int = -1
		if enemy_team_only and source != null:
			team_filter = 1 if source.team == 0 else 0
		var neighbors: Array = ctx.find_in_radius(primary.cell, aoe_radius, team_filter)
		if not neighbors.has(primary):
			neighbors.append(primary)
		for t in neighbors:
			if t == null or not t.is_alive():
				continue
			if seen.has(t):
				continue
			var dur: float = duration_override if duration_override >= 0.0 else status_def.duration
			var stacks: int = max_stacks_override if max_stacks_override >= 0 else status_def.max_stacks
			t.apply_status(status_def, dur, stacks, source)
			GameBus.emit_status_changed(t, status_def.id, true)
			seen.append(t)
			results.append({"target": t, "applied": true, "status_id": status_def.id})
	return results