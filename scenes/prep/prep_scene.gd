extends Control
## S6.2: PREP phase placement screen.
## Показывается между REWARD и BATTLE (и на старте рана).
## Игрок может swap юнитов на доске, move board↔bench, нажать Ready.
##
## Layout: full-rect overlay с затемнением. Внутри:
## - Title "PREP — arrange your units"
## - Board grid (горизонтальные кнопки для каждого board slot)
## - Bench strip (если есть юниты)
## - Ready button (или SPACE)

const ContentDBStatic = preload("res://core/utils/content_db.gd")
const BalanceScript = preload("res://core/balance.gd")

var run_controller: Node = null
var _board_buttons: Array[Button] = []
var _bench_buttons: Array[Button] = []
var _ready_button: Button = null
# Click flow state: null / {kind: "board"|"bench", index: int}
var _selected: Dictionary = {}


func _ready() -> void:
	_build_background()
	_build_panel()
	# S6.2: если set_run_controller был вызван ДО add_child (например, из test),
	# пересобираем панель сейчас когда is_inside_tree = true.
	if run_controller != null:
		_rebuild()


## S6.2: подключить RunController и перестроить UI под его state.
func set_run_controller(ctrl: Node) -> void:
	run_controller = ctrl
	# Если _ready уже отработал — пересобрать панель.
	if is_inside_tree():
		_rebuild()


func _build_background() -> void:
	var bg: ColorRect = ColorRect.new()
	bg.name = "Backdrop"
	bg.color = Color(0.02, 0.04, 0.10, 0.78)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)


func _build_panel() -> void:
	var center: CenterContainer = CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel: PanelContainer = PanelContainer.new()
	panel.name = "Panel"
	panel.custom_minimum_size = Vector2(960, 440)
	panel.add_theme_stylebox_override("panel", _make_panel_style())
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(panel)
	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)
	# Title.
	var title: Label = Label.new()
	title.name = "Title"
	title.text = "PREP — arrange your units (SPACE to start)"
	title.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	title.add_theme_font_size_override("font_size", 20)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	# Board strip.
	var board_label: Label = Label.new()
	board_label.text = "Board"
	board_label.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	vbox.add_child(board_label)
	var board_row: HBoxContainer = HBoxContainer.new()
	board_row.name = "BoardRow"
	board_row.alignment = BoxContainer.ALIGNMENT_CENTER
	board_row.add_theme_constant_override("separation", 12)
	vbox.add_child(board_row)
	# Bench strip.
	var bench_label: Label = Label.new()
	bench_label.name = "BenchLabel"
	bench_label.text = "Bench"
	bench_label.add_theme_color_override("font_color", Color(0.85, 0.75, 0.6))
	vbox.add_child(bench_label)
	var bench_row: HBoxContainer = HBoxContainer.new()
	bench_row.name = "BenchRow"
	bench_row.alignment = BoxContainer.ALIGNMENT_CENTER
	bench_row.add_theme_constant_override("separation", 12)
	vbox.add_child(bench_row)
	# Ready button.
	_ready_button = Button.new()
	_ready_button.name = "ReadyButton"
	_ready_button.text = "Ready (SPACE)"
	_ready_button.custom_minimum_size = Vector2(200, 50)
	_ready_button.add_theme_font_size_override("font_size", 18)
	_ready_button.add_theme_stylebox_override("normal", _make_ready_style(Color(0.30, 0.50, 0.30)))
	_ready_button.add_theme_stylebox_override("hover", _make_ready_style(Color(0.40, 0.60, 0.40)))
	_ready_button.add_theme_stylebox_override("pressed", _make_ready_style(Color(0.25, 0.40, 0.25)))
	_ready_button.pressed.connect(_on_ready_pressed)
	var ready_row: HBoxContainer = HBoxContainer.new()
	ready_row.alignment = BoxContainer.ALIGNMENT_CENTER
	ready_row.add_child(_ready_button)
	vbox.add_child(ready_row)
	# Apply explicit SystemFont (Cyrillic).
	var font: SystemFont = SystemFont.new()
	font.font_names = PackedStringArray([
		"Noto Sans", "Noto Sans CJK", "DejaVu Sans", "Arial", "sans-serif",
	])
	font.allow_system_fallback = true
	for c in [title, board_label, bench_label, _ready_button]:
		if c is Label:
			c.add_theme_font_override("font", font)
		elif c is Button:
			c.add_theme_font_override("font", font)


func _make_panel_style() -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.14, 0.22, 0.96)
	sb.border_color = Color(0.55, 0.65, 0.85, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	return sb


func _make_ready_style(bg: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = Color(0.6, 0.8, 0.6, 0.7)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


## Перестраивает кнопки board + bench под текущий state.run_controller.state.
func _rebuild() -> void:
	if run_controller == null:
		return
	_clear_buttons()
	_build_board_buttons()
	_build_bench_buttons()
	_apply_selection_style()


func _clear_buttons() -> void:
	for btn in _board_buttons:
		if is_instance_valid(btn):
			btn.queue_free()
	_board_buttons.clear()
	for btn in _bench_buttons:
		if is_instance_valid(btn):
			btn.queue_free()
	_bench_buttons.clear()


func _build_board_buttons() -> void:
	var row: HBoxContainer = get_node_or_null("Center/Panel/VBox/BoardRow")
	if row == null:
		return
	var ids: Array = run_controller.state.player_unit_ids
	for i in ids.size():
		var def: Resource = ContentDBStatic.get_by_id(ids[i])
		var btn: Button = _make_unit_button("board", i, def)
		row.add_child(btn)
		_board_buttons.append(btn)


func _build_bench_buttons() -> void:
	var row: HBoxContainer = get_node_or_null("Center/Panel/VBox/BenchRow")
	var label: Label = get_node_or_null("Center/Panel/VBox/BenchLabel")
	if row == null:
		return
	var ids: Array = run_controller.state.bench_unit_ids
	if ids.is_empty():
		if label != null:
			label.text = "Bench (empty)"
		return
	if label != null:
		label.text = "Bench"
	for i in ids.size():
		var def: Resource = ContentDBStatic.get_by_id(ids[i])
		var btn: Button = _make_unit_button("bench", i, def)
		row.add_child(btn)
		_bench_buttons.append(btn)


func _make_unit_button(kind: String, index: int, def: Resource) -> Button:
	var btn: Button = Button.new()
	btn.name = "%s_%d" % [kind.capitalize(), index]
	btn.custom_minimum_size = Vector2(120, 110)
	btn.add_theme_font_size_override("font_size", 14)
	if def != null:
		btn.text = "%s\nATK %d\nHP %d" % [def.display_name, def.attack, def.max_hp]
	else:
		btn.text = "(?)"
	# Tag для click handler.
	btn.set_meta("kind", kind)
	btn.set_meta("index", index)
	btn.pressed.connect(_on_unit_pressed.bind(kind, index))
	_apply_button_style(btn, kind, false)
	return btn


func _apply_button_style(btn: Button, kind: String, selected: bool) -> void:
	var base: Color
	match kind:
		"board":
			base = Color(0.16, 0.22, 0.32)
		"bench":
			base = Color(0.32, 0.22, 0.16)
		_:
			base = Color(0.20, 0.20, 0.20)
	if selected:
		base = base.lightened(0.25)
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = base
	sb.border_color = Color(1, 0.95, 0.3, 0.9) if selected else Color(0.55, 0.55, 0.65, 0.6)
	sb.set_border_width_all(3 if selected else 1)
	sb.set_corner_radius_all(8)
	btn.add_theme_stylebox_override("normal", sb)


func _apply_selection_style() -> void:
	for i in _board_buttons.size():
		var sel: bool = (_selected.get("kind", "") == "board" and int(_selected.get("index", -1)) == i)
		_apply_button_style(_board_buttons[i], "board", sel)
	for i in _bench_buttons.size():
		var sel2: bool = (_selected.get("kind", "") == "bench" and int(_selected.get("index", -1)) == i)
		_apply_button_style(_bench_buttons[i], "bench", sel2)


## Обработчик клика на юнита (board или bench).
func _on_unit_pressed(kind: String, index: int) -> void:
	if run_controller == null:
		return
	if _selected.is_empty():
		# Первый клик: select.
		_selected = {"kind": kind, "index": index}
		_apply_selection_style()
		return
	# Второй клик: dispatch по комбинации.
	var src_kind: String = _selected.get("kind", "")
	var src_index: int = int(_selected.get("index", -1))
	if src_kind == kind and src_index == index:
		# Клик на ту же кнопку — clear selection.
		_selected = {}
		_apply_selection_style()
		return
	# Execute.
	if src_kind == "board" and kind == "board":
		run_controller.swap_board_units(src_index, index)
	elif src_kind == "board" and kind == "bench":
		run_controller.board_to_bench(src_index)
	elif src_kind == "bench" and kind == "board":
		run_controller.bench_to_board(src_index, index)
	elif src_kind == "bench" and kind == "bench":
		# Bench swap: не реализовано пока (нужно добавить в RunController если нужно).
		# Пока пропускаем.
		_selected = {}
		_apply_selection_style()
		return
	# Refresh UI после успешной операции.
	_selected = {}
	_rebuild()


## Обработчик клика Ready.
func _on_ready_pressed() -> void:
	if run_controller == null:
		return
	run_controller.start_battle()


## Обработчик keyboard input — SPACE = Ready.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			if run_controller != null and run_controller.phase == run_controller.Phase.PREP:
				run_controller.start_battle()
