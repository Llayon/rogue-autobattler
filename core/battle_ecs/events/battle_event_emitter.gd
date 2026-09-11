class_name BattleEventEmitter extends RefCounted
## Phase 3 / BattleEventEmitter — central allocation authority for
## BattleEvent objects.
##
## Responsibilities:
##   - Monotonic event_id allocation starting at 1 after reset()
##   - Monotonic root_action_id allocation
##   - per-emitter current tick (set by BattleSimulation per step)
##   - Construction of BattleEvent objects with valid ancestry
##     metadata (parent_event_id, root_action_id, chain_depth).
##
## Architectural rules:
##   - RefCounted (no Node, no scene refs, no global state)
##   - simulation-scoped (BattleSimulation owns one)
##   - deterministic (no RandomNumberGenerator, no global RNG)
##   - Threading/parallelism: not a concern in this slice.
##
## Phase 2 invariant preserved: first event_id == 1 after reset().
##
## NOT for: gameplay mutation. The emitter only constructs events.

const BattleEventScript = preload("res://core/battle_ecs/battle_event.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const BattleResultScript = preload("res://core/battle_ecs/battle_result.gd")

var _next_event_id: int = 1
var _next_root_action_id: int = 1
var _current_tick: int = 0


## Reset to a clean state. Next event starts at id 1, next root
## action at 1. Deterministic across re-init.
func reset() -> void:
	_next_event_id = 1
	_next_root_action_id = 1
	_current_tick = 0


## Set the current simulation tick. The next emitted events will
## carry this tick value.
func set_tick(p_tick: int) -> void:
	_current_tick = int(p_tick)


## Returns the current tick (for inspection).
func current_tick() -> int:
	return _current_tick


## Allocates a fresh root_action_id. Use this when a combat
## action begins a new reaction chain (e.g. an Attack root or a
## Burn periodic tick root).
##
## Returns a positive int (>= 1) after reset().
func next_root_action_id() -> int:
	var r: int = int(_next_root_action_id)
	_next_root_action_id += 1
	return r


## Emits one BattleEvent. Returns the constructed event.
##
## If `parent_event_id` and `root_action_id` are passed, they
## are stored verbatim (caller takes responsibility for chain
## metadata coherence). If `root_action_id` is -1 (default),
## the emitter allocates a fresh root action for this event
## (treats it as a root emission).
##
## If `parent_event_id` is -1 (default), the event is treated as
## a root emission and chain_depth is forced to 0.
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
		p_to_cell: Vector2i = Vector2i(-1, -1),
		p_root_action_id: int = -1,
		p_parent_event_id: int = -1,
		p_chain_depth: int = -1) -> BattleEvent:
	var ev: BattleEvent = BattleEventScript.new()
	ev.event_id = int(_next_event_id)
	_next_event_id += 1
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
	if int(p_root_action_id) < 0:
		ev.root_action_id = next_root_action_id()
		ev.parent_event_id = -1
		ev.chain_depth = 0
	else:
		ev.root_action_id = int(p_root_action_id)
		ev.parent_event_id = int(p_parent_event_id)
		if int(p_chain_depth) < 0:
			# Caller provided a root but no depth: treat as root.
			ev.chain_depth = 0
		else:
			ev.chain_depth = int(p_chain_depth)
	return ev


## Convenience: emit a child event whose parent_event_id is
## known. Caller supplies the parent root_action_id and the
## parent's chain_depth (this event will be parent.chain_depth+1).
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
		p_to_cell: Vector2i = Vector2i(-1, -1)) -> BattleEvent:
	return emit(
		p_type,
		p_source_entity,
		p_target_entity,
		p_source_run_unit_id,
		p_target_run_unit_id,
		p_amount,
		p_tag,
		p_from_cell,
		p_to_cell,
		int(p_parent_root_action_id),
		int(p_parent_event_id),
		int(p_parent_chain_depth) + 1)


## Diagnostic accessor (read-only). Used by tests.
func peek_next_event_id() -> int:
	return int(_next_event_id)


func peek_next_root_action_id() -> int:
	return int(_next_root_action_id)
