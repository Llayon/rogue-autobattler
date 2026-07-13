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
	var attacker_power: int = source.magic_power if (is_magic and scales_with_magic_power) else source.attack()
	for t in targets:
		if t == null or not t.is_alive():
			continue
		var result: Dictionary = BalanceScript.compute_attack(
			attacker_power,
			source.crit_chance,
			source.crit_damage,
			source.magic_pen,
			t.defense() if not is_magic else source.magic_power,  # magic использует magic_resist
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
		results.append({
			"target": t,
			"applied": true,
			"dealt": dealt,
			"is_crit": result.is_crit,
			"is_magic": is_magic,
		})
	return results