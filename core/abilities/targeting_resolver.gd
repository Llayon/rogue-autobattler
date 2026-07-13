class_name TargetingResolver extends RefCounted
## Резолвер таргетинга: превращает "цель по типу таргетинга" в конкретный
## список Combatant-ов на сетке.
##
## Вызывается из BattleContext / AbilityResolver.
##
## Все методы принимают источник (source), исходную точку (origin_cell)
## и параметры способности, и возвращают массив целей.

static func resolve(targeting: int, source, ctx, origin_cell: Vector2i, ability: Resource) -> Array:
	if source == null or ctx == null:
		return []
	match targeting:
		Targeting.SELF:
			return [source]
		Targeting.SINGLE_ENEMY:
			return _resolve_single_enemy(source, ctx, origin_cell, ability)
		Targeting.SINGLE_ALLY:
			return _resolve_single_ally(source, ctx, origin_cell, ability)
		Targeting.AOE_CIRCLE:
			return _resolve_aoe_circle(source, ctx, origin_cell, ability)
		Targeting.AOE_LINE:
			return _resolve_aoe_line(source, ctx, origin_cell, ability)
		Targeting.AOE_CONE:
			return _resolve_aoe_cone(source, ctx, origin_cell, ability)
		Targeting.RANDOM_ENEMY:
			return _resolve_random_enemy(source, ctx)
		Targeting.ALL_ENEMIES:
			return _resolve_all_enemies(source, ctx)
		Targeting.ALL_ALLIES:
			return _resolve_all_allies(source, ctx)
		_:
			GameLog.warn("abilities", "Unknown targeting", {"targeting": targeting})
			return []


static func _resolve_single_enemy(source, ctx, origin: Vector2i, ability: Resource) -> Array:
	# Ищем ближайшего живого врага в пределах ability.range.
	var best = null
	var best_dist: int = 999999
	for c in ctx.all_combatants():
		if c == null or not c.is_alive():
			continue
		if c.team == source.team:
			continue
		var d: int = _manhattan(c.cell, origin)
		if d <= ability.range and d < best_dist:
			best_dist = d
			best = c
	return [best] if best != null else []


static func _resolve_single_ally(source, ctx, origin: Vector2i, ability: Resource) -> Array:
	# По умолчанию — самый раненый союзник (включая себя) в радиусе.
	var best = null
	var best_missing_hp: int = -1
	for c in ctx.all_combatants():
		if c == null or not c.is_alive():
			continue
		if c.team != source.team:
			continue
		var d: int = _manhattan(c.cell, origin)
		if d > ability.range:
			continue
		var missing: int = c.max_hp - c.current_hp
		if missing > best_missing_hp:
			best_missing_hp = missing
			best = c
	return [best] if best != null else []


static func _resolve_aoe_circle(source, ctx, origin: Vector2i, ability: Resource) -> Array:
	var radius: int = maxi(1, ability.aoe_radius)
	var enemies_only: bool = ability.targeting == Targeting.AOE_CIRCLE  # v1: AOE круги — по врагам
	var result: Array = []
	for c in ctx.all_combatants():
		if c == null or not c.is_alive():
			continue
		if enemies_only and c.team == source.team:
			continue
		if _manhattan(c.cell, origin) <= radius:
			result.append(c)
	return result


static func _resolve_aoe_line(source, ctx, origin: Vector2i, ability: Resource) -> Array:
	# Линия по направлению "к врагам" — выбираем направление с максимумом врагов.
	var direction: Vector2i = _enemy_direction(source, ctx)
	var length: int = maxi(1, ability.aoe_length)
	var width: int = maxi(1, ability.aoe_width)
	var result: Array = []
	for c in ctx.all_combatants():
		if c == null or not c.is_alive():
			continue
		if c.team == source.team:
			continue
		var d: Vector2i = c.cell - origin
		# Проверяем: компонента по направлению от 1 до length, по перпендикуляру |.| <= width/2
		if _is_in_line(d, direction, length, width):
			result.append(c)
	return result


static func _resolve_aoe_cone(source, ctx, origin: Vector2i, ability: Resource) -> Array:
	var direction: Vector2i = _enemy_direction(source, ctx)
	var length: int = maxi(1, ability.aoe_length)
	var result: Array = []
	for c in ctx.all_combatants():
		if c == null or not c.is_alive():
			continue
		if c.team == source.team:
			continue
		var d: Vector2i = c.cell - origin
		if _is_in_cone(d, direction, length):
			result.append(c)
	return result


static func _resolve_random_enemy(source, ctx) -> Array:
	var pool: Array = []
	for c in ctx.all_combatants():
		if c == null or not c.is_alive():
			continue
		if c.team != source.team:
			pool.append(c)
	if pool.is_empty():
		return []
	return [Rng.pick(pool)]


static func _resolve_all_enemies(source, ctx) -> Array:
	var result: Array = []
	for c in ctx.all_combatants():
		if c == null or not c.is_alive():
			continue
		if c.team != source.team:
			result.append(c)
	return result


static func _resolve_all_allies(source, ctx) -> Array:
	var result: Array = []
	for c in ctx.all_combatants():
		if c == null or not c.is_alive():
			continue
		if c.team == source.team:
			result.append(c)
	return result


# --- Вспомогательные геометрические хелперы (детерминированные) ---

static func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


static func _enemy_direction(source, ctx) -> Vector2i:
	# Возвращает нормализованное направление к ближайшему врагу.
	var best = null
	var best_dist: int = 999999
	for c in ctx.all_combatants():
		if c == null or not c.is_alive():
			continue
		if c.team == source.team:
			continue
		var d: int = _manhattan(c.cell, source.cell)
		if d < best_dist:
			best_dist = d
			best = c
	if best == null:
		return Vector2i(0, 1)
	var delta: Vector2i = best.cell - source.cell
	if delta == Vector2i.ZERO:
		return Vector2i(0, 1)
	# Нормализация по доминирующей оси.
	if absi(delta.x) >= absi(delta.y):
		return Vector2i(1 if delta.x > 0 else -1, 0)
	return Vector2i(0, 1 if delta.y > 0 else -1)


static func _is_in_line(delta: Vector2i, direction: Vector2i, length: int, width: int) -> bool:
	# Проецируем delta на direction и на перпендикуляр.
	var forward: int = delta.x * direction.x + delta.y * direction.y
	if forward < 1 or forward > length:
		return false
	var perp_x: int = -direction.y
	var perp_y: int = direction.x
	var side: int = absi(delta.x * perp_x + delta.y * perp_y)
	return side <= width / 2


static func _is_in_cone(delta: Vector2i, direction: Vector2i, length: int) -> bool:
	var forward: int = delta.x * direction.x + delta.y * direction.y
	if forward < 1 or forward > length:
		return false
	var perp_x: int = -direction.y
	var perp_y: int = direction.x
	var side: int = delta.x * perp_x + delta.y * perp_y
	# Конус расширяется пропорционально forward (в форме пирамиды).
	var max_side: int = maxi(0, forward - 1)
	return absi(side) <= max_side