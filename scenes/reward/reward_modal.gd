extends Control
const ResponsiveUILayoutScript = preload("res://core/ui/responsive_ui_layout.gd")


## The responsive layout: the interface is drawn in the base space and
## the node compensates the engine's downscale.
## The root of the compensated UI.
var _layout: ResponsiveUILayoutScript = null
var _ui_root: Control = null

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


## The physical size of an interactive area, in the base space.


## The base-space length for a physical (CSS) length.
##
## The engine shrinks the viewport by `engine_scale`, so a physical
## length P is expressed in the base space as P / engine_scale. On the
## desktop the scale is 1 and nothing changes.
func _px(physical_px: float) -> float:
	if _layout == null:
		return physical_px
	return _layout.px(physical_px)


## The same for an integer length.
func _px_i(physical_px: int) -> int:
	if _layout == null:
		return physical_px
	return _layout.px_i(physical_px)

func _touch_size(base_size: Vector2) -> Vector2:
	if _layout == null:
		return base_size
	return _layout.touch_px(base_size)


## The physical font size of a base-space font size.
func _font_px(base_px: int) -> int:
	if _layout == null:
		return base_px
	return _layout.font_px(base_px)


## The window's size in physical (CSS) pixels.

## The window's size in physical (CSS) pixels.
##
## `get_window().size` is the window's own pixel size. In the web
## build that IS the canvas's CSS size -- the physical size the player
## sees.
##
## The headless `--script` mode reports Godot's default 64x64 window,
## which is not a real viewport. A size below the base width is
## therefore rejected, and the base size is used: the desktop layout.
func _window_size() -> Vector2:
	var theWindow := get_window()
	if theWindow == null:
		return Vector2(ResponsiveUILayoutScript.BASE_WIDTH, ResponsiveUILayoutScript.BASE_HEIGHT)
	var theSize := theWindow.size
	# A degenerate or tiny window is the headless default, not a
	# viewport.
	if theSize.x < 200.0 or theSize.y < 200.0:
		return Vector2(ResponsiveUILayoutScript.BASE_WIDTH, ResponsiveUILayoutScript.BASE_HEIGHT)
	return theSize


## Builds the compensated UI root.
##
## The content is drawn in the base space; this node's scale returns the
## physical size that the engine's `canvas_items + expand` downscale took
## away. On the desktop the scale is 1 and nothing changes.
func _build_ui_root() -> void:
	if _ui_root != null:
		return
	_ui_root = Control.new()
	_ui_root.name = "UiRoot"
	_ui_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ui_root)
	if _layout != null:
		_layout.apply_to(_ui_root)


## The size that fits the screen, in the base space.
func _fit_size(desired: Vector2) -> Vector2:
	if _layout == null:
		return desired
	return _layout.fit(desired, 16.0)

func _ready() -> void:
	# The layout is taken from the window ONCE: a layout that was
	# set before the scene entered the tree is kept.
	if _layout == null:
		_layout = ResponsiveUILayoutScript.from_window(_window_size())
	_build_ui_root()
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
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_ui_root.add_child(bg)


## The reward choice's height on a phone.
##
## The reward's content is the title + the three choices + the skip
## button + the separations. On a 360x640 phone the three choices at
## 200 physical px each are 738 px of content -- 98 px MORE than the
## screen, so the third choice and the Skip button were cut off.
##
## The choices share the height that is left, so the whole reward
## fits the screen and every choice stays reachable. The touch floor
## is the minimum.
func _choice_button_height() -> float:
	var theHeight: float = _touch_size(Vector2(180, 200)).y
	if _layout == null or not _layout.is_mobile():
		return theHeight
	# The physical height that is left for the three choices.
	# The available height: the screen minus the panel's own margins
	# (36 physical px), the outer margin (16), the title, the skip
	# button and the separations.
	var theAvailable: float = float(_layout.view_height) - 32.0 - 36.0 \
		- 56.0 - 40.0 - 48.0
	# The share is a PHYSICAL height, and the result is a BASE size
	# (the button lives in the base space).
	var theEach: float = _px(theAvailable / 3.0)
	return maxf(ResponsiveUILayoutScript.MIN_TOUCH_PX, minf(theHeight, theEach))

func _build_panel() -> void:
	# S6.1: CenterContainer центрирует дочерний panel в пределах full-rect
	# родителя. Раньше PanelContainer с anchors_preset(PRESET_CENTER) +
	# custom_minimum_size не центрировал — anchors не работают для
	# Container'ов с layout.
	# The build is idempotent: the old panel is removed first.
	# A rebuild (the orientation changed) must not leave a
	# stale one behind -- and the node lookup must find the
	# CURRENT one.
	for theChild in _ui_root.get_children():
		if theChild.name == "Center":
			# The removal is IMMEDIATE: queue_free() is deferred,
			# so the stale panel would stay in the tree for a
			# frame, and the node lookup would find it.
			_ui_root.remove_child(theChild)
			theChild.queue_free()
	# The build is idempotent: the old panel is removed first.
	# A rebuild (the orientation changed) must not leave a
	# stale one behind -- and the node lookup must find the
	# CURRENT one.
	for theChild in _ui_root.get_children():
		if theChild.name == "Center":
			theChild.queue_free()
	var center: CenterContainer = CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE  # клики проходят к panel
	_ui_root.add_child(center)

	var panel: PanelContainer = PanelContainer.new()
	panel.name = "Panel"
	# The panel's minimum: the available area MINUS the content's
	# margins. `fit()` returns the WHOLE available area, and the
	# style's margins are added on top of it -- so the panel became
	# taller than the screen (2356 base px = 664 physical on a 640 px
	# phone) and the third choice and the Skip button were cut off.
	# `custom_minimum_size` only RAISES a Control's minimum, so it can
	# never make the panel smaller than its content. On a phone the
	# panel takes the CONTENT's size (the content is built to fit the
	# screen) and the Center centres it; on the desktop the custom
	# minimum keeps the layout exactly as it was.
	if _layout == null or not _layout.is_mobile():
		panel.custom_minimum_size = _fit_size(Vector2(720, 360))
	panel.add_theme_stylebox_override("panel", _make_panel_style())
	panel.mouse_filter = Control.MOUSE_FILTER_STOP  # поглощает клики, передаёт детям
	center.add_child(panel)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", _px_i(12))
	panel.add_child(vbox)

	var title: Label = Label.new()
	title.text = "REWARD — choose a unit (or skip)"
	title.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_size_override("font_size", _font_px(22))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font(title)
	vbox.add_child(title)

	# The choices' row: on a narrow screen they STACK. Three
	# 180 px buttons side by side are 588 px wide, and the
	# phone's panel is 358 px -- two of the three choices would
	# be entirely off the screen.
	var theStacked: bool = _layout != null and _layout.is_mobile() \
			and _layout.view_width < 560.0
	var hbox: BoxContainer = VBoxContainer.new() if theStacked else HBoxContainer.new()
	hbox.name = "ChoicesRow"
	if hbox is HBoxContainer:
		hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", _px_i(24))
	vbox.add_child(hbox)

	# 3 кнопки выбора (slot 0/1/2).
	for i in 3:
		var btn: Button = Button.new()
		btn.name = "Choice_%d" % i
		btn.custom_minimum_size = Vector2(
			_fit_size(Vector2(720, 360)).x - 48.0,
			_choice_button_height()) if theStacked else _touch_size(Vector2(180, 200))
		btn.add_theme_font_size_override("font_size", _font_px(14))
		btn.add_theme_stylebox_override("normal", _make_button_style(Color(0.16, 0.22, 0.32)))
		btn.add_theme_stylebox_override("hover", _make_button_style(Color(0.22, 0.30, 0.44)))
		btn.add_theme_stylebox_override("pressed", _make_button_style(Color(0.12, 0.18, 0.28)))
		_apply_font(btn)
		btn.pressed.connect(_on_choice_pressed.bind(i))
		_buttons.append(btn)
		hbox.add_child(btn)

	_skip_button = Button.new()
	_skip_button.text = "Skip (SPACE)"
	_skip_button.custom_minimum_size = _touch_size(Vector2(160, 40))
	_skip_button.add_theme_font_size_override("font_size", _font_px(14))
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
	sb.content_margin_left = _px(24)
	sb.content_margin_right = _px(24)
	sb.content_margin_top = _px(18)
	sb.content_margin_bottom = _px(18)
	return sb


func _make_button_style(bg: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = Color(0.65, 0.75, 0.95, 0.6)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = _px(8)
	sb.content_margin_right = _px(8)
	sb.content_margin_top = _px(8)
	sb.content_margin_bottom = _px(8)
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
		var board_size: int = _run_controller.state.get_board_units().size()
		var bench_size: int = _run_controller.state.get_bench_units().size()
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
