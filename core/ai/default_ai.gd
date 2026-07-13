class_name DefaultAi extends "res://core/ai/ai_controller.gd"
## Простейший AI: идёт к ближайшему врагу, атакует в радиусе,
## кастует способности как только они готовы.
##
## Подходит для v1: предсказуемый, детерминированный, легко балансится.
##
## Расширение: создай AggressiveAi / DefensiveAi / HealerAi и подключай
## через Combatant.ai_controller или AI factory в BattleRunner.

const AbilityResolverScript = preload("res://core/abilities/ability_resolver.gd")


func tick(c, ctx, dt: float) -> void:
	if c == null or not c.is_alive():
		return
	# 1. Способности (приоритет — один каст за тик).
	for ability in c.abilities:
		if ability == null:
			continue
		if should_cast(c, ctx, ability):
			AbilityResolverScript.cast(ability, c, ctx, null)
			return
	# 2. Атака/движение.
	var target = _pick_target(c, ctx)
	if target == null:
		return
	var dist: int = Grid.distance(c.cell, target.cell)
	if dist <= c.attack_range:
		c.accumulate_attack(dt)
		if c.can_attack():
			c.basic_attack(target)
			c.reset_attack_accumulator()
	else:
		# В движении тоже копим "разогрев" — чтобы при подходе сразу ударить.
		c.accumulate_attack(dt)
		_step_towards(c, ctx, target)


## Возвращает ближайшего врага в пределах sight_range (или null).
func _pick_target(c, ctx):
	var candidates: Array = []
	var enemy_team: int = 1 - c.team if c.team < 2 else 2
	for e in ctx.combatants_of_team(enemy_team):
		var d: int = Grid.distance(c.cell, e.cell)
		if d <= c.sight_range:
			candidates.append(e)
	return Grid.nearest_to(c.cell, candidates)


## Делает один шаг к target.
func _step_towards(c, ctx, target) -> void:
	var delta: Vector2i = target.cell - c.cell
	if delta == Vector2i.ZERO:
		return
	# Приоритет — по доминирующей оси (X для дальних дистанций, иначе Y).
	var step_dir: Vector2i = _step_direction(delta)
	var next: Vector2i = c.cell + step_dir
	if ctx.grid.in_bounds(next) and not ctx.grid.is_occupied(next):
		ctx.move_to(c, next)


## Возвращает нормализованный вектор шага (одна клетка по доминирующей оси).
## Вынесено в static чтобы тестировать отдельно.
static func _step_direction(delta: Vector2i) -> Vector2i:
	if absi(delta.x) > 0 and (absi(delta.x) >= absi(delta.y) or delta.y == 0):
		return Vector2i(1 if delta.x > 0 else -1, 0)
	if absi(delta.y) > 0:
		return Vector2i(0, 1 if delta.y > 0 else -1)
	return Vector2i(1 if delta.x > 0 else -1, 0)