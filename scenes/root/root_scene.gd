extends Node
## Корневой scene — содержит MainMenu + BattleScene как sub-views.
## Переключает visibility между ними без queue_free.
##
## Это решает Sprint 3 race condition где MainMenu._start_battle_scene
## queue_free'ил root children и add_child'ил BattleScene, ломая reward modal
## в Web build (event connections с старыми instances).

const MainMenuScript = preload("res://scenes/main_menu/main_menu.gd")

var _main_menu: Control = null
var _battle_scene: Control = null
var _current_view: String = "main_menu"


func _ready() -> void:
    _build_main_menu()
    _build_battle_scene()
    show_main_menu()


func _build_main_menu() -> void:
    _main_menu = MainMenuScript.new()
    _main_menu.name = "MainMenu"
    add_child(_main_menu)


func _build_battle_scene() -> void:
    var packed: PackedScene = load("res://scenes/battle/battle_scene.tscn") as PackedScene
    if packed == null:
        push_error("RootScene: failed to load battle_scene.tscn")
        return
    _battle_scene = packed.instantiate()
    _battle_scene.name = "BattleScene"
    add_child(_battle_scene)
    _battle_scene.visible = false


func show_main_menu() -> void:
    _current_view = "main_menu"
    if _main_menu != null:
        _main_menu.visible = true
    if _battle_scene != null:
        _battle_scene.visible = false


func show_battle_scene(seed: int) -> void:
    _current_view = "battle"
    if _main_menu != null:
        _main_menu.visible = false
    if _battle_scene != null:
        # Передаём seed через metadata НЕ на packed (shared), а на самом instance.
        _battle_scene.set_meta("initial_seed", seed)
        _battle_scene.visible = true
        # Trigger BattleScene's _ready manually если ещё не вызван?
        # Actually _ready уже runs на add_child. Переинициализируем run:
        if _battle_scene.has_method("restart_with_seed"):
            _battle_scene.restart_with_seed(seed)
        elif _battle_scene.has_method("_on_battle_start"):
            # Manual trigger - BattleScene's _ready уже отработал один раз.
            # Чтобы пере-инициализировать run, нужно recreate battle_scene.
            push_warning("RootScene: battle_scene has no restart method, recreating")
            _recreate_battle_scene(seed)


func show_main_menu_after_battle() -> void:
    # Game over / user pressed R - возврат в MainMenu.
    if _battle_scene != null:
        _battle_scene.visible = false
    if _main_menu != null:
        _main_menu.visible = true
        if _main_menu.has_method("refresh"):
            _main_menu.refresh()
    _current_view = "main_menu"


func _recreate_battle_scene(seed: int) -> void:
    # Fallback: если battle_scene не имеет restart method, recreate.
    if _battle_scene != null:
        _battle_scene.queue_free()
    var packed: PackedScene = load("res://scenes/battle/battle_scene.tscn") as PackedScene
    _battle_scene = packed.instantiate()
    _battle_scene.name = "BattleScene"
    add_child(_battle_scene)
    _battle_scene.set_meta("initial_seed", seed)
    _battle_scene.visible = true
    _current_view = "battle"


func get_current_view() -> String:
    return _current_view


func get_battle_scene() -> Control:
    return _battle_scene


func get_main_menu() -> Control:
    return _main_menu
