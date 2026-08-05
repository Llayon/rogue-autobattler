extends Control
## S6.1: Reward modal — показывается на REWARD phase, предлагает выбрать юнита.
##
## Лейаут: full-rect затемняющий фон + центральная панель с 3 кнопками
## (по одному юниту) и кнопкой Skip. При клике вызывает
## run_controller.choose_reward(slot) или run_controller.skip_reward().
##
## Модалка живёт в scenes/battle/battle_scene.gd как overlay; show_offer()
## обновляет контент при reward_offered signal.

const ContentDBStatic = preload("res://core/utils/content_db.gd")
const BalanceScript = preload("res://core/balance.gd")

var _buttons: Array[Button] = []
var _skip_button: Button = null
var _run_controller: Node = null


func _ready() -> void:
	_build_background()
	_build_panel()


func _build_background() -> void:
	var bg: ColorRect = ColorRect.new()
	bg.name = "Backdrop"
	bg.color = Color(0.02, 0.04, 0.10, 0.78)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	# S6.1: Backdrop pure-visual (mouse_filter IGNORE). Клики проходят
	# сквозь backdrop к Panel/Buttons. Если backdrop STOP — он бы
	# перехватывал клики вне панели, но клики НАД панелью всё равно идут в панель.
	# IGNORE безопаснее и не блокирует future click-outside-to-close поведение.
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)


func _build_panel() -> void:
	# S6.1: CenterContainer центрирует дочерний panel в пределах full-rect
	# родителя. Раньше PanelContainer с anchors_preset(PRESET_CENTER) +
	# custom_minimum_size не центрировал — anchors не работают для
	# Container'ов с layout.
	var center: CenterContainer = CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE  # клики проходят к panel
	add_child(center)

	var panel: PanelContainer = PanelContainer.new()
	panel.name = "Panel"
	panel.custom_minimum_size = Vector2(720, 360)
	panel.add_theme_stylebox_override("panel", _make_panel_style())
	panel.mouse_filter = Control.MOUSE_FILTER_STOP  # поглощает клики, передаёт детям
	center.add_child(panel)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var title: Label = Label.new()
	title.text = "REWARD — choose a unit (or skip)"
	title.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font(title)
	vbox.add_child(title)

	var hbox: HBoxContainer = HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 24)
	vbox.add_child(hbox)

	# 3 кнопки выбора (slot 0/1/2).
	for i in 3:
		var btn: Button = Button.new()
		btn.name = "Choice_%d" % i
		btn.custom_minimum_size = Vector2(180, 200)
		btn.add_theme_font_size_override("font_size", 14)
		btn.add_theme_stylebox_override("normal", _make_button_style(Color(0.16, 0.22, 0.32)))
		btn.add_theme_stylebox_override("hover", _make_button_style(Color(0.22, 0.30, 0.44)))
		btn.add_theme_stylebox_override("pressed", _make_button_style(Color(0.12, 0.18, 0.28)))
		_apply_font(btn)
		btn.pressed.connect(_on_choice_pressed.bind(i))
		_buttons.append(btn)
		hbox.add_child(btn)

	_skip_button = Button.new()
	_skip_button.text = "Skip (SPACE)"
	_skip_button.custom_minimum_size = Vector2(160, 40)
	_skip_button.add_theme_font_size_override("font_size", 14)
	_skip_button.add_theme_stylebox_override("normal", _make_button_style(Color(0.32, 0.22, 0.18)))
	_skip_button.add_theme_stylebox_override("hover", _make_button_style(Color(0.44, 0.30, 0.22)))
	_skip_button.add_theme_stylebox_override("pressed", _make_button_style(Color(0.28, 0.18, 0.16)))
	_apply_font(_skip_button)
	_skip_button.pressed.connect(_on_skip_pressed)
	var skip_row: HBoxContainer = HBoxContainer.new()
	skip_row.alignment = BoxContainer.ALIGNMENT_CENTER
	skip_row.add_child(_skip_button)
	vbox.add_child(skip_row)


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


func _make_button_style(bg: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = Color(0.65, 0.75, 0.95, 0.6)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


## S6.1: explicit Unicode SystemFont (Cyrillic + Latin) для всех Control'ов.
## Default Godot font в headless не рендерит кириллицу; явный fallback через
## SystemFont + Noto Sans / Arial даёт Unicode coverage на любой платформе.
var _ui_font: SystemFont = null


func _get_ui_font() -> SystemFont:
	if _ui_font != null:
		return _ui_font
	_ui_font = SystemFont.new()
	_ui_font.font_names = PackedStringArray([
		"Noto Sans", "Noto Sans CJK", "DejaVu Sans", "Arial", "sans-serif",
	])
	_ui_font.allow_system_fallback = true
	_ui_font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	return _ui_font


func _apply_font(control: Control) -> void:
	var font: SystemFont = _get_ui_font()
	if control is Label:
		control.add_theme_font_override("font", font)
	elif control is Button:
		control.add_theme_font_override("font", font)


## Обновляет контент модалки по списку предложенных юнитов (id'ы UnitDef).
func show_offer(unit_ids: Array, run_controller: Node) -> void:
	_run_controller = run_controller
	# S6.1.2: если board полный И bench полный, выбирать некуда.
	# Все Choice-кнопки делаем disabled + меняем Skip label.
	var no_room: bool = false
	if _run_controller != null:
		var board_size: int = _run_controller.state.player_unit_ids.size()
		var bench_size: int = _run_controller.state.bench_unit_ids.size()
		no_room = (board_size >= BalanceScript.MAX_BOARD_UNITS and
			bench_size >= BalanceScript.MAX_BENCH_UNITS)
	if _skip_button != null:
		_skip_button.text = "Skip — bench & board full" if no_room else "Skip (SPACE)"
	for i in _buttons.size():
		var btn: Button = _buttons[i]
		if i < unit_ids.size():
			var id: StringName = unit_ids[i]
			var def: Resource = ContentDBStatic.get_by_id(id)
			if def != null:
				btn.text = "%s\nATK %d / HP %d\nTier %d" % [
					def.display_name,
					def.attack,
					def.max_hp,
					def.tier,
				]
				var gold_ok: bool = (_run_controller == null or _run_controller.state.gold >= BalanceScript.REWARD_OFFER_PRICE)
				btn.disabled = (not gold_ok) or no_room
				btn.visible = true
			else:
				btn.text = "(unknown)"
				btn.disabled = true
				btn.visible = true
		else:
			btn.visible = false


func _on_choice_pressed(slot: int) -> void:
	if _run_controller == null:
		return
	var chosen: Resource = _run_controller.choose_reward(slot)
	if chosen != null:
		visible = false


func _on_skip_pressed() -> void:
	if _run_controller == null:
		return
	if _run_controller.skip_reward():
		visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not visible or _run_controller == null:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_on_skip_pressed()
		var viewport: Viewport = get_viewport()
		if viewport != null:
			viewport.set_input_as_handled()
