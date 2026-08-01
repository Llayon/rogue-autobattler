class_name UIOverlay extends Control
## Overlay layer on top of battle_view. Renders HP-bars, cooldown rings, status icons.
##
## Hooks into BattleScene via _ready() — gets ctx reference and listens to EventBus.

const BattleContextScript = preload("res://core/battle/battle_context.gd")

var _ctx: BattleContext = null


func _ready() -> void:
	# Подключаемся к GameBus через EventBus autoload.
	var bus = get_node_or_null("/root/EventBus")
	if bus != null:
		bus.unit_damaged.connect(_on_unit_damaged)
		bus.unit_died.connect(_on_unit_died)
		bus.status_changed.connect(_on_status_changed)
		bus.ability_cast.connect(_on_ability_cast)
	queue_redraw()


func set_context(ctx: BattleContext) -> void:
	_ctx = ctx
	queue_redraw()


func _process(_delta: float) -> void:
	# Постоянная перерисовка прогресс-баров (mana, cooldown, hp).
	queue_redraw()


func _on_unit_damaged(_c, _amount: int, _source) -> void:
	queue_redraw()


func _on_unit_died(_c) -> void:
	queue_redraw()


func _on_status_changed(_c, _status_id: StringName, _applied: bool) -> void:
	queue_redraw()


func _on_ability_cast(_ability, _caster, _target) -> void:
	queue_redraw()


func _draw() -> void:
	if _ctx == null:
		return
	_draw_hp_bars()
	_draw_cooldown_rings()
	_draw_status_icons()


func _draw_hp_bars() -> void:
	# Тонкая плашка 4px под каждой клеткой с HP.
	for c in _ctx.all_combatants():
		if c == null or not c.is_alive():
			continue
		var cell: Vector2i = c.cell
		var pos: Vector2 = _cell_to_screen(cell, Vector2(60, 60))
		var hp_ratio: float = float(c.health.current_hp) / float(maxi(1, c.max_hp()))
		var bar_w: float = 60.0 * hp_ratio
		draw_rect(Rect2(pos.x, pos.y + 60, 60, 4), Color(0.2, 0.2, 0.2, 0.8))
		draw_rect(Rect2(pos.x, pos.y + 60, bar_w, 4), Color(0.2, 0.9, 0.3))


func _draw_cooldown_rings() -> void:
	# Тонкий индикатор кулдауна над кастером (закруглённый квадрат).
	for c in _ctx.all_combatants():
		if c == null or c.abilities == null:
			continue
		var pos: Vector2 = _cell_to_screen(c.cell, Vector2(60, 60))
		for i in c.abilities.size():
			var ab: Resource = c.abilities[i]
			if ab == null:
				continue
			var remaining: float = c.cooldown_remaining(ab)
			if remaining <= 0.0:
				continue
			# Полоска над юнитом.
			var bar_y: float = pos.y - 6 + i * 4
			var total_cd: float = ab.cooldown
			var cd_ratio: float = 1.0 - (remaining / maxf(0.1, total_cd))
			draw_rect(Rect2(pos.x, bar_y, 60 * cd_ratio, 2), Color(0.4, 0.6, 1.0))


func _draw_status_icons() -> void:
	# Маленькие цветные точки справа от юнита.
	for c in _ctx.all_combatants():
		if c == null or not c.is_alive():
			continue
		var statuses: Array = c.active_statuses()
		var pos: Vector2 = _cell_to_screen(c.cell, Vector2(60, 60))
		for i in statuses.size():
			var s: Dictionary = statuses[i]
			var color: Color = _status_color(s.def)
			draw_circle(Vector2(pos.x + 62 + i * 5, pos.y + 8), 2.0, color)


func _status_color(status_def: Resource) -> Color:
	if status_def == null:
		return Color.GRAY
	# Хорошие — зелёный, плохие — красный, нейтральные — жёлтый.
	if status_def.is_harmful:
		return Color(1.0, 0.3, 0.3)
	elif status_def.blocks_actions:
		return Color(1.0, 0.8, 0.0)
	else:
		return Color(0.3, 0.9, 0.3)


func _cell_to_screen(cell: Vector2i, cell_size: Vector2) -> Vector2:
	# Grid 7x4, центрированная.
	var grid_w: float = 7.0 * cell_size.x
	var grid_h: float = 4.0 * cell_size.y
	var origin_x: float = (size.x - grid_w) / 2.0
	var origin_y: float = (size.y - grid_h) / 2.0
	return Vector2(origin_x + cell.x * cell_size.x, origin_y + cell.y * cell_size.y)
