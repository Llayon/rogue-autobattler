class_name ChainLightningEffect extends "res://core/effects/effect.gd"
## Эффект цепной молнии: бьёт primary цель, затем бounces на ближайших врагов.
## Каждый bounce — урон × decay.
##
## Пример: маг кастует chain_lightning → primary 40 dmg → bounce 1 = 30 → bounce 2 = 22 → bounce 3 = 16.

const BalanceScript = preload("res://core/balance.gd")

@export var base_damage: int = 25
@export var bounce_count: int = 2
@export var decay: float = 0.7  # каждый bounce × decay
@export var is_magic: bool = true
@export var scales_with_magic_power: bool = true


func _init() -> void:
	kind = EffectKind.DAMAGE


func apply(ctx, source, targets: Array) -> Array:
	var results: Array = []
	if not has_valid_targets(targets):
		return results
	# Найти всех врагов source (для bounce).
	var enemy_team: int = -1
	if source != null:
		enemy_team = 1 if source.team == 0 else 0
	var hit: Array = []
	# Primary strike.
	for primary in targets:
		if primary == null or not primary.is_alive():
			continue
		var d: int = _damage_at(source, primary, 1.0)
		primary.take_damage(d, source)
		hit.append(primary)
		results.append({"target": primary, "applied": true, "dealt": d, "bounce": 0})
	# Bounces.
	var multiplier: float = 1.0
	for bounce_i in bounce_count:
		multiplier *= decay
		var last_hit = hit[hit.size() - 1]
		if last_hit == null or not last_hit.is_alive():
			break
		# Найти ближайшего врага, который ещё не hit.
		var next_target = _find_next(ctx, last_hit, enemy_team, hit)
		if next_target == null:
			break
		var d: int = _damage_at(source, next_target, multiplier)
		next_target.take_damage(d, source)
		hit.append(next_target)
		results.append({"target": next_target, "applied": true, "dealt": d, "bounce": bounce_i + 1})
	return results


func _damage_at(source, t, multiplier: float) -> int:
	var attacker_power: int = source.magic_power_base if (is_magic and scales_with_magic_power) else source.attack()
	var target_defense: int = t.defense() if not is_magic else t.magic_resist()
	var r: Dictionary = BalanceScript.compute_attack(
		int(round(float(attacker_power) * multiplier)),
		source.crit_chance,
		source.crit_damage,
		source.magic_pen,
		target_defense,
		t.armor,
		t.dodge,
		is_magic,
		0.0
	)
	if r.dodged:
		return 0
	return r.dealt


func _find_next(ctx, from, enemy_team: int, hit: Array):
	if ctx == null or from == null:
		return null
	var all_enemies: Array = ctx.combatants_of_team(enemy_team)
	var best = null
	var best_dist: int = 999999
	for c in all_enemies:
		if c == null or not c.is_alive():
			continue
		if hit.has(c):
			continue
		var dist: int = absi(c.cell.x - from.cell.x) + absi(c.cell.y - from.cell.y)
		if dist < best_dist:
			best_dist = dist
			best = c
	return best