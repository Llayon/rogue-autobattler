class_name BattleEvent extends RefCounted
## Phase 2 + Phase 3 / BattleSimulation — logical event payload.
##
## Carries NO Node, NO Control, NO scene reference.
##
## Fields:
##   - event_id: monotonically-increasing int, unique per battle.
##     Allocator: BattleEventEmitter (Phase 3 centralizes this).
##   - type: BattleEventType enum value.
##   - tick: simulation tick when the event was emitted (>= 0).
##   - source_entity: int entity ID of the actor (or -1 if none).
##   - target_entity: int entity ID of the target (or -1 if none).
##   - source_run_unit_id: stable RunUnit.instance_id String for
##     the actor (when applicable), else "".
##   - target_run_unit_id: stable RunUnit.instance_id String for
##     the target (when applicable), else "".
##   - amount: damage dealt (or healing, depending on type).
##     Not used for position data — use from_cell/to_cell for
##     movement.
##   - tag: free-form string tag (currently unused; reserved for
##     future event taxonomy).
##   - from_cell: Vector2i source position (used by UNIT_MOVED).
##   - to_cell: Vector2i destination position (used by UNIT_MOVED).
##
## Phase 3 ancestry (new):
##   - parent_event_id: int event_id of the immediate triggering
##     event, or -1 for root events.
##   - root_action_id: int shared by all events in one reaction
##     chain. Allocated by BattleEventEmitter. -1 if no chain.
##   - chain_depth: int 0 for the root event of a chain, depth+1
##     for each child reaction event.

var event_id: int = 0
var type: int = 0
var tick: int = 0
var source_entity: int = -1
var target_entity: int = -1
var source_run_unit_id: String = ""
var target_run_unit_id: String = ""
var amount: int = 0
var tag: String = ""
var from_cell: Vector2i = Vector2i(-1, -1)
var to_cell: Vector2i = Vector2i(-1, -1)
var parent_event_id: int = -1
var root_action_id: int = -1
var chain_depth: int = 0
