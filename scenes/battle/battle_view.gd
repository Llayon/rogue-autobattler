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
# S4.2: floating damage numbers [{target_id, cell, amount, time_remaining}].
var _damage_numbers: Array = []


func set_context(ctx: BattleContext) -> void:
	_ctx = ctx
	queue_redraw()


func _ready() -> void:
	# S4.2: подписка на damage_dealt signal.
	var bus: Node = _find_event_bus()
	if bus != null:
		bus.damage_dealt.connect(_on_damage_dealt)


## S4.2: возвращает EventBus instance или null.
func _find_event_bus() -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.root.get_node_or_null("EventBus")


## S4.2: callback для damage_dealt — добавляет floating number.
func _on_damage_dealt(target, amount: int, _source) -> void:
	if target == null:
		return
	var cell: Vector2i = target.cell if "cell" in target else Vector2i(-1, -1)
	if cell.x < 0:
		return
	_damage_numbers.append({
		"target_id": target.get_instance_id(),
		"cell": cell,
		"amount": amount,
		"time_remaining": 0.6,
	})
	queue_redraw()


func _process(delta: float) -> void:
	# S4.2: TTL для damage numbers.
	if _damage_numbers.is_empty():
		return
	var new_list: Array = []
	for entry in _damage_numbers:
		entry["time_remaining"] -= delta
		if entry["time_remaining"] > 0.0:
			new_list.append(entry)
	_damage_numbers = new_list
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
		# S4.3: lerp между prev_cell и cell по pos_lerp.
		var lerp_t: float = 1.0 - c.visual_state["pos_lerp"]  # 0 = prev, 1 = current
		var draw_cell: Vector2 = Vector2(
			lerpf(c.prev_cell.x, c.cell.x, lerp_t),
			lerpf(c.prev_cell.y, c.cell.y, lerp_t)
		)
		var cell_rect: Vector2 = Vector2(
			origin_x + draw_cell.x * CELL_SIZE + 4,
			origin_y + draw_cell.y * CELL_SIZE + 4,
		)
		var sz: Vector2 = Vector2(CELL_SIZE - 8, CELL_SIZE - 8)
		# S4.3: flash_alpha модулирует цвет (white flash на hit).
		var base_color: Color = player_color if c.team == Team.PLAYER else enemy_color
		var flash: float = c.visual_state["flash_alpha"]
		var fade: float = c.visual_state["fade_alpha"]
		var modulated: Color = base_color.lerp(Color.WHITE, flash)
		modulated.a = modulated.a * fade
		draw_rect(Rect2(cell_rect, sz), modulated)
		# HP-бар.
		# Combatant: current_hp это поле HealthComponent (не метод!), max_hp() это метод.
		var hp_ratio: float = float(c.health.current_hp) / float(maxi(1, c.max_hp()))
		var bar_w: float = sz.x * hp_ratio
		var bar_rect: Rect2 = Rect2(cell_rect.x, cell_rect.y + sz.y + 2, bar_w, BAR_HEIGHT)
		# HP-бар тоже затухает при смерти.
		var hp_color: Color = Color(0.2, 0.9, 0.3)
		hp_color.a = fade
		draw_rect(bar_rect, hp_color)
		var hp_bg: Color = Color(0.3, 0.0, 0.0)
		hp_bg.a = fade
		draw_rect(Rect2(cell_rect.x, cell_rect.y + sz.y + 2, sz.x, BAR_HEIGHT), hp_bg, false, 1.0)
		# S4.2: attack meter indicator (жёлтая полоска прогресса).
		var meter_ratio: float = clampf(c.attack_meter.progress(c.attack_speed()), 0.0, 1.0)
		var meter_w: float = sz.x * meter_ratio
		var meter_color: Color = Color(1.0, 0.9, 0.3)
		meter_color.a = fade
		draw_rect(Rect2(cell_rect.x, cell_rect.y + sz.y + 10, meter_w, 2), meter_color)
		# Статусы.
		var statuses: Array = c.active_statuses()
		for i in statuses.size():
			var s: Dictionary = statuses[i]
			var status_rect: Rect2 = Rect2(cell_rect.x + i * 6, cell_rect.y - 6, 5, 5)
			var status_color: Color = Color(1, 0.5, 0) if s.def.is_harmful else Color(0.3, 0.7, 1.0)
			status_color.a = fade
			draw_rect(status_rect, status_color)
		# Имя.
		var font: Font = ThemeDB.fallback_font
		if font != null:
			var name_color: Color = text_color
			name_color.a = fade
			draw_string(font, cell_rect + Vector2(0, -10), String(c.def_id), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, name_color)
	# S4.2: floating damage numbers overlay (поверх юнитов).
	if not _damage_numbers.is_empty():
		var dmg_font: Font = ThemeDB.fallback_font
		for entry in _damage_numbers:
			var ec: Vector2i = entry["cell"]
			if ec.x < 0 or ec.y < 0:
				continue
			var dmg_pos: Vector2 = Vector2(
				origin_x + ec.x * CELL_SIZE + 8,
				origin_y + ec.y * CELL_SIZE - 4
			)
			if dmg_font != null:
				draw_string(dmg_font, dmg_pos, str(entry["amount"]),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 0.3, 0.3))