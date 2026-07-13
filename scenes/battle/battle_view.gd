extends Control
## Минимальный визуализатор поля боя: рисует сетку, юнитов как цветные квадраты,
## HP-бары и подписи. Без ассетов — чисто процедурно, чтобы можно было запустить
## и увидеть, что бой работает.

const CELL_SIZE: int = 64
const PADDING: int = 16
const BAR_HEIGHT: int = 6

@export var background_color: Color = Color(0.10, 0.10, 0.15)
@export var grid_color: Color = Color(0.20, 0.20, 0.28)
@export var player_color: Color = Color(0.30, 0.60, 1.00)
@export var enemy_color: Color = Color(1.00, 0.30, 0.30)
@export var text_color: Color = Color(0.95, 0.95, 0.95)

var _ctx: BattleContext = null


func set_context(ctx: BattleContext) -> void:
	_ctx = ctx
	queue_redraw()


func _draw() -> void:
	if _ctx == null:
		return
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	draw_rect(rect, background_color)
	var grid: Grid = _ctx.grid
	var origin_x: float = (size.x - grid.width() * CELL_SIZE) / 2.0
	var origin_y: float = (size.y - grid.height() * CELL_SIZE) / 2.0
	# Сетка.
	for y in grid.height():
		for x in grid.width():
			var cell_rect: Rect2 = Rect2(
				origin_x + x * CELL_SIZE,
				origin_y + y * CELL_SIZE,
				CELL_SIZE,
				CELL_SIZE,
			)
			draw_rect(cell_rect, grid_color, false, 1.0)
	# Юниты.
	for c in _ctx.all_combatants():
		if c == null:
			continue
		var cell: Vector2i = c.cell
		var pos: Vector2 = Vector2(
			origin_x + cell.x * CELL_SIZE + 4,
			origin_y + cell.y * CELL_SIZE + 4,
		)
		var sz: Vector2 = Vector2(CELL_SIZE - 8, CELL_SIZE - 8)
		var color: Color = player_color if c.team == Team.PLAYER else enemy_color
		draw_rect(Rect2(pos, sz), color)
		# HP-бар.
		var hp_ratio: float = float(c.current_hp) / float(maxi(1, c.max_hp()))
		var bar_w: float = sz.x * hp_ratio
		var bar_rect: Rect2 = Rect2(pos.x, pos.y + sz.y + 2, bar_w, BAR_HEIGHT)
		draw_rect(bar_rect, Color(0.2, 0.9, 0.3))
		draw_rect(Rect2(pos.x, pos.y + sz.y + 2, sz.x, BAR_HEIGHT), Color(0.3, 0.0, 0.0), false, 1.0)
		# Статусы.
		var statuses: Array = c.active_statuses()
		for i in statuses.size():
			var s: Dictionary = statuses[i]
			var status_rect: Rect2 = Rect2(pos.x + i * 6, pos.y - 6, 5, 5)
			var status_color: Color = Color(1, 0.5, 0) if s.def.is_harmful else Color(0.3, 0.7, 1.0)
			draw_rect(status_rect, status_color)
		# Имя.
		var font: Font = ThemeDB.fallback_font
		if font != null:
			draw_string(font, pos + Vector2(0, -10), String(c.def_id), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, text_color)