class_name BattleContext extends RefCounted
## Контекст боя: состояние, к которому обращаются AI, эффекты, способности.
##
## Не знает о визуальной части. Владеет:
##   - сеткой (Grid),
##   - реестром живых Combatant-ов,
##   - ссылкой на BattleState (для статуса боя),
##   - логом событий (опционально, для реплеев).

const GridScript = preload("res://core/battle/grid.gd")
const CombatantScript = preload("res://core/battle/combatant.gd")

var grid = null  # Grid (RefCounted)
var state: Resource = null  # BattleState
var combatant_registry: Array = []  # все живые (и мёртвые до удаления) Combatant-ы

# Размер стороны (для спавна).
const _SUMMON_SEARCH_RADIUS: int = 4


func _init() -> void:
	grid = GridScript.new()


## Возвращает всех живых участников.
func all_combatants() -> Array:
	var result: Array = []
	for c in combatant_registry:
		if c == null:
			continue
		if c.is_alive():
			result.append(c)
	return result


## Возвращает всех живых участников команды.
func combatants_of_team(team: int) -> Array:
	var result: Array = []
	for c in combatant_registry:
		if c == null or not c.is_alive():
			continue
		if c.team == team:
			result.append(c)
	return result


## Регистрирует Combatant-а и ставит на сетку.
func register(combatant, cell: Vector2i) -> bool:
	if combatant == null:
		return false
	if not grid.in_bounds(cell):
		GameLog.warn("battle", "register: out of bounds", {"cell": cell})
		return false
	if grid.is_occupied(cell):
		GameLog.warn("battle", "register: cell occupied", {"cell": cell})
		return false
	combatant.cell = cell
	combatant_registry.append(combatant)
	grid.set_cell(cell, combatant)
	return true


## Удаляет Combatant-а с сетки (но не из реестра — это делает unregister).
func unregister(combatant) -> void:
	if combatant == null:
		return
	if combatant.cell != Vector2i(-1, -1):
		grid.clear_cell(combatant.cell)
	combatant.cell = Vector2i(-1, -1)
	combatant_registry.erase(combatant)


## Двигает Combatant-а на 1 клетку в направлении (без проверки коллизий v1).
func move_to(combatant, new_cell: Vector2i) -> bool:
	if combatant == null:
		return false
	if not grid.in_bounds(new_cell):
		return false
	if grid.is_occupied(new_cell):
		return false
	grid.clear_cell(combatant.cell)
	combatant.cell = new_cell
	grid.set_cell(new_cell, combatant)
	return true


## Шаг по линии от target_cell в направлении combatant-а.
## Используется MoveEffect. Возвращает true, если двигался хоть раз.
func try_move_along_line(combatant, target_cell: Vector2i, distance: int) -> bool:
	if combatant == null or target_cell == null:
		return false
	var moved_any: bool = false
	for step in distance:
		if combatant.cell == target_cell:
			break
		var delta: Vector2i = target_cell - combatant.cell
		var step_dir: Vector2i = Vector2i(
			1 if delta.x > 0 else (-1 if delta.x < 0 else 0),
			1 if delta.y > 0 else (-1 if delta.y < 0 else 0)
		)
		var next: Vector2i = combatant.cell + step_dir
		if not grid.in_bounds(next) or grid.is_occupied(next):
			break
		if move_to(combatant, next):
			moved_any = true
	return moved_any


## Спавнит юнита рядом с source. Возвращает созданного Combatant или null.
func summon_near(source, def: Resource) -> Variant:
	if source == null or def == null:
		return null
	var origin: Vector2i = source.cell
	# Ищем ближайшую свободную клетку стороны source.team.
	# source.team: 0=PLAYER (нижние ряды, y >= 2), 1=ENEMY (верхние, y < 2).
	var best_cell: Vector2i = Vector2i(-1, -1)
	var best_dist: int = 999999
	for c in grid.all_cells():
		if grid.is_occupied(c):
			continue
		var on_side: bool = (source.team == 0 and c.y >= 2) or (source.team == 1 and c.y < 2)
		if not on_side:
			continue
		var d: int = absi(c.x - origin.x) + absi(c.y - origin.y)
		if d > _SUMMON_SEARCH_RADIUS:
			continue
		if d < best_dist:
			best_dist = d
			best_cell = c
	if best_cell == Vector2i(-1, -1):
		return null
	var summoned = CombatantScript.new(def)
	summoned.just_summoned = true
	if register(summoned, best_cell):
		return summoned
	return null