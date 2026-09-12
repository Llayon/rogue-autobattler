class_name StatQuery extends RefCounted
## Phase 3 / StatQuery — pure stat aggregation.
##
## effective_stat(entity) = base_stat(entity) + sum of magnitudes
## of all status modifiers on entity (filtered by status_id
## semantics).
##
## Phase 3 minimum: effective_attack().
##
## Does NOT mutate stored base stats. Removing a status modifier
## naturally restores the base value (verified by tests).

const StatusContainerScript = preload("res://core/battle_ecs/status/status_container.gd")

var _world = null


func _init(p_world) -> void:
	_world = p_world


## Returns effective attack for entity_id.
## = world.attack_of(id) + sum of magnitude across all statuses
##   on the entity whose status_id starts with "attack_".
##
## Phase 3 minimum policy: any status with id matching
## &"attack_up" or &"attack_down" contributes its magnitude
## (negative for down). Future expansion: explicit "modifies
## attack" flag on the status definition.
func effective_attack(entity_id: int) -> int:
	var base: int = int(_world.attack_of(entity_id))
	var container = _world.get_status_container(entity_id)
	if container == null:
		return base
	var statuses: Array = container.all_for(entity_id)
	for inst in statuses:
		var sid: StringName = inst.status_id
		if sid == &"attack_up" or sid == &"attack_up_stack":
			base += int(inst.magnitude) * int(inst.stacks)
		elif sid == &"attack_down":
			base -= int(inst.magnitude) * int(inst.stacks)
	return base


## Returns effective defense (mirror of effective_attack).
func effective_defense(entity_id: int) -> int:
	var base: int = int(_world.defense_of(entity_id))
	var container = _world.get_status_container(entity_id)
	if container == null:
		return base
	var statuses: Array = container.all_for(entity_id)
	for inst in statuses:
		var sid: StringName = inst.status_id
		if sid == &"defense_up":
			base += int(inst.magnitude) * int(inst.stacks)
		elif sid == &"defense_down":
			base -= int(inst.magnitude) * int(inst.stacks)
	return base


## True iff the entity is currently stunned (has &"stun" status
## with remaining > 0 or indefinite).
func is_stunned(entity_id: int) -> bool:
	var container = _world.get_status_container(entity_id)
	if container == null:
		return false
	var inst = container.get_status(entity_id, &"stun")
	if inst == null:
		return false
	# Indefinite remaining (-1) OR remaining > 0.
	return int(inst.remaining) != 0
