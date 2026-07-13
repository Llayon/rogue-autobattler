class_name AbilityResolver extends RefCounted
## Резолвер применения способностей: проверяет mana, вычисляет цели, прогоняет эффекты,
## применяет кулдаун.
##
## Вызывается из BattleRunner или AI.
##
##   var results := AbilityResolver.cast(ability, caster, ctx, optional_target)

static func cast(ability: Resource, caster, ctx, optional_target = null) -> Array:
	if ability == null or caster == null or ctx == null:
		return []
	if caster.is_stunned():
		GameLog.debug("abilities", "Cast blocked: stunned", {"caster": caster.def_id if caster else null})
		return []
	if caster.is_on_cooldown(ability):
		GameLog.debug("abilities", "Cast blocked: cooldown", {"ability": ability.id})
		return []
	# v3: проверяем mana. Если не хватает — отменяем (без кулдауна).
	if ability.mana_cost > 0 and not caster.mana.has_mana(ability.mana_cost):
		GameLog.debug("abilities", "Cast blocked: no mana", {
			"ability": ability.id,
			"need": ability.mana_cost,
			"have": caster.mana.current_mana,
		})
		return []
	# Резолвим цели.
	var targets: Array = _resolve_targets(ability, caster, ctx, optional_target)
	if targets.is_empty():
		return []
	# Списываем mana ДО применения эффектов (fail-fast).
	if ability.mana_cost > 0:
		caster.mana.spend(ability.mana_cost)
	# Применяем каждый эффект по очереди.
	var results: Array = []
	for eff in ability.effects:
		if eff == null:
			continue
		var r: Array = eff.apply(ctx, caster, targets)
		for item in r:
			results.append(item)
	# Ставим кулдаун (с учётом CDR в Combatant.put_on_cooldown).
	caster.put_on_cooldown(ability)
	GameBus.emit_ability_cast(ability, caster, optional_target if optional_target else targets[0] if not targets.is_empty() else null)
	GameBus.emit_effect_applied(ability, caster, targets)
	return results


static func _resolve_targets(ability: Resource, caster, ctx, optional_target) -> Array:
	if optional_target != null and Targeting.requires_explicit_target(ability.targeting):
		# Если передан явный таргет и таргетинг это допускает — используем его.
		return [optional_target]
	return TargetingResolver.resolve(ability.targeting, caster, ctx, caster.cell, ability)