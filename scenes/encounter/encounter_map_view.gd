extends Control
## Presentation-only view for an EncounterMap DAG (S5.2).
##
## The view never mutates progression state. It stores the assigned map and
## emits node_selected for an owning controller to validate and apply.

signal node_selected(node_id: int)

var _map = null


## Assigns the EncounterMap model displayed by this view.
func set_map(map) -> void:
	_map = map
	queue_redraw()


## Returns the currently assigned EncounterMap model, or null.
func get_map():
	return _map
