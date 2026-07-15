class_name DamageEffect extends "res://core/effects/effect.gd"
## Эффект нанесения урона. Использует Balance.compute_attack (v3):
## учитывает crit, dodge, magic_pen, armor.
##
## Для magic-атак источник берёт magic_power вместо attack.

const BalanceScript = preload("res://core/balance.gd")

@export var base_damage: int = 10
@export var is_magic: bool = false
@export var variance: float = 0.1  # ±10% по умолчанию
@export var scales_with_magic_power: bool = true  # magic=true → использует magic_power


func _init() -> void:
	kind = EffectKind.DAMAGE


func apply(ctx, source, targets: Array) -> Array:
	var results: Array = []
	if not has_valid_targets(targets):
		return results
	# Атакующая сила: для magic используем magic_power_base (поле), для физики — attack() (метод с модификаторами).
	# Magic: нет magic_power() метода, используем поле напрямую (consistency с attacker_power: поле vs метод).
	# TODO: добавить magic_power() метод с модификаторами, если понадобятся status-effects на magic power.
	var attacker_power: int = source.magic_power_base if (is_magic and scales_with_magic_power) else source.attack()
	for t in targets:
		if t == null or not t.is_alive():
			continue
		# Защита цели: физическая → defense(), магическая → magic_resist().
		# Это consistent с attacker_power (поле vs метод).
		var target_defense: int = t.defense() if not is_magic else t.magic_resist()
		var result: Dictionary = BalanceScript.compute_attack(
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
		if result.dodged:
			GameBus.emit_unit_dodged(source, t)
			results.append({"target": t, "applied": false, "dodged": true})
			continue
		var pre_hp: int = t.health.current_hp
		t.take_damage(result.dealt, source)
		var dealt: int = pre_hp - t.health.current_hp
		GameBus.emit_unit_damaged(t, dealt, source)
		# S4.2: emit damage_dealt для floating numbers в BattleView.
		if dealt > 0:
			GameBus.emit_damage_dealt(t, dealt, source)
		results.append({
			"target": t,
			"applied": true,
			"dealt": dealt,
			"is_crit": result.is_crit,
			"is_magic": is_magic,
		})
	return results