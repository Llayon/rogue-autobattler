class_name StatusInstance extends RefCounted
## Phase 3 / StatusInstance — runtime data carrier for one
## active status on a battle entity.
##
## Carries NO Node / scene refs. Mutable (runtime state) but
## shared by reference inside a single StatusContainer only;
## cross-entity sharing is forbidden (verified by tests).

var status_id: StringName = &""
var source_entity: int = -1
var target_entity: int = 0
var stacks: int = 1
var duration: int = -1
## Remaining duration (decremented by tick_status_durations).
## -1 = indefinite (does not tick).
var remaining: int = -1
var magnitude: int = 0
var payload: Dictionary = {}


func _init(
		p_status_id: StringName,
		p_source_entity: int,
		p_target_entity: int,
		p_stacks: int = 1,
		p_duration: int = -1,
		p_magnitude: int = 0) -> void:
	status_id = p_status_id
	source_entity = int(p_source_entity)
	target_entity = int(p_target_entity)
	stacks = int(p_stacks)
	duration = int(p_duration)
	remaining = int(p_duration)
	magnitude = int(p_magnitude)


## Tick duration down by `delta`. Returns true if the status
## is now expired (remaining <= 0).
func tick(delta: int) -> bool:
	if int(remaining) < 0:
		return false  # indefinite
	remaining = maxi(0, int(remaining) - int(delta))
	return int(remaining) == 0
