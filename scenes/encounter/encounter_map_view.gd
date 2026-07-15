extends Control
## Presentation-only view for an EncounterMap DAG (S5.2).
##
## Renders graph edges procedurally and uses real Button children for nodes.
## The view never mutates progression state: it only emits node_selected.

signal node_selected(node_id: int)

const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")

const NODE_SIZE: Vector2 = Vector2(54.0, 46.0)
const SIDE_MARGIN: float = 72.0
const TOP_MARGIN: float = 86.0
const BOTTOM_MARGIN: float = 54.0

@export var background_color: Color = Color("101522")
@export var edge_color: Color = Color("46536b")
@export var locked_color: Color = Color("293142")
@export var available_color: Color = Color("248f73")
@export var visited_color: Color = Color("385a8f")
@export var current_color: Color = Color("d98b32")
@export var boss_color: Color = Color("9d4259")

var _map = null
var _node_positions: Dictionary = {}
var _node_buttons: Dictionary = {}
var _edge_pairs: Array[Vector2i] = []


## Assigns the EncounterMap model displayed by this view.
func set_map(map) -> void:
	_map = map
	_rebuild()


## Returns the currently assigned EncounterMap model, or null.
func get_map():
	return _map


## Returns a copy of node-id to center-position layout data.
func get_node_positions() -> Dictionary:
	return _node_positions.duplicate()


## Returns a copy of node-id to Button lookup data.
func get_node_buttons() -> Dictionary:
	return _node_buttons.duplicate()


## Returns the number of graph edges prepared for rendering.
func get_edge_count() -> int:
	return _edge_pairs.size()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _map != null:
		_rebuild()


## Rebuilds responsive layout, edge data and node buttons from the model.
func _rebuild() -> void:
	_clear_node_buttons()
	_node_positions.clear()
	_edge_pairs.clear()
	if _map == null:
		queue_redraw()
		return
	_layout_nodes()
	_collect_edges()
	_create_node_buttons()
	queue_redraw()


## Removes buttons from the previous layout before rebuilding.
func _clear_node_buttons() -> void:
	for button in _node_buttons.values():
		if is_instance_valid(button):
			if button.get_parent() == self:
				remove_child(button)
			button.queue_free()
	_node_buttons.clear()


## Places depth 1 at the bottom and the boss layer at the top.
func _layout_nodes() -> void:
	var viewport_size: Vector2 = size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		viewport_size = Vector2(1152.0, 648.0)
	var usable_width: float = maxf(NODE_SIZE.x, viewport_size.x - SIDE_MARGIN * 2.0)
	var usable_height: float = maxf(NODE_SIZE.y, viewport_size.y - TOP_MARGIN - BOTTOM_MARGIN)
	var max_depth: int = maxi(1, Balance.MAP_MAX_DEPTH)
	var layer_gap: float = usable_height / float(maxi(1, max_depth - 1))
	for depth in range(1, max_depth + 1):
		var layer: Array = _map.get_layer_nodes(depth)
		if layer.is_empty():
			continue
		var slot_gap: float = usable_width / float(layer.size())
		var y: float = viewport_size.y - BOTTOM_MARGIN - float(depth - 1) * layer_gap
		for index in layer.size():
			var node = layer[index]
			var x: float = SIDE_MARGIN + slot_gap * (float(index) + 0.5)
			_node_positions[node.id] = Vector2(x, y)


## Collects valid parent-to-child edges for procedural drawing.
func _collect_edges() -> void:
	for node in _map.get_all_nodes():
		if not _node_positions.has(node.id):
			continue
		for child_id in node.child_ids:
			if _node_positions.has(child_id):
				_edge_pairs.append(Vector2i(node.id, child_id))


## Creates an accessible Button for every node in the graph.
func _create_node_buttons() -> void:
	var available: Array[int] = _map.get_available_next_ids()
	var current_id: int = _map.get_current_node_id()
	for node in _map.get_all_nodes():
		if not _node_positions.has(node.id):
			continue
		var button := Button.new()
		button.name = "EncounterNode_%d" % node.id
		button.text = EncounterTypeScript.short_label(node.type)
		button.tooltip_text = "%s · Layer %d" % [
			EncounterTypeScript.display_name(node.type),
			node.depth,
		]
		button.custom_minimum_size = NODE_SIZE
		button.size = NODE_SIZE
		button.position = _node_positions[node.id] - NODE_SIZE * 0.5
		button.focus_mode = Control.FOCUS_ALL
		button.disabled = node.id not in available
		button.add_theme_font_size_override("font_size", 18)
		_apply_button_style(button, node, current_id, node.id in available)
		button.pressed.connect(_on_node_pressed.bind(node.id))
		add_child(button)
		_node_buttons[node.id] = button


## Applies semantic colors for locked, available, visited, current and boss nodes.
## `selectable` avoids boolean classification prefixes reserved by the linter.
func _apply_button_style(button: Button, node, current_id: int, selectable: bool) -> void:
	var fill: Color = locked_color
	if node.type == EncounterTypeScript.Kind.BOSS:
		fill = boss_color.darkened(0.30) if not selectable else boss_color
	if node.visited:
		fill = visited_color
	if selectable:
		fill = available_color
	if node.id == current_id:
		fill = current_color
	var normal := StyleBoxFlat.new()
	normal.bg_color = fill
	normal.border_color = fill.lightened(0.28)
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(12)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = fill.lightened(0.16)
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = fill.darkened(0.16)
	var disabled: StyleBoxFlat = normal.duplicate()
	disabled.bg_color = fill.darkened(0.28)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("disabled", disabled)
	button.add_theme_color_override("font_color", Color.WHITE)
	button.add_theme_color_override("font_disabled_color", Color("8791a5"))


## Validates the id against the model before notifying the owning controller.
func _on_node_pressed(node_id: int) -> void:
	if _map == null:
		return
	if node_id not in _map.get_available_next_ids():
		return
	node_selected.emit(node_id)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), background_color)
	for edge in _edge_pairs:
		if not _node_positions.has(edge.x) or not _node_positions.has(edge.y):
			continue
		var from: Vector2 = _node_positions[edge.x]
		var to: Vector2 = _node_positions[edge.y]
		draw_line(from, to, edge_color, 3.0, true)
	var font: Font = ThemeDB.fallback_font
	if font != null:
		draw_string(font, Vector2(32.0, 42.0), "ENCOUNTER MAP",
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 24, Color("e7edf8"))
		draw_string(font, Vector2(32.0, 68.0),
			"Choose one highlighted route · Boss awaits at the summit",
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14, Color("9ba8bd"))
