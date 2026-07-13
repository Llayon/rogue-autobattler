extends Control
## Контроллер боевой сцены. Тикает RunController каждый кадр,
## подписан на сигналы EventBus для обновления HUD.

const RUN_CONTROLLER_SCRIPT: GDScript = preload("res://core/progression/run_controller.gd")
const BATTLE_VIEW_SCRIPT: GDScript = preload("res://scenes/battle/battle_view.gd")

var run_controller: Node
var battle_view: Control
var status_label: Label
var speed: float = 1.0
var _bus: Node = null  # EventBus instance (autoload) или локальный


func _ready() -> void:
	# UI.
	battle_view = BATTLE_VIEW_SCRIPT.new()
	battle_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	battle_view.custom_minimum_size = Vector2(900, 400)
	add_child(battle_view)
	status_label = Label.new()
	status_label.position = Vector2(16, 8)
	status_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(status_label)
	# RunController.
	run_controller = RUN_CONTROLLER_SCRIPT.new()
	run_controller.name = "RunController"
	add_child(run_controller)
	# EventBus.
	_bus = _find_event_bus()
	if _bus != null:
		_bus.battle_ended.connect(_on_battle_ended)
		_bus.unit_died.connect(_on_unit_died)
		_bus.round_started.connect(_on_round_started)
	# Начинаем ран.
	run_controller.start_run(42)


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
	# Перерисовываем каждый кадр во время боя (юниты двигаются/получают урон).
	if run_controller.phase == RunController.Phase.BATTLE:
		run_controller.tick_battle(delta * speed)
		battle_view.queue_redraw()
	_update_status()


func _update_status() -> void:
	var txt: String = ""
	match run_controller.phase:
		RunController.Phase.PREP:
			txt = "PREP  Round %d  Gold %d  Press SPACE to start" % [run_controller.state.round_index, run_controller.state.gold]
		RunController.Phase.BATTLE:
			var t: float = 0.0
			if run_controller.runner != null:
				t = run_controller.runner.state.battle_time
			txt = "BATTLE  t=%.1fs  speed=x%.1f  (1/2/4)" % [t, speed]
		RunController.Phase.REWARD:
			txt = "REWARD"
		RunController.Phase.GAMEOVER:
			txt = "GAME OVER — round %d  (R to restart)" % run_controller.state.round_index
	status_label.text = txt


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
					run_controller.start_run(randi())


func _on_battle_ended(_winner: int) -> void:
	pass


func _on_unit_died(_c) -> void:
	pass


func _on_round_started(_round: int) -> void:
	pass