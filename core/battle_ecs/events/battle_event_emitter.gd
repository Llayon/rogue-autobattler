extends RefCounted
## Phase 3 / B2.1 / BattleEventEmitter — central allocation
## authority for BattleEvent objects.
##
## B2.1 contract:
##   - emit() constructs ROOT events. Always:
##       parent_event_id == -1
##       chain_depth     == 0
##       root_action_id  == freshly allocated positive int
##     The caller's depth/root metadata is ignored on a root
##     emission (caller cannot accidentally create
##     "root at depth 7").
##   - emit_child() constructs CHILD events. Requires:
##       parent_event_id      > 0
##       parent_root_action_id > 0
##       parent_chain_depth   >= 0
##     Rejected (returns null) when any of these are invalid.
##     The resulting child has:
##       chain_depth     == parent_chain_depth + 1
##       root_action_id  == parent_root_action_id
##   - emit() and emit_child() NEVER consume event_id /
##     root_action_id counters on rejection.
##
## Counters:
##   - event_id: starts at 1 after reset(); strictly monotonic.
##   - root_action_id: starts at 1 after reset(); strictly
##     monotonic.
##   - current_tick: tag for emitted events.
##
## No global state. Simulation-scoped.

const BattleEventScript = preload("res://core/battle_ecs/battle_event.gd")

var _next_event_id: int = 1
var _next_root_action_id: int = 1
var _current_tick: int = 0


## Reset all counters to their starting values. The next
## emitted event has event_id == 1; the next root action has
## root_action_id == 1.
func reset() -> void:
	_next_event_id = 1
	_next_root_action_id = 1
	_current_tick = 0


## Set the current simulation tick. The next emitted events
## carry this tick value.
func set_tick(p_tick: int) -> void:
	_current_tick = int(p_tick)


## Returns the current tick (for inspection).
func current_tick() -> int:
	return _current_tick


## Allocates and returns a fresh root_action_id. Each call
## advances the counter by 1.
func next_root_action_id() -> int:
	var r: int = int(_next_root_action_id)
	_next_root_action_id = int(_next_root_action_id) + 1
	return r


## Emits a ROOT BattleEvent.
##
## Required shape of the result:
##   event_id        = freshly allocated positive int
##   parent_event_id = -1
##   chain_depth     = 0
##   root_action_id  = freshly allocated positive int
##
## Caller-supplied p_root_action_id, p_parent_event_id,
## p_chain_depth are IGNORED — a root emission is always a
## root emission. This guarantees the emitter cannot be
## tricked into producing a "root at depth 7".
##
## Does NOT mutate world state. Pure event construction.
func emit(
		p_type: int,
		p_source_entity: int = -1,
		p_target_entity: int = -1,
		p_source_run_unit_id: String = "",
		p_target_run_unit_id: String = "",
		p_amount: int = 0,
		p_tag: String = "",
		p_from_cell: Vector2i = Vector2i(-1, -1),
		p_to_cell: Vector2i = Vector2i(-1, -1)) -> BattleEvent:
	var ev: BattleEvent = BattleEventScript.new()
	ev.event_id = int(_next_event_id)
	_next_event_id = int(_next_event_id) + 1
	ev.type = int(p_type)
	ev.tick = int(_current_tick)
	ev.source_entity = int(p_source_entity)
	ev.target_entity = int(p_target_entity)
	ev.source_run_unit_id = String(p_source_run_unit_id)
	ev.target_run_unit_id = String(p_target_run_unit_id)
	ev.amount = int(p_amount)
	ev.tag = String(p_tag)
	ev.from_cell = Vector2i(int(p_from_cell.x), int(p_from_cell.y))
	ev.to_cell = Vector2i(int(p_to_cell.x), int(p_to_cell.y))
	ev.root_action_id = next_root_action_id()
	ev.parent_event_id = -1
	ev.chain_depth = 0
	return ev


## Emits a CHILD BattleEvent. The child shares the parent's
## root_action_id, increments chain_depth by 1, and points
## its parent_event_id at the supplied parent.
##
## Returns null (no event created, no counter advanced) when:
##   p_parent_event_id        <= 0
##   p_parent_root_action_id   <= 0
##   p_parent_chain_depth     <  0
##
## Does NOT mutate world state. Pure event construction.
func emit_child(
		p_type: int,
		p_parent_event_id: int,
		p_parent_root_action_id: int,
		p_parent_chain_depth: int,
		p_source_entity: int = -1,
		p_target_entity: int = -1,
		p_source_run_unit_id: String = "",
		p_target_run_unit_id: String = "",
		p_amount: int = 0,
		p_tag: String = "",
		p_from_cell: Vector2i = Vector2i(-1, -1),
		p_to_cell: Vector2i = Vector2i(-1, -1)) -> RefCounted:
	if int(p_parent_event_id) <= 0:
		return null
	if int(p_parent_root_action_id) <= 0:
		return null
	if int(p_parent_chain_depth) < 0:
		return null
	var ev: BattleEvent = BattleEventScript.new()
	ev.event_id = int(_next_event_id)
	_next_event_id = int(_next_event_id) + 1
	ev.type = int(p_type)
	ev.tick = int(_current_tick)
	ev.source_entity = int(p_source_entity)
	ev.target_entity = int(p_target_entity)
	ev.source_run_unit_id = String(p_source_run_unit_id)
	ev.target_run_unit_id = String(p_target_run_unit_id)
	ev.amount = int(p_amount)
	ev.tag = String(p_tag)
	ev.from_cell = Vector2i(int(p_from_cell.x), int(p_from_cell.y))
	ev.to_cell = Vector2i(int(p_to_cell.x), int(p_to_cell.y))
	ev.parent_event_id = int(p_parent_event_id)
	ev.root_action_id = int(p_parent_root_action_id)
	ev.chain_depth = int(p_parent_chain_depth) + 1
	return ev


## Diagnostic accessor: returns the next event_id that would be
## assigned by the next successful emit() / emit_child(). The
## counter is not advanced by this call.
func peek_next_event_id() -> int:
	return int(_next_event_id)


## Diagnostic accessor: returns the next root_action_id that
## would be assigned by the next successful emit(). The counter
## is not advanced by this call.
func peek_next_root_action_id() -> int:
	return int(_next_root_action_id)
