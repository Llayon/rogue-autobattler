class_name StatusContainer extends RefCounted
## Phase 3 / StatusContainer — owns runtime StatusInstance
## values for one battle entity.
##
## Iteration order is deterministic (insertion order). No
## Dictionary iteration is used for trigger semantics — the
## `status_ids_for(entity)` method returns statuses in insertion
## order.
##
## Stacking policy (Phase 3 minimum):
##   - Adding a status with the same status_id as an existing
##     one INCREMENTS the existing instance's stacks.
##   - This avoids StatusInstance explosion for repeated
##     applies of the same status.

var _by_entity: Dictionary = {}


## Add a status to the entity. If the entity already has a
## status with the same status_id, increment stacks of the
## existing instance and return that. Otherwise insert.
## Returns the (possibly existing) StatusInstance.
##
## Ownership invariant: a StatusContainer logically belongs to
## ONE BattleWorld entity. `inst.target_entity` MUST equal the
## owning entity. If it does not, the status is still stored
## under its target_entity key (forwarded), but production code
## is expected to call set_status_container() once per entity
## and pass StatusInstances whose target_entity matches.
func add(inst) -> RefCounted:
	var tgt: int = int(inst.target_entity)
	if not _by_entity.has(tgt):
		_by_entity[tgt] = []
	var arr: Array = _by_entity[tgt]
	for existing in arr:
		if existing.status_id == inst.status_id:
			existing.stacks = int(existing.stacks) + int(inst.stacks)
			# Refresh duration to the new instance's remaining
			# (Phase 3 minimum: refresh-on-stack policy).
			if int(inst.remaining) > 0:
				existing.remaining = int(inst.remaining)
			return existing
	arr.append(inst)
	return inst


## Remove the status with this status_id from the entity.
## Returns true if removed, false if not present.
func remove(entity_id: int, status_id: StringName) -> bool:
	if not _by_entity.has(entity_id):
		return false
	var arr: Array = _by_entity[entity_id]
	for i in arr.size():
		if arr[i].status_id == status_id:
			arr.remove_at(i)
			if arr.is_empty():
				_by_entity.erase(entity_id)
			return true
	return false


## True iff the entity has a status with this status_id.
func has_status(entity_id: int, status_id: StringName) -> bool:
	if not _by_entity.has(entity_id):
		return false
	for inst in _by_entity[entity_id]:
		if inst.status_id == status_id:
			return true
	return false


## Returns the StatusInstance for this entity + status_id, or null.
func get_status(entity_id: int, status_id: StringName) -> RefCounted:
	if not _by_entity.has(entity_id):
		return null
	for inst in _by_entity[entity_id]:
		if inst.status_id == status_id:
			return inst
	return null


## Returns status_ids for the entity in insertion order.
func status_ids_for(entity_id: int) -> Array:
	if not _by_entity.has(entity_id):
		return []
	var out: Array = []
	for inst in _by_entity[entity_id]:
		out.append(inst.status_id)
	return out


## Returns all StatusInstances for the entity, in insertion order.
## Callers MUST NOT mutate the returned array or the instances.
func all_for(entity_id: int) -> Array:
	if not _by_entity.has(entity_id):
		return []
	# Return a shallow copy so callers cannot mutate storage.
	var out: Array = []
	for inst in _by_entity[entity_id]:
		out.append(inst)
	return out


## Number of distinct statuses on this entity.
func size(entity_id: int) -> int:
	if not _by_entity.has(entity_id):
		return 0
	return (_by_entity[entity_id] as Array).size()


## Tick all durations on all entities by `delta`. Returns the
## list of (entity_id, status_id) tuples that just expired.
func tick_all(delta: int) -> Array:
	var expired: Array = []
	for entity_id in _by_entity.keys():
		var arr: Array = _by_entity[entity_id]
		var i: int = 0
		while i < arr.size():
			var inst = arr[i]
			if inst.tick(delta):
				var sid = inst.status_id
				arr.remove_at(i)
				expired.append([int(entity_id), int(sid)])
				# do not advance i
			else:
				i += 1
	# Clean up empty entity entries.
	for entity_id in _by_entity.keys():
		if (_by_entity[entity_id] as Array).is_empty():
			_by_entity.erase(entity_id)
	return expired


## Remove all statuses for an entity. Returns the removed ids.
func clear(entity_id: int) -> Array:
	if not _by_entity.has(entity_id):
		return []
	var out: Array = []
	for inst in _by_entity[entity_id]:
		out.append(int(inst.status_id))
	_by_entity.erase(entity_id)
	return out
