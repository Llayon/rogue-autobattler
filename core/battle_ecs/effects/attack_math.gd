extends RefCounted
## B6.1 — single canonical attack-damage computation.
## BOTH BattleSimulation normal attacks and PerformAttackEffect
## MUST route through this helper so divergent formulas
## cannot re-emerge. Crit / dodge / variance / lifesteal /
## thorns / armor expansion remain deferred (B6.2+).
##
## Wraps Balance.compute_damage with the canonical Phase 2
## signature: (attacker_attack, defender_defense,
##   is_magic=false, variance=0.0, variance_factor=1.0).

static func compute(attacker_attack: int, defender_defense: int) -> int:
	return BalanceScript.compute_damage(
		attacker_attack, defender_defense,
		false, 0.0, 1.0)


const BalanceScript = preload("res://core/balance.gd")
