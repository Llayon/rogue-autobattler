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
	# BLOCKER 3 fix: an entity spawned with starting_hp <= 0 is
	# dead at t=0. Mark it as non-alive so it never attacks and
	# never acquires a target. validate() rejects starting_hp < 0,
	# so we only need to guard starting_hp == 0 here (which is
	# allowed at the validator boundary).
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


## Removes an entity from the world. All component entries are
## dropped. The entity ID is NOT reused (entity is "dead" but
## remains a stable reference for events).
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
