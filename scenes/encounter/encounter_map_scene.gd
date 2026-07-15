extends Control
## Standalone preview/controller for the S5.2 Encounter Map UI.
##
## Generates a deterministic map when opened directly. S5.3 will replace this
## local ownership with RunController integration while keeping the view API.

const EncounterMapScript = preload("res://core/encounter/encounter_map.gd")
const EncounterMapViewScript = preload("res://scenes/encounter/encounter_map_view.gd")

@export var preview_seed: int = 5202

var encounter_map = null
var map_view: Control = null
var status_label: Label = null


func _ready() -> void:
	_setup_background()
	_setup_map_view()
	_setup_status_label()
	if encounter_map == null:
		Rng.seed_run(preview_seed)
		encounter_map = EncounterMapScript.new()
		encounter_map.generate(preview_seed)
	map_view.set_map(encounter_map)
	_update_status("Choose your first encounter")


## Receives a validated view selection and advances the preview model.
func _on_node_selected(node_id: int) -> void:
	if encounter_map == null or not encounter_map.choose_next(node_id):
		return
	var node = encounter_map.get_current_node()
	if node == null:
		return
	_update_status("Layer %d · %s" % [node.depth, node.get_display_name()])
	map_view.set_map(encounter_map)


## Allows S5.3 to provide a real run-owned EncounterMap before _ready.
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
	add_child(map_view)


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
	status_label.add_theme_font_size_override("font_size", 15)
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color("b0202937")
	panel.set_corner_radius_all(10)
	status_label.add_theme_stylebox_override("normal", panel)
	add_child(status_label)


## Adds a dark background behind the full-rect view for transparent margins.
func _setup_background() -> void:
	var background := ColorRect.new()
	background.name = "Background"
	background.color = Color("0b0f18")
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)


## Updates user-facing selection feedback.
func _update_status(message: String) -> void:
	if is_instance_valid(status_label):
		status_label.text = message
