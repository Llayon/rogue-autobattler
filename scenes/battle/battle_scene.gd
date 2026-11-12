extends Control
## Контроллер боевой сцены. Тикает RunController каждый кадр,
## подписан на сигналы EventBus для обновления HUD.

const RUN_CONTROLLER_SCRIPT: GDScript = preload("res://core/progression/run_controller.gd")
const BATTLE_VIEW_SCRIPT: GDScript = preload("res://scenes/battle/battle_view.gd")
const UI_OVERLAY_SCRIPT: GDScript = preload("res://scenes/battle/ui_overlay.gd")
const ENCOUNTER_MAP_SCENE_SCRIPT: GDScript = preload("res://scenes/encounter/encounter_map_scene.gd")
const REWARD_MODAL_SCRIPT: GDScript = preload("res://scenes/reward/reward_modal.gd")
const PREP_SCENE_SCRIPT: GDScript = preload("res://scenes/prep/prep_scene.gd")
const INVENTORY_SCENE_SCRIPT: GDScript = preload("res://scenes/inventory/inventory_scene.gd")
const SHOP_SCENE_SCRIPT: GDScript = preload("res://scenes/shop/shop_scene.gd")
const BalanceScript: GDScript = preload("res://core/balance.gd")
const RunLaunchRequestScript: GDScript = preload("res://core/progression/run_launch_request.gd")
const GameLog: GDScript = preload("res://core/utils/logger.gd")

# S6.1: явный Unicode SystemFont для всех UI-лейблов (Cyrillic работает).
var _ui_font: SystemFont = null



const ResponsiveUILayoutScript = preload("res://core/ui/responsive_ui_layout.gd")
## The responsive layout: the HUD and the touch controls are drawn in
var _layout: ResponsiveUILayoutScript = null
## The root of the compensated UI.
var _ui_root: Control = null

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

var run_controller: Node
var battle_view: Control
var ui_overlay: Control
var status_label: Label
# === S4.2: HUD bar ===
var hud: HBoxContainer
var hud_round_label: Label
var hud_gold_label: Label
var hud_wins_label: Label
var hud_lives_label: Label
# === S4.2: end-of-round summary ===
var summary_label: Label = null
var _summary_pending: bool = false
var speed: float = 1.0
var _bus: Node = null  # EventBus instance (autoload) или локальный
## the base space and the node compensates the engine's downscale.
## The on-screen controls (the touch path). Each one calls the SAME
## domain operation as the keyboard shortcut.
var _touch_bar: HBoxContainer = null
var _inventory_button: Button = null
var _speed_button: Button = null
var _buy_button: Button = null
var _restart_button: Button = null
# === S5.3: encounter map overlay on MAP phase ===
var encounter_map_scene: Control = null
# === S6.1: reward modal on REWARD phase ===
var reward_modal: Control = null


func _ready() -> void:
	# S4.2: HUD bar (поверх battle_view).
	# The responsive layout: the HUD and the touch controls keep
	# their physical size on a phone.
	_layout = ResponsiveUILayoutScript.from_window(_window_size())
	_build_ui_root()
	_build_hud()
	_build_touch_bar()
	# UI.
	battle_view = BATTLE_VIEW_SCRIPT.new()
	battle_view.name = "BattleView"
	battle_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	battle_view.custom_minimum_size = Vector2(900, 400)
	add_child(battle_view)
	# UIOverlay: HP-bars + cooldowns + status icons поверх battle_view.
	ui_overlay = UI_OVERLAY_SCRIPT.new()
	ui_overlay.name = "UIOverlay"
	ui_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ui_overlay)
	# Status label (нижний-левый, отдельно от HUD).
	status_label = Label.new()
	status_label.name = "StatusLabel"
	status_label.position = Vector2(16, size.y - 32)
	status_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	status_label.add_theme_font_size_override("font_size", _font_px(16))
	status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_font(status_label)
	_ui_root.add_child(status_label)
	# RunController.
	run_controller = RUN_CONTROLLER_SCRIPT.new()
	run_controller.name = "RunController"
	add_child(run_controller)
	# S6.1: reward modal (создаём заранее, но скрыт initial).
	_build_reward_modal()
	# S5.3: encounter map overlay (скрыт initial).
	_build_encounter_map_overlay()
	# S6.2: PREP scene (скрыт initial).
	_build_prep_scene()
	# S7.1: inventory scene (overlay, скрыт initial, toggle по I).
	_build_inventory_scene()
	# S7.4: shop scene (overlay, hidden initial, shown on PREP-from-MERCHANT).
	_build_shop_scene()
	# EventBus — подписки ДО start_run, чтобы первый phase_changed поймался.
	_bus = _find_event_bus()
	if _bus != null:
		_bus.battle_ended.connect(_on_battle_ended)
		_bus.unit_died.connect(_on_unit_died)
		_bus.round_started.connect(_on_round_started)
		_bus.gold_changed.connect(_on_gold_changed)
		_bus.reward_offered.connect(_on_reward_offered)
		_bus.lives_changed.connect(_on_lives_changed)
	# Подписываемся на phase_changed ДО start_run.
	if run_controller.has_signal("phase_changed"):
		run_controller.phase_changed.connect(_on_run_phase_changed)
	# The launch request carries the INTENT; the scene does not decide
	# whether the run is new or resumed.
	# A UI test can build the scene's TREE without starting a run: the
	# `suppress_run` meta is set only by the tests, and it leaves the
	# production path untouched (the meta is never set there).
	if has_meta("suppress_run"):
		return
	var launch_request: RunLaunchRequestScript = _read_launch_request()
	if launch_request == null:
		launch_request = RunLaunchRequestScript.new_run(Rng.randi_range(1, 999999))
	apply_launch_request(launch_request)


# === S4.2: HUD ===

func _build_hud() -> void:
	# S6.1: HUD — HBoxContainer с явной top-anchor (y=0) и width=full.
	# Раньше был PanelContainer + set_anchors_preset(PRESET_TOP_WIDE), но anchors
	# не работают для Container'ов с layout — детей они не выравнивали.
	hud = HBoxContainer.new()
	hud.name = "HUD"
	hud.set_anchors_preset(Control.PRESET_TOP_WIDE)
	hud.position = Vector2(0, 0)
	hud.add_theme_constant_override("separation", _px_i(24))
	hud.add_theme_stylebox_override("normal", _make_hud_panel_style())
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_root.add_child(hud)
	hud_round_label = _make_hud_label("Round 1")
	hud_gold_label = _make_hud_label("Gold: 0")
	hud_wins_label = _make_hud_label("Wins: 0")
	hud_lives_label = _make_hud_label("Lives: 0")
	hud.add_child(hud_round_label)
	hud.add_child(hud_gold_label)
	hud.add_child(hud_wins_label)
	hud.add_child(hud_lives_label)


func _make_hud_panel_style() -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.10, 0.16, 0.92)
	sb.border_color = Color(0.25, 0.30, 0.40, 0.6)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = _px(16)
	sb.content_margin_right = _px(16)
	sb.content_margin_top = _px(6)
	sb.content_margin_bottom = _px(6)
	return sb


func _make_hud_label(initial_text: String) -> Label:
	var label: Label = Label.new()
	label.text = initial_text
	label.add_theme_color_override("font_color", Color(0.92, 0.94, 1.0))
	label.add_theme_font_size_override("font_size", _font_px(16))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_font(label)
	return label


func _refresh_hud() -> void:
	if hud == null or run_controller == null or run_controller.state == null:
		return
	hud_round_label.text = "Round %d" % run_controller.state.round_index
	hud_gold_label.text = "Gold: %d" % run_controller.state.gold
	hud_wins_label.text = "Wins: %d" % run_controller.state.wins
	hud_lives_label.text = "Lives: %d" % run_controller.state.lives


## S6.1: обновить status_label по текущей фазе.
func _refresh_status() -> void:
	if status_label == null or run_controller == null:
		return
	match run_controller.phase:
		RunController.Phase.PREP:
			status_label.text = "PREP  Round %d  Gold %d  Press SPACE to start" % [
				run_controller.state.round_index, run_controller.state.gold]
		RunController.Phase.BATTLE:
			var t: float = 0.0
			if run_controller.runner != null:
				t = run_controller.runner.state.battle_time
			status_label.text = "BATTLE  t=%.1fs  speed=x%.1f  (1/2/4)" % [t, speed]
		RunController.Phase.REWARD:
			status_label.text = "REWARD — pick a unit or press SPACE to skip"
		RunController.Phase.MAP:
			status_label.text = "MAP — click an encounter node"
		RunController.Phase.GAMEOVER:
			status_label.text = "GAME OVER — round %d  (R to restart)" % run_controller.state.round_index
		_:
			status_label.text = ""


func _on_gold_changed(_new_value: int) -> void:
	_refresh_hud()
	_refresh_status()


func _on_lives_changed(_new_value: int) -> void:
	_refresh_hud()


## Возвращает инстанс EventBus (autoload "EventBus" из project.godot),
## или null если недоступен (в editor-mode без сцены).
func _find_event_bus() -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.root.get_node_or_null("EventBus")



## DEPRECATED: do not call this.
##
## This was the old "start a new run" entry point, and it is exactly the
## hole the launch-intent model closed: it starts a run without a
## `RunLaunchRequest`, so a caller can reintroduce the defect where a
## CONTINUE creates a replacement run instead of resuming.
##
## Nothing calls it any more. A new run goes through the launch
## request: `RunLaunchRequest.new_run(seed)` -> `apply_launch_request`
## -> `start_run`. Use that path.
func restart_with_seed(seed: int) -> void:
	GameLog.warn("battle", "restart_with_seed is deprecated; use the launch request")
	if run_controller != null:
		run_controller.start_run(seed)
	if run_controller != null and run_controller.profile != null:
		speed = run_controller.profile.battle_speed
	_refresh_hud()
	_refresh_status()


## Reads the launch request the RootScene attached to this scene.
## Returns null when the scene was created without one.
func _read_launch_request() -> RunLaunchRequestScript:
	if not has_meta("launch_request"):
		return null
	var request = get_meta("launch_request")
	if request is RunLaunchRequestScript:
		return request
	return null


## Applies an explicit launch request to the run controller.
##
## NEW RUN  -> start_run(seed): a fresh run, every subsystem is
##             regenerated.
## CONTINUE -> resume_run(seed): the persisted run is restored.
##
## A failed Continue is NOT retried as a new run: the controller
## reports the failure and the live state stays untouched.
func apply_launch_request(request: RunLaunchRequestScript) -> void:
	if run_controller == null or request == null:
		return
	var started: bool = true
	if request.is_continue():
		started = run_controller.resume_run(request.seed)
		if not started:
			# The resume failed: do NOT create a replacement run and
			# do NOT touch the existing save.
			GameLog.error("battle_scene", "CONTINUE failed", {"seed": request.seed})
	else:
		run_controller.start_run(request.seed)
	if run_controller != null and run_controller.profile != null:
		speed = run_controller.profile.battle_speed
	_refresh_hud()
	_refresh_status()
	if not started:
		# The run did not start. The live state and the save are
		# untouched; the router decides what to show next.
		GameLog.warn("battle_scene", "the launch request did not start a run",
			{"seed": request.seed})


## Starts a brand new run with a fresh seed (the "R" shortcut).
func start_new_run(seed: int) -> void:
	if run_controller != null:
		run_controller.start_run(seed)
	_refresh_hud()
	_refresh_status()


func _process(delta: float) -> void:
	if run_controller == null:
		return
	# Обновляем battle_view когда ctx меняется (новый бой).
	#
	# H-04: the NULL case matters. After a successful resume the
	# controller has NO context, and the view must not keep drawing
	# the combatants of the battle that is gone. The condition used
	# to require a non-null context, so the stale visual context
	# survived the resume.
	if battle_view != null and battle_view._ctx != run_controller.ctx:
		battle_view.set_context(run_controller.ctx)
	if ui_overlay != null and ui_overlay._ctx != run_controller.ctx:
		ui_overlay.set_context(run_controller.ctx)
	# Перерисовываем каждый кадр во время боя (юниты двигаются/получают урон).
	if run_controller.phase == RunController.Phase.BATTLE:
		run_controller.tick_battle(delta * speed)
		battle_view.queue_redraw()
	_refresh_status()


## The shared domain actions.
##
## The keyboard shortcuts and the on-screen buttons call the SAME
## methods, so there is exactly one implementation of every action and
## no possibility of the two paths drifting apart.
##
## ## The actions
## - `toggle_inventory` — the inventory overlay (the `I` key).
## - `set_battle_speed` — the battle speed (the `1`/`2`/`4` keys).
## - `buy_first_unit` — the unit purchase (the `B` key).
## - `start_battle` — the battle start (the `SPACE` key in PREP).
## - `restart_run` — the game-over restart (the `R` key).
func toggle_inventory() -> void:
	## Opens or closes the inventory overlay.
	##
	## The scene is created ONCE (in `_build_inventory_scene`) and only
	## its visibility changes, so a repeated tap never creates a second
	## InventoryScene.
	if inventory_scene == null:
		return
	var theNext: bool = not inventory_scene.visible
	inventory_scene.visible = theNext
	if theNext:
		inventory_scene.set_run_controller(run_controller)
	_refresh_touch_bar()
	get_viewport().set_input_as_handled()


func set_battle_speed(value: float) -> void:
	## Sets the battle speed.
	##
	## The value is one of the persisted profile's speeds (1.0, 2.0,
	## 4.0), so the on-screen control and the keyboard shortcut share
	## the one source of truth.
	speed = value
	if run_controller != null and run_controller.profile != null:
		run_controller.profile.battle_speed = value
	_refresh_hud()
	_refresh_status()


func buy_first_unit() -> void:
	## Buys a unit in the PREP phase.
	if run_controller == null:
		return
	if run_controller.phase != RunController.Phase.PREP:
		return
	run_controller.buy_unit(0)


func start_battle() -> void:
	## Starts the battle in the PREP phase.
	if run_controller == null:
		return
	if run_controller.phase != RunController.Phase.PREP:
		return
	run_controller.start_battle()


func restart_run() -> void:
	## Starts a new run after the game over.
	if run_controller == null:
		return
	if run_controller.phase != RunController.Phase.GAMEOVER:
		return
	run_controller.start_run(Rng.randi_range(1, 999999))


## Builds the on-screen controls.
##
## The bar sits at the bottom of the screen and holds the actions a
## phone player needs: the inventory, the battle speed, the unit
## purchase and the game-over restart. Each button is visible only in
## the phase where its action is legal, so a hidden action has no
## touch target at all.
func _build_touch_bar() -> void:
	if _touch_bar != null:
		return
	_touch_bar = HBoxContainer.new()
	_touch_bar.name = "TouchBar"
	_touch_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	# The offsets are physical lengths: the bar is 64 CSS px tall on
	# every screen.
	_touch_bar.offset_top = -_px(64.0)
	_touch_bar.offset_bottom = -_px(8.0)
	_touch_bar.offset_left = _px(8.0)
	_touch_bar.offset_right = -_px(8.0)
	# The bar is the TOPMOST layer: the inventory must be closable by
	# tapping the Inventory button again, even while the inventory's
	# panel is on the screen.
	_touch_bar.z_index = 100
	_touch_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	_touch_bar.add_theme_constant_override("separation", _px_i(12))
	_touch_bar.mouse_filter = Control.MOUSE_FILTER_PASS
	_ui_root.add_child(_touch_bar)
	_inventory_button = _make_touch_button("Inventory", _on_inventory_button_pressed)
	_speed_button = _make_touch_button("Speed", _on_speed_button_pressed)
	_buy_button = _make_touch_button("Buy", _on_buy_button_pressed)
	_restart_button = _make_touch_button("Restart", _on_restart_button_pressed)
	_touch_bar.add_child(_inventory_button)
	_touch_bar.add_child(_speed_button)
	_touch_bar.add_child(_buy_button)
	_touch_bar.add_child(_restart_button)


func _make_touch_button(text: String, callback: Callable) -> Button:
	var btn: Button = Button.new()
	btn.name = text + "Button"
	btn.text = text
	btn.custom_minimum_size = _touch_size(Vector2(110, 48))
	btn.add_theme_font_size_override("font_size", _font_px(16))
	btn.add_theme_stylebox_override("normal", _make_touch_style(Color(0.24, 0.32, 0.48)))
	btn.add_theme_stylebox_override("hover", _make_touch_style(Color(0.30, 0.40, 0.58)))
	btn.add_theme_stylebox_override("pressed", _make_touch_style(Color(0.18, 0.24, 0.38)))
	btn.pressed.connect(callback)
	_apply_font(btn)
	return btn


func _make_touch_style(bg: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = Color(0.6, 0.7, 0.9, 0.7)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = _px(10)
	sb.content_margin_right = _px(10)
	return sb


## The touch bar's buttons are shown only where their action is legal.
##
## A hidden button has no touch target, so a tap can never reach an
## action that the current phase forbids.
func _refresh_touch_bar() -> void:
	if _touch_bar == null or run_controller == null:
		return
	var thePhase: int = run_controller.phase
	# A MODAL overlay owns the screen: its own controls are the only
	# actions the player may take. The shop and the reward are modal --
	# the shop has its Leave Shop, the reward has its choices and Skip.
	# The inventory is NOT modal: it is opened on top of the run, so
	# the Inventory button stays available to close it again.
	var theModal: bool = (shop_scene != null and shop_scene.visible) \
			or (reward_modal != null and reward_modal.visible)
	if theModal:
		_inventory_button.visible = false
		_speed_button.visible = false
		_buy_button.visible = false
		_restart_button.visible = false
		return
	_inventory_button.visible = (thePhase != RunController.Phase.GAMEOVER)
	_speed_button.visible = (thePhase == RunController.Phase.BATTLE
			or thePhase == RunController.Phase.PREP)
	_buy_button.visible = (thePhase == RunController.Phase.PREP)
	_restart_button.visible = (thePhase == RunController.Phase.GAMEOVER)


## The speed button cycles the persisted speed profile.
##
## The profile's speeds are the source of truth, so the button and the
## `1`/`2`/`4` keys can never disagree.
func _on_speed_button_pressed() -> void:
	var theSpeeds: Array[float] = [1.0, 2.0, 4.0]
	var theIndex: int = 0
	for i in range(theSpeeds.size()):
		if is_equal_approx(theSpeeds[i], speed):
			theIndex = i
			break
	var theNext: float = theSpeeds[(theIndex + 1) % theSpeeds.size()]
	set_battle_speed(theNext)
	_speed_button.text = "Speed x%.0f" % theNext


func _on_inventory_button_pressed() -> void:
	toggle_inventory()


func _on_buy_button_pressed() -> void:
	buy_first_unit()


func _on_restart_button_pressed() -> void:
	restart_run()


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


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				# The same domain operation the on-screen control calls.
				start_battle()
			KEY_1:
				set_battle_speed(1.0)
			KEY_2:
				set_battle_speed(2.0)
			KEY_4:
				set_battle_speed(4.0)
			KEY_B:
				buy_first_unit()
			KEY_R:
				restart_run()
			KEY_I:
				# S7.1: toggle inventory overlay.
				toggle_inventory()
func _on_battle_ended(winner_team: int) -> void:
	# Очищаем ui_overlay (он не должен показывать dead combatants).
	if ui_overlay != null:
		ui_overlay.set_context(null)
	# S4.2: end-of-round summary — показываем 1.5s после боя.
	if winner_team == 0:
		var gold_earned: int = BalanceScript.WIN_BONUS_GOLD + run_controller.state.round_index - 1
		_show_round_summary("Round %d cleared! +%d gold" % [
			run_controller.state.round_index - 1,
			gold_earned
		])
	else:
		_show_round_summary("Defeat!")
	_refresh_hud()


## S4.2: показывает summary Label на 1.5s, затем удаляет.
func _show_round_summary(text: String) -> void:
	# Удалить предыдущий summary если ещё висит.
	if summary_label != null and is_instance_valid(summary_label):
		summary_label.queue_free()
	summary_label = Label.new()
	summary_label.text = text
	summary_label.add_theme_color_override("font_color", Color(1, 0.95, 0.3))
	summary_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	summary_label.position = Vector2(360, 60)
	summary_label.add_theme_font_size_override("font_size", _font_px(24))
	summary_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_root.add_child(summary_label)
	_summary_pending = true
	# Через 1.5s убрать (если ран продолжается).
	await get_tree().create_timer(1.5).timeout
	if is_instance_valid(summary_label):
		summary_label.queue_free()
	summary_label = null
	_summary_pending = false


func _on_unit_died(_c) -> void:
	pass


func _on_round_started(_round: int) -> void:
	_refresh_hud()


# === S5.3: encounter map overlay ===

## Создает encounter_map_scene, лежит поверх battle_view, скрыт initial.
func _build_encounter_map_overlay() -> void:
	encounter_map_scene = ENCOUNTER_MAP_SCENE_SCRIPT.new()
	encounter_map_scene.name = "EncounterMapOverlay"
	encounter_map_scene.set_anchors_preset(Control.PRESET_FULL_RECT)
	encounter_map_scene.visible = false
	encounter_map_scene.mouse_filter = Control.MOUSE_FILTER_STOP
	# S6.1: scene re-emits node_selected → RunController dispatch
	# (внутри scene включён _delegate_selection = true, чтобы она не
	# сама делала choose_next на preview-owned карте).
	if encounter_map_scene.has_signal("node_selected"):
		encounter_map_scene.node_selected.connect(_on_encounter_node_selected)
	add_child(encounter_map_scene)


## S6.1: handle encounter node click from MAP phase.
func _on_encounter_node_selected(node_id: int) -> void:
	if run_controller == null:
		return
	run_controller._on_node_selected(node_id)


# === S6.1: reward modal ===

## Создаёт reward modal поверх battle_view, скрыт initial.
## Показывается при phase=REWARD через _on_reward_offered().
func _build_reward_modal() -> void:
	reward_modal = REWARD_MODAL_SCRIPT.new()
	reward_modal.name = "RewardModal"
	reward_modal.set_anchors_preset(Control.PRESET_FULL_RECT)
	reward_modal.visible = false
	reward_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(reward_modal)


## EventBus.reward_offered → показать модалку с предложенными юнитами.
func _on_reward_offered(unit_ids: Array) -> void:
	if reward_modal == null or run_controller == null:
		return
	reward_modal.show_offer(unit_ids, run_controller)
	reward_modal.visible = true


# === S6.2: PREP scene ===

var prep_scene: Control = null


## Создаёт prep_scene, скрыт initial. Показывается на phase=PREP.
func _build_prep_scene() -> void:
	prep_scene = PREP_SCENE_SCRIPT.new()
	prep_scene.name = "PrepScene"
	prep_scene.set_anchors_preset(Control.PRESET_FULL_RECT)
	prep_scene.visible = false
	prep_scene.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(prep_scene)


# === S7.1: Inventory scene ===

var inventory_scene: Control = null


## Создаёт inventory_scene (overlay, скрыт initial).
## Тогглится по клавише I в _unhandled_input.
func _build_inventory_scene() -> void:
	inventory_scene = INVENTORY_SCENE_SCRIPT.new()
	inventory_scene.name = "InventoryScene"
	inventory_scene.set_anchors_preset(Control.PRESET_FULL_RECT)
	inventory_scene.visible = false
	inventory_scene.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(inventory_scene)
	if run_controller != null:
		inventory_scene.set_run_controller(run_controller)


# === S7.4: Shop scene ===

var shop_scene: Control = null


## Создаёт shop_scene (overlay, скрыт initial). Показывается на phase=PREP
## когда пришли с MERCHANT (state flag-managed).
func _build_shop_scene() -> void:
	shop_scene = SHOP_SCENE_SCRIPT.new()
	shop_scene.name = "ShopScene"
	shop_scene.set_anchors_preset(Control.PRESET_FULL_RECT)
	shop_scene.visible = false
	shop_scene.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shop_scene)
	if run_controller != null:
		shop_scene.set_run_controller(run_controller)


# === Phase switching ===

## S5.3: реакция на phase_changed — show/hide encounter map и reward modal.
func _on_run_phase_changed(new_phase: int) -> void:
	if run_controller == null:
		return
	# Encounter map — только на MAP phase.
	if encounter_map_scene != null:
		if new_phase == RUN_CONTROLLER_SCRIPT.Phase.MAP:
			var map = run_controller.get_encounter_map()
			if map != null:
				encounter_map_scene.set_encounter_map(map)
			encounter_map_scene.visible = true
		else:
			encounter_map_scene.visible = false
	# Reward modal — видна на REWARD phase, скрыта иначе.
	if reward_modal != null:
		if new_phase == RUN_CONTROLLER_SCRIPT.Phase.REWARD:
			# Direct ownership keeps Web UI valid even if EventBus delivery is delayed.
			reward_modal.show_offer(run_controller.reward.offered_ids(), run_controller)
			reward_modal.visible = true
		else:
			reward_modal.visible = false
	# S7.2: PREP scene — also pass inventory_scene для equip wiring.
	if prep_scene != null and inventory_scene != null:
		prep_scene.set_inventory_scene(inventory_scene)
	# S6.2: PREP scene — видна на PREP phase, скрыта иначе.
	if prep_scene != null:
		prep_scene.visible = (new_phase == RUN_CONTROLLER_SCRIPT.Phase.PREP)
		if new_phase == RUN_CONTROLLER_SCRIPT.Phase.PREP and run_controller != null:
			prep_scene.set_run_controller(run_controller)
			if inventory_scene != null:
				prep_scene.set_inventory_scene(inventory_scene)
	# S7.4: Shop scene — видна когда пришли из MERCHANT на phase=PREP.
	# После Close (exit_shop_to_map) флаг сбрасывается, и на следующем
	# phase_changed show пропускается (until another MERCHANT encounter).
	if shop_scene != null:
		var show_shop: bool = (new_phase == RUN_CONTROLLER_SCRIPT.Phase.PREP
			and run_controller != null
			and run_controller.state.just_visited_merchant)
		shop_scene.visible = show_shop
		if show_shop:
			shop_scene.set_run_controller(run_controller)
	_refresh_touch_bar()
	# Обновляем status.
	_refresh_status()
	_refresh_hud()
