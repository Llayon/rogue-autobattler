extends Control
## Standalone preview/controller for the S5.2 Encounter Map UI.
##
## Generates a deterministic map when opened directly. S5.3+ replaces this
## local ownership with RunController integration while keeping the view API.

signal node_selected(node_id: int)

const EncounterMapScript = preload("res://core/encounter/encounter_map.gd")
const EncounterMapViewScript = preload("res://scenes/encounter/encounter_map_view.gd")
const ResponsiveUILayoutScript = preload("res://core/ui/responsive_ui_layout.gd")


@export var preview_seed: int = 5202

var encounter_map = null
var map_view: Control = null
var status_label: Label = null
# S6.1: When true, scene delegates node selection to outer handler
# (RunController) instead of advancing the model itself.
var _delegate_selection: bool = true
## The responsive layout: the map's nodes keep their physical size on a
## phone.
var _layout: ResponsiveUILayoutScript = null
## The root of the compensated UI.
var _ui_root: Control = null


## The layout, for the map view and the status label.


func get_responsive_layout() -> ResponsiveUILayoutScript:
	return _layout


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

func _ready() -> void:
	_layout = ResponsiveUILayoutScript.from_window(_window_size())
	_build_ui_root()
	_setup_background()
	_setup_map_view()
	_setup_status_label()
	if encounter_map == null:
		# The preview map is a VIEW concern: it must not consume or
		# reset the run's random stream. The run stream carries the
		# persisted RNG continuation, and a preview that reseeded it
		# would break the resume contract.
		#
		# The map generator draws from the global stream, so the stream
		# is saved around the preview and restored afterwards.
		var saved_stream: Dictionary = Rng.snapshot()
		Rng.seed_run(preview_seed)
		encounter_map = EncounterMapScript.new()
		encounter_map.generate(preview_seed)
		var saved_seed: int = int(saved_stream.get("seed", 0))
		if saved_seed != 0:
			# The bookkeeping only: current_seed and _is_seeded.
			Rng.seed_run(saved_seed)
		# The machine state is ALWAYS restored: `restore` writes the
		# captured PRNG position, and it is exact for every seed,
		# including 0.
		Rng.restore(saved_stream)
	map_view.set_map(encounter_map)
	_update_status("Choose your first encounter")


## Receives a validated view selection.
## When delegate mode is on (default for S6.1+), re-emits node_selected
## signal for outer RunController to handle. When off (legacy preview
## mode), advances the local model and updates status.
func _on_node_selected(node_id: int) -> void:
	if _delegate_selection:
		# Re-emit signal so BattleScene / RunController can dispatch.
		node_selected.emit(node_id)
		return
	# Legacy preview mode.
	if encounter_map == null or not encounter_map.choose_next(node_id):
		return
	var node = encounter_map.get_current_node()
	if node == null:
		return
	_update_status("Layer %d · %s" % [node.depth, node.get_display_name()])
	map_view.set_map(encounter_map)


## Allows S5.3+ to provide a real run-owned EncounterMap before _ready.
func set_encounter_map(map) -> void:
	encounter_map = map
	if is_instance_valid(map_view):
		map_view.set_map(encounter_map)


## Creates the full-rect presentation view.
func _setup_map_view() -> void:
	map_view = EncounterMapViewScript.new()
	map_view.name = "EncounterMapView"
	map_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_view.node_selected.connect(_on_node_selected)
	_ui_root.add_child(map_view)


## Creates a bottom status pill above the map view.
func _setup_status_label() -> void:
	status_label = Label.new()
	status_label.name = "StatusLabel"
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	status_label.position = Vector2(-180.0, -44.0)
	status_label.size = Vector2(360.0, 32.0)
	status_label.add_theme_color_override("font_color", Color("d8e2f0"))
	status_label.add_theme_font_size_override("font_size", _font_px(15))
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color("b0202937")
	panel.set_corner_radius_all(10)
	status_label.add_theme_stylebox_override("normal", panel)
	_ui_root.add_child(status_label)


## Adds a dark background behind the full-rect view for transparent margins.
func _setup_background() -> void:
	var background := ColorRect.new()
	background.name = "Background"
	background.color = Color("0b0f18")
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_root.add_child(background)


## Updates user-facing selection feedback.
func _update_status(message: String) -> void:
	if is_instance_valid(status_label):
		status_label.text = message
