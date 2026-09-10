class_name BattleUnitSetup extends RefCounted
## Phase 2 / BattleSimulation — IMMUTABLE-SEMANTICS setup row for
## a single battle participant.
##
## Carries only what is necessary to construct a battle entity:
##   - source_run_unit_id: stable RunUnit.instance_id String
##     when this unit is derived from Run Domain. Empty string for
##     pure-enemy units (no RunUnit source).
##   - definition_id: content-only ID (StringName). NOT used as
##     entity identity.
##   - team: 0 = PLAYER, 1 = ENEMY (matches legacy convention).
##   - cell: deployment cell (Vector2i). Must be within grid.
##   - starting_hp: current HP at battle start (>= 0).
##   - max_hp: maximum HP at battle start (> 0).
##   - attack_base: integer attack value before modifiers.
##   - defense_base: integer defense value before modifiers.
##   - attack_range: integer Manhattan attack range (>= 1).
##
## After construction, all fields are set from constructor
## arguments and the caller cannot mutate them through any
## supported field write path (GDScript fields are public by
## default — see BattleSetup._clone_unit_array() for the
## defensive-copy guarantee that BattleSetup snapshots its
## inputs).
##
## Duplicate warriors (same definition_id) MUST produce two
## distinct BattleUnitSetup rows with distinct source_run_unit_ids
## (when applicable) — that is what proves semantic identity.

var source_run_unit_id: String = ""
var definition_id: StringName = &""
var team: int = 0
var cell: Vector2i = Vector2i(-1, -1)
var starting_hp: int = 0
var max_hp: int = 0
var attack_base: int = 0
var defense_base: int = 0
var attack_range: int = 1


func _init(
		p_source_run_unit_id: String = "",
		p_definition_id: StringName = &"",
		p_team: int = 0,
		p_cell: Vector2i = Vector2i(-1, -1),
		p_starting_hp: int = 0,
		p_max_hp: int = 0,
		p_attack_base: int = 0,
		p_defense_base: int = 0,
		p_attack_range: int = 1) -> void:
	source_run_unit_id = String(p_source_run_unit_id)
	definition_id = p_definition_id
	team = int(p_team)
	cell = Vector2i(int(p_cell.x), int(p_cell.y))
	starting_hp = int(p_starting_hp)
	max_hp = int(p_max_hp)
	attack_base = int(p_attack_base)
	defense_base = int(p_defense_base)
	attack_range = maxi(1, int(p_attack_range))
