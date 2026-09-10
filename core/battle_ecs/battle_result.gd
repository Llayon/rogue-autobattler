class_name BattleResult extends RefCounted
## Phase 2 / BattleSimulation — battle outcome DTO.
##
## Pure data, presentation-independent, no Node references.
## All fields are public for read; the simulation does NOT mutate
## RunDomainState. BattleResult is descriptive only.
##
## Fields:
##   - winner_team: 0 = PLAYER won, 1 = ENEMY won, -1 = draw.
##   - outcome: OUTCOME_VICTORY / OUTCOME_DEFEAT / OUTCOME_DRAW.
##   - termination_reason: TERMINATION_NATURAL /
##     TERMINATION_STALEMATE / TERMINATION_TICK_BUDGET.
##   - tick_count: number of simulation ticks consumed.
##   - surviving_player_ids / surviving_enemy_ids: Array[int] of
##     battle entity IDs still alive at battle end (HP > 0).
##   - source_run_unit_mapping: Dictionary[int, String] — battle
##     entity ID -> source_run_unit_id for the player entities
##     that came from Run Domain. Enemy entities are absent.
##
## Outcome semantics (enforced by BattleSimulation):
##   - Player empty, enemy alive:  winner=1, OUTCOME_DEFEAT, NATURAL
##   - Enemy empty, player alive:  winner=0, OUTCOME_VICTORY, NATURAL
##   - Both empty:                winner=-1, OUTCOME_DRAW, NATURAL
##   - Stalemate (no progress):    winner=-1, OUTCOME_DRAW, STALEMATE
##   - Tick budget hit:            winner=-1, OUTCOME_DRAW, TICK_BUDGET
##
## Forced termination NEVER awards a victory.

const OUTCOME_VICTORY: int = 0
const OUTCOME_DEFEAT: int = 1
const OUTCOME_DRAW: int = 2

const TERMINATION_NATURAL: int = 0
const TERMINATION_STALEMATE: int = 1
const TERMINATION_TICK_BUDGET: int = 2

var winner_team: int = -1
var outcome: int = -1
var termination_reason: int = -1
var tick_count: int = 0
var surviving_player_ids: Array = []   # Array[int]
var surviving_enemy_ids: Array = []    # Array[int]
var source_run_unit_mapping: Dictionary = {}  # int -> String
