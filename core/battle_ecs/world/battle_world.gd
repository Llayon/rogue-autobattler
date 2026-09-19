class_name BattleWorld extends RefCounted
## Phase 2 / BattleSimulation — minimal numeric battle world.
##
## Owns the canonical mapping between int entity IDs and their
## component data (position, team, stats, health, source
## identity). No bitmasks, no archetypes, no packed ECS — just
## plain Dictionary storage keyed by int entity ID.
##
## Entity ID policy:
##   - EntityId is a plain int.
##   - IDs are allocated strictly monotonically by
##     `allocate_entity_id()`. They never decrement, never reuse.
##   - Removing an entity DOES NOT free its ID for reuse. A
##     removed entity's ID remains "valid" in the sense that
##     `is_alive(id)` returns false, but `alive_ids_by_team()` and
##     similar queries will skip it. This guarantees stable
##     cross-event references for BattleEvent payloads.
##
## Component cleanup:
##   - On remove_entity(id), all component dictionaries drop the
##     id key (component cleanup).
##
## Movement (Phase 2 / BLOCKER 1):
##   - `try_move_toward(entity, target)` moves one Manhattan
##     cell toward the target if the candidate cell is in
##     bounds and unoccupied. Returns the new cell on success
##     or the source cell on failure (caller decides whether to
##     emit a UNIT_MOVED event).
##   - Axis priority: Y first, then X (deterministic tie-break).
##   - The world owns the position mutation; the simulation
##     schedules movement but never teleports.

const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")

var grid_width: int = 7
var grid_height: int = 4

var _next_id: int = 0
var _alive: Dictionary = {}          # int -> bool
var _teams: Dictionary = {}          # int -> int (0/1)
var _positions: Dictionary = {}      # int -> Vector2i
var _max_hp: Dictionary = {}         # int -> int
var _current_hp: Dictionary = {}     # int -> int
var _attack: Dictionary = {}         # int -> int
var _defense: Dictionary = {}        # int -> int
var _attack_range: Dictionary = {}   # int -> int
var _definition_ids: Dictionary = {} # int -> StringName
var _source_run_unit_ids: Dictionary = {}  # int -> String

# Phase 3: per-entity StatusContainer storage.
# int -> StatusContainer (or null if no statuses yet).
var _status_containers: Dictionary = {}

# Internal ordered list per team to guarantee deterministic
# iteration order (NOT depending on Dictionary ordering).
var _player_ids_ordered: Array = []
var _enemy_ids_ordered: Array = []


func _init(p_grid_width: int = 7, p_grid_height: int = 4) -> void:
	grid_width = maxi(1, p_grid_width)
	grid_height = maxi(1, p_grid_height)


## Allocates a new monotonically-increasing entity ID. Caller is
## responsible for populating components before marking it alive.
func allocate_entity_id() -> int:
	var id: int = _next_id
	_next_id += 1
	return id


## Total entities ever allocated (alive + dead). Stable across
## resets? No — call _reset() to reset allocation.
func next_id_value() -> int:
	return _next_id


## Spawn entities from a BattleSetup. Returns the int IDs of
## spawned entities in deterministic order (players then enemies,
## in source-array order).
func spawn_from_setup(setup) -> Array:
	var spawned: Array = []
	for u in setup.player_units:
		var id: int = _spawn_one(u)
		spawned.append(id)
	for u in setup.enemy_units:
		var id: int = _spawn_one(u)
		spawned.append(id)
	return spawned


func _spawn_one(u: BattleUnitSetup) -> int:
	var id: int = allocate_entity_id()
	_teams[id] = int(u.team)
	_positions[id] = Vector2i(int(u.cell.x), int(u.cell.y))
	_max_hp[id] = int(u.max_hp)
	_current_hp[id] = int(u.starting_hp)
	_attack[id] = int(u.attack_base)
	_defense[id] = int(u.defense_base)
	_attack_range[id] = maxi(1, int(u.attack_range))
	_definition_ids[id] = u.definition_id
	_source_run_unit_ids[id] = u.source_run_unit_id
	# starting_hp <= 0 spawns as not-alive so it never attacks
	# and never acquires a target.
	_alive[id] = int(u.starting_hp) > 0
	if int(u.team) == 0:
		_player_ids_ordered.append(id)
	else:
		_enemy_ids_ordered.append(id)
	return id


func is_alive(id: int) -> bool:
	if not _alive.has(id):
		return false
	return bool(_alive[id])


func team_of(id: int) -> int:
	if not _teams.has(id):
		return -1
	return int(_teams[id])


func position_of(id: int) -> Vector2i:
	if not _positions.has(id):
		return Vector2i(-1, -1)
	var p: Vector2i = _positions[id]
	return p


func max_hp_of(id: int) -> int:
	return int(_max_hp.get(id, 0))


func current_hp_of(id: int) -> int:
	return int(_current_hp.get(id, 0))


func attack_of(id: int) -> int:
	return int(_attack.get(id, 0))


func defense_of(id: int) -> int:
	return int(_defense.get(id, 0))


func attack_range_of(id: int) -> int:
	return int(_attack_range.get(id, 1))


func definition_id_of(id: int) -> StringName:
	return _definition_ids.get(id, &"")


func source_run_unit_id_of(id: int) -> String:
	return String(_source_run_unit_ids.get(id, ""))


## Applies damage to entity. Returns the actual amount applied
## (capped at current_hp). Marks entity dead if HP reaches 0.
func apply_damage(id: int, amount: int) -> int:
	if not is_alive(id):
		return 0
	var hp: int = current_hp_of(id)
	var dealt: int = mini(maxi(0, amount), hp)
	_current_hp[id] = hp - dealt
	if _current_hp[id] <= 0:
		_alive[id] = false
	return dealt


## Phase 3: applies heal to entity. Restores HP up to max_hp.
## Returns the actual amount restored (capped at remaining HP).
## Caller MUST validate target is alive BEFORE calling.
func heal(id: int, amount: int) -> int:
	if not is_alive(id):
		return 0
	var hp: int = current_hp_of(id)
	var max_hp: int = max_hp_of(id)
	var room: int = max_hp - hp
	var restored: int = mini(maxi(0, amount), room)
	_current_hp[id] = hp + restored
	return restored


## Phase 3: set the StatusContainer for an entity.
## Container must belong to `entity_id` (ownership assertion).
## Container may be null (clears it). Replaces any existing.
##
## B1.1 strict container owner:
##   - A container assigned to entity X must have
##     owner_entity_id() == X.
##   - Containers with owner == -1 (signaling "unset") are
##     rejected.
##   - Containers missing the owner_entity_id() API entirely
##     are rejected.
##
## On rejection the world keeps its previous container (or null)
## and returns false.
func set_status_container(entity_id: int, container) -> bool:
	if container == null:
		_status_containers.erase(entity_id)
		return true
	# Strict ownership: the container must expose owner_entity_id
	# and it must equal the entity it is being attached to.
	if not container.has_method("owner_entity_id"):
		return false
	var owner: int = int(container.owner_entity_id())
	if owner != int(entity_id):
		# Reject: container owner does not match the target
		# entity. This covers owner == -1 (unset), owner == other,
		# and any other mismatch.
		return false
	_status_containers[entity_id] = container
	return true


## Phase 3: get the StatusContainer for an entity.
## Returns null if no container is set.
func get_status_container(entity_id: int) -> RefCounted:
	if not _status_containers.has(entity_id):
		return null
	return _status_containers[entity_id]


## Phase 3: convenience — create and attach a fresh
## StatusContainer for the entity. Returns the new container.
## Equivalent to constructing StatusContainer.new(entity_id)
## and passing it to set_status_container().
func create_status_container(entity_id: int) -> RefCounted:
	var C = preload("res://core/battle_ecs/status/status_container.gd")
	var c = C.new(int(entity_id))
	set_status_container(entity_id, c)
	return c


## Removes an entity from the world. All component entries are
## dropped. The entity ID is NOT reused (entity is "dead" but
## remains a stable reference for events).
## Phase 3: also clears the entity's status container.
func remove_entity(id: int) -> void:
	_alive.erase(id)
	_teams.erase(id)
	_positions.erase(id)
	_max_hp.erase(id)
	_current_hp.erase(id)
	_attack.erase(id)
	_defense.erase(id)
	_attack_range.erase(id)
	_definition_ids.erase(id)
	_source_run_unit_ids.erase(id)
	# Phase 3: clear status container on entity removal.
	_status_containers.erase(id)
	var i: int = _player_ids_ordered.find(id)
	if i >= 0:
		_player_ids_ordered.remove_at(i)
	var j: int = _enemy_ids_ordered.find(id)
	if j >= 0:
		_enemy_ids_ordered.remove_at(j)


## Returns the alive entity IDs for `team` in deterministic
## allocation order.
func alive_ids_by_team(team: int) -> Array:
	var out: Array = []
	var source: Array = _player_ids_ordered if team == 0 else _enemy_ids_ordered
	for id in source:
		if is_alive(int(id)):
			out.append(int(id))
	return out


## B3: returns ALL alive entity IDs in deterministic numeric
## allocation order. Player units first (their IDs were
## allocated first), then enemy units, both in spawn order.
## This is the canonical entity iteration order for the
## periodic status phase. Do NOT use Dictionary iteration.
func alive_ids_in_order() -> Array:
	var out: Array = []
	for id in _player_ids_ordered:
		if is_alive(int(id)):
			out.append(int(id))
	for id in _enemy_ids_ordered:
		if is_alive(int(id)):
			out.append(int(id))
	return out


## True iff `cell` is occupied by any alive entity.
func is_cell_occupied(cell: Vector2i) -> bool:
	for id in _positions.keys():
		var p: Vector2i = _positions[id]
		if p.x == cell.x and p.y == cell.y and is_alive(int(id)):
			return true
	return false


## Computes the next-step cell toward `target_cell` from
## `attacker_cell` using Manhattan axis/tie ordering.
## Axis priority: Y first (matches legacy "forward" = row
## direction), then X. When |dy| >= |dx|, step along Y.
## Deterministic — same input -> same output.
static func step_cell_toward(attacker_cell: Vector2i, target_cell: Vector2i) -> Vector2i:
	var dx: int = int(target_cell.x) - int(attacker_cell.x)
	var dy: int = int(target_cell.y) - int(attacker_cell.y)
	if dx == 0 and dy == 0:
		return Vector2i(attacker_cell.x, attacker_cell.y)
	if absi(dy) >= absi(dx):
		if dy > 0:
			return Vector2i(attacker_cell.x, attacker_cell.y + 1)
		else:
			return Vector2i(attacker_cell.x, attacker_cell.y - 1)
	else:
		if dx > 0:
			return Vector2i(attacker_cell.x + 1, attacker_cell.y)
		else:
			return Vector2i(attacker_cell.x - 1, attacker_cell.y)


## Try to move `entity_id` ONE cell toward `target_id`.
## Returns the new cell on success, or the current cell on
## failure (out of bounds, target cell occupied by another
## alive entity, or entity not alive).
##
## HIGH 4 fix: if the primary axis candidate is blocked, try
## the secondary axis (X if Y was primary, Y if X was primary)
## PROVIDED the secondary cell is in bounds, unoccupied, and
## reduces Manhattan distance to target. If both blocked: no
## movement. This prevents false stalemates in trivially
## traversable formations.
##
## Deterministic — same world state -> same result.
func try_move_toward(entity_id: int, target_id: int) -> Vector2i:
	if not is_alive(entity_id) or not is_alive(target_id):
		return position_of(entity_id)
	var src: Vector2i = position_of(entity_id)
	var dst: Vector2i = position_of(target_id)
	# Try primary candidate.
	var primary: Vector2i = step_cell_toward(src, dst)
	if _is_walkable(entity_id, primary):
		_positions[entity_id] = primary
		return primary
	# HIGH 4: try secondary-axis candidate.
	var secondary: Vector2i = _secondary_axis_step(src, dst, primary)
	if _is_walkable(entity_id, secondary):
		_positions[entity_id] = secondary
		return secondary
	return src


## True iff `cell` is in bounds AND unoccupied by any other
## alive entity.
func _is_walkable(entity_id: int, cell: Vector2i) -> bool:
	if cell.x < 0 or cell.x >= grid_width or cell.y < 0 or cell.y >= grid_height:
		return false
	for id in _positions.keys():
		if int(id) == entity_id:
			continue
		if not is_alive(int(id)):
			continue
		var p: Vector2i = _positions[id]
		if p.x == cell.x and p.y == cell.y:
			return false
	return true


## HIGH 4 helper: compute the secondary-axis step cell.
## If `primary` stepped along Y, secondary steps along X (and
## vice versa). The secondary step is in the direction of the
## target's X (or Y) offset.
static func _secondary_axis_step(src: Vector2i, dst: Vector2i, primary: Vector2i) -> Vector2i:
	var dy: int = int(dst.y) - int(src.y)
	var dx: int = int(dst.x) - int(src.x)
	# If primary stepped along Y (dx unchanged), secondary steps
	# along X.
	if int(primary.x) == int(src.x) and int(primary.y) != int(src.y):
		if dx > 0:
			return Vector2i(int(src.x) + 1, int(src.y))
		elif dx < 0:
			return Vector2i(int(src.x) - 1, int(src.y))
		else:
			# dx == 0 means target is on the same column;
			# primary is already the only move.
			return src
	# Else primary stepped along X; secondary steps along Y.
	if int(primary.y) == int(src.y) and int(primary.x) != int(src.x):
		if dy > 0:
			return Vector2i(int(src.x), int(src.y) + 1)
		elif dy < 0:
			return Vector2i(int(src.x), int(src.y) - 1)
		else:
			return src
	# On same cell as target.
	return src


## True iff one side has zero alive entities (the battle should
## terminate).
func one_side_empty() -> bool:
	return alive_ids_by_team(0).is_empty() or alive_ids_by_team(1).is_empty()


## True iff `attacker_id` is in attack range (Manhattan distance
## <= attacker.attack_range) of `target_id`. Both must be alive.
func in_attack_range(attacker_id: int, target_id: int) -> bool:
	if not is_alive(attacker_id) or not is_alive(target_id):
		return false
	var a: Vector2i = position_of(attacker_id)
	var t: Vector2i = position_of(target_id)
	var d: int = absi(a.x - t.x) + absi(a.y - t.y)
	return d <= attack_range_of(attacker_id)


## Returns the alive enemy entity ID nearest (Manhattan) to
## `attacker_id`. Ties broken by allocation order (smaller ID
## wins). Returns -1 if none.
func nearest_enemy_id(attacker_id: int, candidate_ids: Array) -> int:
	if not is_alive(attacker_id):
		return -1
	var origin: Vector2i = position_of(attacker_id)
	var best_id: int = -1
	var best_dist: int = 999999
	for cid in candidate_ids:
		var id_i: int = int(cid)
		if not is_alive(id_i):
			continue
		var p: Vector2i = position_of(id_i)
		var d: int = absi(origin.x - p.x) + absi(origin.y - p.y)
		if d < best_dist:
			best_dist = d
			best_id = id_i
	return best_id


## Returns battle entity ID -> source_run_unit_id for entities
## that came from Run Domain (i.e. have a non-empty source id).
func source_run_unit_mapping() -> Dictionary:
	var out: Dictionary = {}
	for id in _source_run_unit_ids.keys():
		var sid: String = String(_source_run_unit_ids[id])
		if sid != "":
			out[int(id)] = sid
	return out


## Test/debug helper: returns all allocated entity IDs (alive and
## dead) in allocation order.
func all_known_ids() -> Array:
	var out: Array = []
	for i in _next_id:
		out.append(i)
	return out
