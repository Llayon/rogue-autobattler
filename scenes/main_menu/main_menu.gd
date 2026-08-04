extends Control
## Главное меню: stats panel + start/continue buttons.
##
## Загружает MetaProfile через SaveService на _ready.
## При нажатии "New Run" вызывает run_controller.start_run с новым seed.
## При нажатии "Continue" вызывает run_controller.resume_run с сохранённым seed.

const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const SaveSvc = preload("res://core/utils/save_manager.gd")
const RngScript = preload("res://core/utils/rng_service.gd")
const BattleSceneScript = preload("res://scenes/battle/battle_scene.gd")

var _profile: MetaProfileScript = null
var _new_run_button: Button = null
var _continue_button: Button = null
var _stats_label: Label = null
var _title_label: Label = null


func _ready() -> void:
    _profile = SaveSvc.load_meta()
    if _profile == null:
        _profile = MetaProfileScript.new()
    _build_layout()
    _refresh()


func _build_layout() -> void:
    var bg: ColorRect = ColorRect.new()
    bg.color = Color(0.04, 0.06, 0.12, 1.0)
    bg.set_anchors_preset(Control.PRESET_FULL_RECT)
    bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(bg)
    var center: CenterContainer = CenterContainer.new()
    center.set_anchors_preset(Control.PRESET_FULL_RECT)
    center.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(center)
    var vbox: VBoxContainer = _build_vbox()
    center.add_child(vbox)


func _build_vbox() -> VBoxContainer:
    var vbox: VBoxContainer = VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 18)
    vbox.alignment = BoxContainer.ALIGNMENT_CENTER
    _title_label = Label.new()
    _title_label.text = "ROGUE AUTOBATTLER"
    _title_label.add_theme_font_size_override("font_size", 36)
    _title_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
    _title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    vbox.add_child(_title_label)
    _stats_label = Label.new()
    _stats_label.add_theme_font_size_override("font_size", 16)
    _stats_label.add_theme_color_override("font_color", Color(0.85, 0.90, 1.0))
    _stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    vbox.add_child(_stats_label)
    var spacer: Control = Control.new()
    spacer.custom_minimum_size = Vector2(0, 20)
    vbox.add_child(spacer)
    _new_run_button = _make_button("New Run", _on_new_run_pressed, Color(0.30, 0.50, 0.30))
    vbox.add_child(_new_run_button)
    _continue_button = _make_button("Continue", _on_continue_pressed, Color(0.20, 0.40, 0.55))
    vbox.add_child(_continue_button)
    return vbox


func _make_button(text: String, callback: Callable, color: Color) -> Button:
    var btn: Button = Button.new()
    btn.text = text
    btn.custom_minimum_size = Vector2(280, 60)
    btn.add_theme_font_size_override("font_size", 22)
    var normal: StyleBoxFlat = StyleBoxFlat.new()
    normal.bg_color = color
    normal.border_color = Color(0.6, 0.6, 0.8, 0.6)
    normal.set_border_width_all(2)
    normal.set_corner_radius_all(8)
    btn.add_theme_stylebox_override("normal", normal)
    var hover: StyleBoxFlat = normal.duplicate()
    hover.bg_color = color.lightened(0.2)
    btn.add_theme_stylebox_override("hover", hover)
    btn.pressed.connect(callback)
    return btn


func _refresh() -> void:
    if _profile == null:
        return
    if _stats_label != null:
        _stats_label.text = "Runs: %d  Wins: %d  Best round: %d  Souls: %d" % [
            _profile.total_runs, _profile.total_wins, _profile.best_round, _profile.soul_currency
        ]
    if _continue_button != null:
        _continue_button.visible = (_profile.current_run_seed != 0)


func _on_new_run_pressed() -> void:
    var rng_seed: int = RngScript.randi_range(1, 999999)
    _start_battle_scene(rng_seed)


func _on_continue_pressed() -> void:
    if _profile == null or _profile.current_run_seed == 0:
        return
    _start_battle_scene(_profile.current_run_seed)


func _start_battle_scene(seed: int) -> void:
    var tree: SceneTree = Engine.get_main_loop() as SceneTree
    if tree == null:
        return
    var packed: PackedScene = load("res://scenes/battle/battle_scene.tscn") as PackedScene
    if packed == null:
        push_error("Failed to load battle_scene.tscn")
        return
    packed.set_meta("initial_seed", seed)
    var inst: Node = packed.instantiate()
    var root: Node = tree.root
    # Удаляем все дети root кроме autoload (autoloads имеют имя начинающееся с "@").
    for child in root.get_children():
        if not child.name.begins_with("@"):
            child.queue_free()
    root.add_child(inst)