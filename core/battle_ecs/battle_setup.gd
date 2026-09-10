class_name BattleSetup extends RefCounted
## Phase 2 / BattleSimulation — IMMUTABLE-SEMANTICS battle input.
##
## Holds:
##   - seed: deterministic seed used to construct the simulation's
##     owned DeterministicRng.
##   - player_units: Array[BattleUnitSetup] (team = 0).
##   - enemy_units: Array[BattleUnitSetup] (team = 1).
##   - grid_width / grid_height: integer grid bounds.
##
## Immutability model: BattleSetup stores **defensive copies** of
## the caller-provided arrays and unit setups. After construction,
## later mutation of the caller's arrays / unit fields does NOT
## change this BattleSetup. BattleSimulation.initialize() takes
## ANOTHER snapshot of these defensive copies, so an in-progress
## battle cannot be retroactively mutated by the caller.
##
## No Node dependencies. No global RNG. No presentation references.
##
## Construction does NOT allocate entities or RNG. That happens
## inside BattleSimulation.initialize().

const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")

var seed: int = 0
var player_units: Array = []  # Array[BattleUnitSetup] (defensive copies)
var enemy_units: Array = []   # Array[BattleUnitSetup] (defensive copies)
var grid_width: int = 7
var grid_height: int = 4


func _init(
		p_seed: int = 0,
		p_player_units: Array = [],
		p_enemy_units: Array = [],
		p_grid_width: int = 7,
		p_grid_height: int = 4) -> void:
	seed = p_seed
	player_units = _clone_unit_array(p_player_units)
	enemy_units = _clone_unit_array(p_enemy_units)
	grid_width = maxi(1, p_grid_width)
	grid_height = maxi(1, p_grid_height)


static func _clone_unit_array(src: Array) -> Array:
	var out: Array = []
	for u in src:
		if u == null:
			out.append(null)
			continue
		var copy: BattleUnitSetupScript = BattleUnitSetupScript.new(
			u.source_run_unit_id,
			u.definition_id,
			u.team,
			Vector2i(int(u.cell.x), int(u.cell.y)),
			int(u.starting_hp),
			int(u.max_hp),
			int(u.attack_base),
			int(u.defense_base),
			int(u.attack_range))
		out.append(copy)
	return out


## True iff setup is well-formed enough to attempt simulation:
##   - both sides non-empty
##   - all cells within grid bounds
##   - all max_hp > 0
##   - all starting_hp in [0, max_hp]
##   - GLOBAL cell occupancy: no two units (any team) share a cell
##   - player_units[i].team == 0 (BLOCKER 3)
##   - enemy_units[i].team == 1 (BLOCKER 3)
##   - no team value outside {0, 1}
##   - every NON-EMPTY source_run_unit_id is unique across the
##     entire setup (HIGH 4 — duplicate stable identity rejected).
##     Empty source_run_unit_id (summons/enemies without a Run
##     source) is allowed multiple times.
##
## Returns a human-readable error string on the first defect, or
## "" when valid.
func validate() -> String:
	if player_units.is_empty():
		return "no player units"
	if enemy_units.is_empty():
		return "no enemy units"
	var occupied: Dictionary = {}
	var seen_source_ids: Dictionary = {}  # String -> team (int)
	for u in player_units:
		var msg: String = _validate_one(u, 0, occupied, seen_source_ids)
		if msg != "":
			return msg
	for u in enemy_units:
		var msg: String = _validate_one(u, 1, occupied, seen_source_ids)
		if msg != "":
			return msg
	return ""


func _validate_one(u: BattleUnitSetup, expected_team: int, occupied: Dictionary, seen_source_ids: Dictionary) -> String:
	if u == null:
		return "null unit setup"
	if u.team != expected_team:
		return "unit %s team=%d (expected %d in this array)" % [String(u.definition_id), int(u.team), expected_team]
	if u.max_hp <= 0:
		return "unit %s has max_hp <= 0" % String(u.definition_id)
	if u.starting_hp < 0 or u.starting_hp > u.max_hp:
		return "unit %s starting_hp %d out of [0,%d]" % [String(u.definition_id), u.starting_hp, u.max_hp]
	if u.cell.x < 0 or u.cell.x >= grid_width or u.cell.y < 0 or u.cell.y >= grid_height:
		return "unit %s cell %s out of bounds %dx%d" % [String(u.definition_id), str(u.cell), grid_width, grid_height]
	# Global cell occupancy — no two units share a cell,
	# regardless of team.
	var key: String = str(u.cell)
	if occupied.has(key):
		return "cell %s already occupied by team=%d (cannot share cells across teams)" % [str(u.cell), int(occupied[key])]
	occupied[key] = int(u.team)
	# HIGH 4: duplicate non-empty source_run_unit_id rejected.
	# Stable RunUnit.instance_id must be unique within a battle.
	if u.source_run_unit_id != "":
		if seen_source_ids.has(u.source_run_unit_id):
			return "duplicate source_run_unit_id '%s' (must be unique across setup)" % u.source_run_unit_id
		seen_source_ids[u.source_run_unit_id] = int(u.team)
	return ""
