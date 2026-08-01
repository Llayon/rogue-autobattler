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

# S6.1: явный Unicode SystemFont для всех UI-лейблов (Cyrillic работает).
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
# === S5.3: encounter map overlay on MAP phase ===
var encounter_map_scene: Control = null
# === S6.1: reward modal on REWARD phase ===
var reward_modal: Control = null


func _ready() -> void:
	# S4.2: HUD bar (поверх battle_view).
	_build_hud()
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
	status_label.add_theme_font_size_override("font_size", 16)
	status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_font(status_label)
	add_child(status_label)
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
	# Начинаем ран.
	run_controller.start_run(42)
	_refresh_hud()
	_refresh_status()


# === S4.2: HUD ===

func _build_hud() -> void:
	# S6.1: HUD — HBoxContainer с явной top-anchor (y=0) и width=full.
	# Раньше был PanelContainer + set_anchors_preset(PRESET_TOP_WIDE), но anchors
	# не работают для Container'ов с layout — детей они не выравнивали.
	hud = HBoxContainer.new()
	hud.name = "HUD"
	hud.set_anchors_preset(Control.PRESET_TOP_WIDE)
	hud.position = Vector2(0, 0)
	hud.add_theme_constant_override("separation", 24)
	hud.add_theme_stylebox_override("normal", _make_hud_panel_style())
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud)
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
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb


func _make_hud_label(initial_text: String) -> Label:
	var label: Label = Label.new()
	label.text = initial_text
	label.add_theme_color_override("font_color", Color(0.92, 0.94, 1.0))
	label.add_theme_font_size_override("font_size", 16)
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


func _process(delta: float) -> void:
	if run_controller == null:
		return
	# Обновляем battle_view когда ctx меняется (новый бой).
	if run_controller.ctx != null and battle_view._ctx != run_controller.ctx:
		battle_view.set_context(run_controller.ctx)
	if ui_overlay != null and ui_overlay._ctx != run_controller.ctx:
		ui_overlay.set_context(run_controller.ctx)
	# Перерисовываем каждый кадр во время боя (юниты двигаются/получают урон).
	if run_controller.phase == RunController.Phase.BATTLE:
		run_controller.tick_battle(delta * speed)
		battle_view.queue_redraw()
	_refresh_status()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				if run_controller.phase == RunController.Phase.PREP:
					run_controller.start_battle()
			KEY_1:
				speed = 1.0
			KEY_2:
				speed = 2.0
			KEY_4:
				speed = 4.0
			KEY_B:
				if run_controller.phase == RunController.Phase.PREP:
					run_controller.buy_unit(0)
			KEY_R:
				if run_controller.phase == RunController.Phase.GAMEOVER:
					run_controller.start_run(Rng.randi_range(1, 999999))
			KEY_I:
				# S7.1: toggle inventory overlay.
				if inventory_scene != null:
					inventory_scene.visible = not inventory_scene.visible
					if inventory_scene.visible:
						inventory_scene.set_run_controller(run_controller)
					get_viewport().set_input_as_handled()


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
	summary_label.add_theme_font_size_override("font_size", 24)
	summary_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(summary_label)
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
		reward_modal.visible = (new_phase == RUN_CONTROLLER_SCRIPT.Phase.REWARD)
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
	# Обновляем status.
	_refresh_status()
	_refresh_hud()
