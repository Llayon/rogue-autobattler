class_name BattleSetup extends RefCounted
## Phase 2 / BattleSimulation — IMMUTABLE battle input.
##
## Holds:
##   - seed: deterministic seed used to construct the simulation's
##     owned DeterministicRng.
##   - player_units: Array[BattleUnitSetup] (team = 0).
##   - enemy_units: Array[BattleUnitSetup] (team = 1).
##   - grid_width / grid_height: integer grid bounds.
##
## No Node dependencies. No global RNG. No presentation references.
##
## Construction does NOT allocate entities or RNG. That happens
## inside BattleSimulation.initialize().

const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")

var seed: int = 0
var player_units: Array = []  # Array[BattleUnitSetup]
var enemy_units: Array = []   # Array[BattleUnitSetup]
var grid_width: int = 7
var grid_height: int = 4


func _init(
		p_seed: int = 0,
		p_player_units: Array = [],
		p_enemy_units: Array = [],
		p_grid_width: int = 7,
		p_grid_height: int = 4) -> void:
	seed = p_seed
	player_units = p_player_units
	enemy_units = p_enemy_units
	grid_width = maxi(1, p_grid_width)
	grid_height = maxi(1, p_grid_height)


## True iff setup is well-formed enough to attempt simulation:
##   - both sides non-empty (otherwise no battle)
##   - all cells within grid bounds
##   - all starting_hp within [0, max_hp]
##   - no duplicate (cell, team) deployment
##
## Returns a human-readable error string on the first defect, or
## "" when valid.
func validate() -> String:
	if player_units.is_empty():
		return "no player units"
	if enemy_units.is_empty():
		return "no enemy units"
	var occupied: Dictionary = {}
	for u in player_units:
		var msg: String = _validate_one(u, occupied)
		if msg != "":
			return msg
	for u in enemy_units:
		var msg: String = _validate_one(u, occupied)
		if msg != "":
			return msg
	return ""


func _validate_one(u: BattleUnitSetup, occupied: Dictionary) -> String:
	if u == null:
		return "null unit setup"
	if u.max_hp <= 0:
		return "unit %s has max_hp <= 0" % String(u.definition_id)
	if u.starting_hp < 0 or u.starting_hp > u.max_hp:
		return "unit %s starting_hp %d out of [0,%d]" % [String(u.definition_id), u.starting_hp, u.max_hp]
	if u.cell.x < 0 or u.cell.x >= grid_width or u.cell.y < 0 or u.cell.y >= grid_height:
		return "unit %s cell %s out of bounds %dx%d" % [String(u.definition_id), str(u.cell), grid_width, grid_height]
	var key: String = "%d:%s" % [u.team, str(u.cell)]
	if occupied.has(key):
		return "duplicate deployment at team=%d cell=%s" % [u.team, str(u.cell)]
	occupied[key] = true
	return ""
