class_name BattleResult extends RefCounted
## Phase 2 / BattleSimulation — battle outcome DTO.
##
## Pure data, presentation-independent, no Node references.
##
## Fields:
##   - winner_team: 0 = PLAYER won, 1 = ENEMY won, -1 = draw.
##   - outcome: BattleResult.OUTCOME_VICTORY / OUTCOME_DEFEAT /
##     OUTCOME_DRAW.
##   - tick_count: number of simulation ticks consumed.
##   - surviving_player_ids / surviving_enemy_ids: Array[int] of
##     battle entity IDs still alive at battle end (HP > 0).
##   - source_run_unit_mapping: Dictionary[int, String] — battle
##     entity ID -> source_run_unit_id for the player entities
##     that came from Run Domain. Enemy entities are absent.
##
## BattleResult does NOT mutate RunDomainState. It is purely
## descriptive.

const OUTCOME_VICTORY: int = 0   # player's side eliminated enemy side
const OUTCOME_DEFEAT: int = 1    # enemy side eliminated player's side
const OUTCOME_DRAW: int = 2      # both sides empty in same tick

var winner_team: int = -1
var outcome: int = -1
var tick_count: int = 0
var surviving_player_ids: Array = []   # Array[int]
var surviving_enemy_ids: Array = []    # Array[int]
var source_run_unit_mapping: Dictionary = {}  # int -> String
