class_name CleaveEffect extends "res://core/effects/effect.gd"
## Эффект "splash" урона: бьёт основную цель + всех врагов в radius вокруг неё.
## Использует grid.find_in_radius() для нахождения соседей.
##
## Пример: воин с cleave бьёт всех врагов в 1 клетке от цели.

const BalanceScript = preload("res://core/balance.gd")

@export var base_damage: int = 15
@export var is_magic: bool = false
@export var splash_radius: int = 1
@export var variance: float = 0.1
@export var scales_with_magic_power: bool = false


func _init() -> void:
	kind = EffectKind.DAMAGE


func apply(ctx, source, targets: Array) -> Array:
	var results: Array = []
	if not has_valid_targets(targets):
		return results
	if ctx == null:
		# Без контекста не можем найти соседей — fallback на обычный damage.
		for t in targets:
			if t == null or not t.is_alive():
				continue
			var d: int = _single_damage(source, t)
			t.take_damage(d, source)
			results.append({"target": t, "applied": true, "dealt": d, "is_splash": false})
		return results
	# С grid context — найти соседей каждой primary цели и ударить.
	var hit: Array = []
	for primary in targets:
		if primary == null or not primary.is_alive():
			continue
		# Splash: находим всех в radius от primary, но только противников source.
		var neighbors: Array = ctx.find_in_radius(primary.cell, splash_radius)
		var new_targets: Array = []
		for c in neighbors:
			if c == null or not c.is_alive():
				continue
			if c == primary:
				continue
			# Только противоположная команда (не союзники source).
			if source != null and c.team == source.team:
				continue
			if hit.has(c):
				continue  # не дублируем удар
			new_targets.append(c)
		# Сначала primary, потом новички.
		var all_targets: Array = [primary] + new_targets
		for t in all_targets:
			if t == null or not t.is_alive():
				continue
			if hit.has(t):
				continue
			var d: int = _single_damage(source, t)
			t.take_damage(d, source)
			hit.append(t)
			results.append({
				"target": t,
				"applied": true,
				"dealt": d,
				"is_splash": t != primary,
			})
	return results


func _single_damage(source, t) -> int:
	var attacker_power: int = source.magic_power_base if (is_magic and scales_with_magic_power) else source.attack()
	var target_defense: int = t.defense() if not is_magic else t.magic_resist()
	var r: Dictionary = BalanceScript.compute_attack(
		attacker_power,
		source.crit_chance,
		source.crit_damage,
		source.magic_pen,
		target_defense,
		t.armor,
		t.dodge,
		is_magic,
		variance
	)
	if r.dodged:
		return 0
	return r.dealt