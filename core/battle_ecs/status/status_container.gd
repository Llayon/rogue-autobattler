class_name StatusContainer extends RefCounted
## Phase 3 / StatusContainer — owns runtime StatusInstance values
## for EXACTLY ONE BattleWorld entity.
##
## Architectural contract (B0.1):
##   - One StatusContainer = one owner entity.
##   - Constructed via StatusContainer.new(owner_entity_id).
##   - Internal storage is a plain Array (insertion order).
##   - All add() / get / remove operations are OWNER-SCOPED.
##     StatusInstance.target_entity MUST equal owner_entity_id.
##   - Mismatched target_entity is REJECTED.
##
## Iteration order is deterministic (insertion order). No
## Dictionary iteration is used for trigger semantics — the
## `all()` method returns statuses in insertion order.
##
## Stacking policy (B0.1):
##   - Resolved through a StatusDefResolver at apply time.
##   - If StatusDef.stackable == false: reapply refreshes duration;
##     stacks remain at 1.
##   - If StatusDef.stackable == true: reapply increments stacks
##     up to StatusDef.max_stacks; duration refreshed.

var _owner_entity_id: int = -1
var _statuses: Array = []  # Array[StatusInstance]


## Construct a container that OWNS one BattleWorld entity. Once
## constructed, every add/get/remove operation is scoped to
## owner_entity_id.
func _init(p_owner_entity_id: int = -1) -> void:
	_owner_entity_id = int(p_owner_entity_id)


## Returns the owning BattleWorld entity id.
func owner_entity_id() -> int:
	return int(_owner_entity_id)


## True iff `entity_id` equals the owner.
func owns(entity_id: int) -> bool:
	return int(_owner_entity_id) == int(entity_id)


## Add a status to this container. The status's target_entity
## MUST equal owner_entity_id; otherwise the add is REJECTED
## (returns null, no mutation).
##
## Stacking is decided by `stacking_policy`. Pass:
##   - "unique": never stack (reapply refreshes duration, stacks=1)
##   - "stackable": increment stacks up to max_stacks, refresh
##
## Returns the (existing or newly-inserted) StatusInstance, or
## null if rejected.
## B1.1 stack invariant contract (enforced at container boundary):
##   - Stacks are ALWAYS clamped to [1, max_stacks] when max_stacks > 0.
##   - Stacks requested as <= 0 cause rejection (returns null).
##   - This invariant holds for BOTH first insert and reapply.
func add(inst, stacking_policy: String = "stackable", max_stacks: int = 99) -> RefCounted:
	if inst == null:
		return null
	if int(inst.target_entity) != int(_owner_entity_id):
		# Reject: status does not belong to this container.
		return null
	# Reject invalid requested stacks (<= 0).
	if int(inst.stacks) <= 0:
		return null
	# Normalize max_stacks: <= 0 falls back to 99 (legacy safety).
	if max_stacks <= 0:
		max_stacks = 99
	var existing = _find(inst.status_id)
	if existing != null:
		if stacking_policy == "unique":
			# Refresh duration; stacks clamped to [1, max_stacks].
			existing.stacks = clampi(int(inst.stacks), 1, max_stacks)
			if int(inst.remaining) > 0:
				existing.remaining = int(inst.remaining)
			return existing
		# stackable: increment up to max_stacks.
		var new_stacks: int = int(existing.stacks) + int(inst.stacks)
		if new_stacks > max_stacks:
			new_stacks = max_stacks
		if new_stacks < 1:
			new_stacks = 1
		existing.stacks = new_stacks
		if int(inst.remaining) > 0:
			existing.remaining = int(inst.remaining)
		return existing
	# First insert. Clamp requested stacks to [1, max_stacks].
	inst.stacks = clampi(int(inst.stacks), 1, max_stacks)
	_statuses.append(inst)
	return inst


## Remove the status with this status_id from this container.
## Returns true if removed, false if not present.
func remove(status_id: StringName) -> bool:
	for i in _statuses.size():
		if _statuses[i].status_id == status_id:
			_statuses.remove_at(i)
			return true
	return false


## Remove the status with this status_id AND return the
## removed instance (used by expiry sweeps to inspect identity).
## Returns null if not present.
func take(status_id: StringName) -> RefCounted:
	for i in _statuses.size():
		if _statuses[i].status_id == status_id:
			var inst = _statuses[i]
			_statuses.remove_at(i)
			return inst
	return null


## True iff this container has a status with this status_id.
func has_status(status_id: StringName) -> bool:
	return _find(status_id) != null


## Returns the StatusInstance for this status_id, or null.
func get_status(status_id: StringName) -> RefCounted:
	return _find(status_id)


## Returns status_ids for this container in insertion order.
func status_ids() -> Array:
	var out: Array = []
	for inst in _statuses:
		out.append(inst.status_id)
	return out


## Returns all StatusInstances in insertion order.
## Callers MUST NOT mutate the returned array or the instances.
func all() -> Array:
	var out: Array = []
	for inst in _statuses:
		out.append(inst)
	return out


## Number of distinct statuses on this container.
func size() -> int:
	return _statuses.size()


## Tick all durations on this container by `delta`. Returns the
## list of expired StatusInstances (in expiry order).
## Each returned entry preserves StringName status_id (no
## int-cast corruption).
func tick(delta: int) -> Array:
	var expired: Array = []
	var i: int = 0
	while i < _statuses.size():
		var inst = _statuses[i]
		if inst.tick(delta):
			_statuses.remove_at(i)
			expired.append(inst)
			# do not advance i
		else:
			i += 1
	return expired


## Remove all statuses. Returns the removed StatusInstances in
## insertion order (StringName status_id preserved).
func clear() -> Array:
	var removed: Array = []
	for inst in _statuses:
		removed.append(inst)
	_statuses.clear()
	return removed


## Internal: linear scan lookup. StatusContainer cardinality
## in Phase 3 is bounded (1-N per entity), so this is acceptable.
func _find(status_id: StringName) -> RefCounted:
	for inst in _statuses:
		if inst.status_id == status_id:
			return inst
	return null
