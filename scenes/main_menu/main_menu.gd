extends Control
## Главное меню: stats panel + start/continue buttons.
##
## Загружает MetaProfile через SaveService на _ready.
##
## "New Run" emits a RunLaunchRequest in the NEW_RUN mode; "Continue"
## emits one in the CONTINUE mode. The intent travels with the
## request, so the router can never mistake a Continue for a new
## run. The seed alone is NOT the intent: a Continue also carries the
## persisted run seed.

const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const SaveService = preload("res://core/save/save_service.gd")
const RngScript = preload("res://core/utils/rng_service.gd")
const RunLaunchRequestScript = preload("res://core/progression/run_launch_request.gd")

## The launch request carries the explicit intent (NEW_RUN /
## CONTINUE) and the seed.
signal run_requested(request: RunLaunchRequestScript)

var _profile: MetaProfileScript = null
var _new_run_button: Button = null
var _continue_button: Button = null
var _stats_label: Label = null
var _title_label: Label = null
var _settings_button: Button = null
var _settings_panel: PanelContainer = null
var _speed_1_button: Button = null
var _speed_2_button: Button = null
var _speed_4_button: Button = null
## R-04: the repository seam for the checkpoint discovery. The menu
## uses the SAME seam as the save and the load, so an injected
## repository sees its own runs and the production runs are not
## touched.
var _save_repository: Object = null
## The persistence seam for the settings. A test injects a writer and
## a reader that point at a temporary directory, so the suites never
## write into the production `user://saves/meta.tres` and never touch
## the developer's own profile. This is the SAME seam shape the
## RunController uses for its meta publication.
var _meta_writer: Object = null
var _meta_reader: Object = null
## R-04: the seed the Continue button would restore, and whether the
## choice needs the player.
var _continue_seed_value: int = 0
var _continue_needs_a_choice: bool = false


func _ready() -> void:
    _profile = _load_meta()
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
    # The settings are reachable from the main screen. The button was
    # declared but never CREATED, so the panel could not be opened at
    # all: the whole settings feature was dead code.
    _settings_button = _make_button("Settings", _on_settings_pressed, Color(0.28, 0.28, 0.42))
    vbox.add_child(_settings_button)
    # The panel lives INSIDE the vbox, so it is laid out with the menu
    # and can never cover the New Run and Continue buttons.
    _build_settings_panel(vbox)
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
    _refresh_continue_target()
    if _continue_button != null:
        _continue_button.visible = (_continue_seed_value != 0)


func _on_new_run_pressed() -> void:
    var rng_seed: int = RngScript.randi_range(1, 999999)
    _start_battle_scene(RunLaunchRequestScript.new_run(rng_seed))


func _on_continue_pressed() -> void:
    # R-04: the seed is resolved by `_refresh_continue_target()`, which
    # also knows whether the choice needs the player. The ambiguity of
    # SEVERAL checkpoints is NOT resolved silently.
    if _continue_seed_value == 0:
        return
    if _continue_needs_a_choice:
        # The player has to pick: there is more than one committed
        # checkpoint and the pointer is stale. Continuing with an
        # arbitrary one could restore the WRONG run.
        GameLog.warn("ui", "the continue target is ambiguous: a choice is needed",
            {"candidates": _continue_candidates().size()})
        return
    _start_battle_scene(RunLaunchRequestScript.continue_run(_continue_seed_value))


## Resolves the seed the Continue button would restore.
##
## R-04: the fresh pointer wins. When the pointer is stale, the
## committed checkpoints are discovered through the SAME seam as the
## save and the load:
##
##   exactly ONE candidate -> that one is offered
##   SEVERAL candidates    -> the ambiguity is reported, and no seed
##                            is offered silently
func _refresh_continue_target() -> void:
    _continue_seed_value = 0
    _continue_needs_a_choice = false
    if _profile == null:
        return
    if _profile.current_run_seed != 0:
        _continue_seed_value = _profile.current_run_seed
        return
    var candidates: Array[int] = _continue_candidates()
    if candidates.size() == 1:
        # The pointer is stale, but there is exactly ONE committed
        # checkpoint: the run is still recoverable.
        _continue_seed_value = candidates[0]
    elif candidates.size() > 1:
        # Several candidates: the player must choose. The menu does
        # NOT pick one silently.
        _continue_needs_a_choice = true


## The committed checkpoints that could be continued.
func _continue_candidates() -> Array[int]:
    var seeds: Array[int] = []
    if _save_repository != null and _save_repository.has_method("list_saved_seeds"):
        var listed: Variant = _save_repository.list_saved_seeds()
        if listed is Array:
            for s in listed:
                seeds.append(int(s))
        return seeds
    var listed_service: Variant = SaveService.list_runs()
    if listed_service is Array:
        for s in listed_service:
            seeds.append(int(s))
    return seeds


## The seed the Continue button would restore, or 0.
func continue_seed() -> int:
    return _continue_seed_value


## Whether the Continue button needs the player to pick a run.
func continue_needs_choice() -> bool:
    return _continue_needs_a_choice


## Whether the ambiguity is resolved silently. It never is.
func continue_is_silent() -> bool:
    return false


## The test seam: the profile the menu reads.
func set_profile_for_test(profile: Object) -> void:
    _profile = profile


## The test seam: the repository the menu discovers the checkpoints in.
func set_save_repository_for_test(repository: Object) -> void:
    _save_repository = repository


## The test seam: the persistence the settings use. A test injects a
## writer and a reader that point at a temporary directory, so the
## suite never writes the production `user://saves/meta.tres`.
func set_meta_persistence_for_test(writer: Object, reader: Object) -> void:
    _meta_writer = writer
    _meta_reader = reader


func _on_settings_pressed() -> void:
    _toggle_settings_panel()


func _toggle_settings_panel() -> void:
    if _settings_panel == null:
        # Only if it was never built. Repeated presses must NOT create
        # a second panel: the panel is built once, in the layout.
        _build_settings_panel(_settings_parent())
    _settings_panel.visible = not _settings_panel.visible
    if _settings_panel.visible:
        _refresh_speed_buttons()


## The node the settings panel belongs to. The panel is created inside
## the menu's vbox, so it is found through the button's own parent.
func _settings_parent() -> Node:
    if _settings_button != null and _settings_button.get_parent() != null:
        return _settings_button.get_parent()
    return self


func _build_settings_panel(parent: Node) -> void:
    # The panel is a CHILD of the menu's vbox, not of the root
    # Control. Positioned against the root it could cover the New Run
    # and Continue buttons; inside the vbox it is laid out with the
    # menu and pushes the layout instead of overlapping it.
    if _settings_panel != null:
        return
    _settings_panel = PanelContainer.new()
    _settings_panel.visible = false
    var sb: StyleBoxFlat = StyleBoxFlat.new()
    sb.bg_color = Color(0.10, 0.14, 0.22, 0.96)
    sb.border_color = Color(0.55, 0.65, 0.85, 0.9)
    sb.set_border_width_all(2)
    sb.set_corner_radius_all(12)
    _settings_panel.add_theme_stylebox_override("panel", sb)
    var vbox: VBoxContainer = VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 12)
    _settings_panel.add_child(vbox)
    var title: Label = Label.new()
    title.text = "Battle Speed"
    title.add_theme_font_size_override("font_size", 20)
    title.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    vbox.add_child(title)
    var hbox: HBoxContainer = HBoxContainer.new()
    hbox.add_theme_constant_override("separation", 8)
    hbox.alignment = BoxContainer.ALIGNMENT_CENTER
    _speed_1_button = _make_small_button("1x", _on_speed_1_pressed)
    _speed_2_button = _make_small_button("2x", _on_speed_2_pressed)
    _speed_4_button = _make_small_button("4x", _on_speed_4_pressed)
    hbox.add_child(_speed_1_button)
    hbox.add_child(_speed_2_button)
    hbox.add_child(_speed_4_button)
    vbox.add_child(hbox)
    # The parent is REQUIRED. Adding the panel to the root Control
    # would re-introduce the overlay this hotfix removed: it would
    # cover the New Run and Continue buttons. The independent critic
    # found the old fallback branch as a foot-gun for the next
    # caller, so it is gone rather than left as a trap.
    assert(parent != null, "the settings panel needs the menu's vbox")
    parent.add_child(_settings_panel)


func _make_small_button(text: String, callback: Callable) -> Button:
    var btn: Button = Button.new()
    btn.text = text
    btn.custom_minimum_size = Vector2(60, 40)
    btn.add_theme_font_size_override("font_size", 16)
    btn.pressed.connect(callback)
    return btn


func _on_speed_1_pressed() -> void:
    _set_speed(1.0)


func _on_speed_2_pressed() -> void:
    _set_speed(2.0)


func _on_speed_4_pressed() -> void:
    _set_speed(4.0)


func _set_speed(s: float) -> void:
    if _profile == null:
        return
    var previous: float = _profile.battle_speed
    _profile.battle_speed = s
    if not _save_meta(_profile):
        # The write FAILED. The profile keeps the value it had, so the
        # menu never shows a speed that is not on the disk -- and the
        # buttons show the speed that is actually persisted.
        _profile.battle_speed = previous
        GameLog.warn("ui", "the battle speed could not be saved", {"speed": s})
        _refresh_speed_buttons()
        return
    _refresh_speed_buttons()


## Writes the profile through the injected seam when there is one.
## Returns whether the profile IS on the disk afterwards.
func _save_meta(profile: MetaProfileScript) -> bool:
    if _meta_writer != null and _meta_writer.has_method("write_meta"):
        return bool(_meta_writer.write_meta(profile))
    return SaveService.save_meta(profile)


## Reads the profile through the injected seam when there is one.
func _load_meta() -> MetaProfileScript:
    if _meta_reader != null and _meta_reader.has_method("read_meta"):
        var loaded: Variant = _meta_reader.read_meta()
        if loaded is MetaProfileScript:
            return loaded
        return MetaProfileScript.new()
    return SaveService.load_meta()


func _refresh_speed_buttons() -> void:
    if _profile == null:
        return
    var current: float = _profile.battle_speed
    for btn in [_speed_1_button, _speed_2_button, _speed_4_button]:
        if btn == null:
            continue
        var is_current: bool = (
            (btn == _speed_1_button and current == 1.0)
            or (btn == _speed_2_button and current == 2.0)
            or (btn == _speed_4_button and current == 4.0)
        )
        var sb: StyleBoxFlat = StyleBoxFlat.new()
        sb.bg_color = Color(0.40, 0.55, 0.40) if is_current else Color(0.30, 0.30, 0.40)
        sb.set_corner_radius_all(6)
        btn.add_theme_stylebox_override("normal", sb)


func _start_battle_scene(request: RunLaunchRequestScript) -> void:
    run_requested.emit(request)
