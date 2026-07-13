class_name Grid extends RefCounted
## Сетка боя. Двумерный массив Vector2i(W,H).
##
## Координаты: x ∈ [0, W), y ∈ [0, H).
## y=0 — задний ряд (для команды ENEMY), y=H-1 — задний ряд PLAYER.
##
## Все проверки границ и занятости — через Grid; Combatant-ы
## не должны выходить за границы напрямую.
##
## Размер берётся из Balance (single source of truth).

const BalanceScript = preload("res://core/balance.gd")
const SIZE: Vector2i = Vector2i(BalanceScript.GRID_WIDTH, BalanceScript.GRID_HEIGHT)

var _cells: Array = []  # Array[Array], _cells[y][x] = Combatant или null


func _init() -> void:
	resize(SIZE.x, SIZE.y)


func resize(width: int, height: int) -> void:
	_cells.clear()
	for y in height:
		var row: Array = []
		for x in width:
			row.append(null)
		_cells.append(row)


func width() -> int:
	return SIZE.x


func height() -> int:
	return SIZE.y


func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < SIZE.x and cell.y < SIZE.y


func at(cell: Vector2i):  # не get(), чтобы не перекрывать Object.get()
	if not in_bounds(cell):
		return null
	return _cells[cell.y][cell.x]


func set_cell(cell: Vector2i, combatant) -> bool:
	if not in_bounds(cell):
		return false
	_cells[cell.y][cell.x] = combatant
	return true


func clear_cell(cell: Vector2i) -> void:
	if in_bounds(cell):
		_cells[cell.y][cell.x] = null


func is_occupied(cell: Vector2i) -> bool:
	return at(cell) != null


## Все клетки (для итераций). Возвращает массив Vector2i.
func all_cells() -> Array:
	var result: Array = []
	for y in SIZE.y:
		for x in SIZE.x:
			result.append(Vector2i(x, y))
	return result


## Все клетки стороны (для расстановки).
## team_filter: 0=PLAYER (нижние ряды), 1=ENEMY (верхние ряды).
func side_cells(team_filter: int) -> Array:
	var result: Array = []
	var y_start: int = 0 if team_filter == 1 else SIZE.y / 2
	var y_end: int = SIZE.y / 2 if team_filter == 1 else SIZE.y
	for y in range(y_start, y_end):
		for x in SIZE.x:
			result.append(Vector2i(x, y))
	return result


## Возвращает Combatant-ов в радиусе (Манхэттен).
func combatant_within(origin: Vector2i, radius: int, team_filter: int = -1) -> Array:
	var result: Array = []
	for y in SIZE.y:
		for x in SIZE.x:
			var cell: Vector2i = Vector2i(x, y)
			var occupant = _cells[y][x]
			if occupant == null:
				continue
			if absi(cell.x - origin.x) + absi(cell.y - origin.y) > radius:
				continue
			if team_filter >= 0 and occupant.team != team_filter:
				continue
			result.append(occupant)
	return result


## Простая сериализация для дебага/сохранений.
func to_dict() -> Dictionary:
	var rows: Array = []
	for y in SIZE.y:
		var row: Array = []
		for x in SIZE.x:
			var occupant = _cells[y][x]
			row.append(occupant.def_id if occupant != null else null)
		rows.append(row)
	return {"size": [SIZE.x, SIZE.y], "rows": rows}


## Дистанция Манхэттена.
static func distance(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


## Находит ближайшую занятую клетку к origin среди units.
static func nearest_to(origin: Vector2i, units: Array, max_range: int = -1):
	var best = null
	var best_dist: int = 999999
	for c in units:
		if c == null:
			continue
		var d: int = distance(origin, c.cell)
		if max_range >= 0 and d > max_range:
			continue
		if d < best_dist:
			best_dist = d
			best = c
	return best