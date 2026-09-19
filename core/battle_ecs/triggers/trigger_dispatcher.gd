class_name DispatchResult extends RefCounted
## B5 / Phase-3 / DispatchResult — return value of
## TriggerDispatcher.process().
##
## Engine/debug information, NOT a BattleEvent. The
## committed-event gameplay semantics stay on the
## BattleEventEmitter side.

const REASON_NONE: int = 0
const REASON_MAX_DEPTH: int = 1
const REASON_MAX_EVENTS: int = 2
const REASON_MAX_REACTIONS_PER_ROOT: int = 3

var events: Array = []                  # new committed reaction events
var reactions_executed: int = 0
var truncated: bool = false
var reason: int = REASON_NONE


class_name TriggerDispatcher extends RefCounted
## B5 / Phase-3 / TriggerDispatcher — bounded FIFO event
## dispatcher.
##
## Consumes committed BattleEvents. For each event:
##   1. Calls provider.discover(world, event, rng) to get an
##      ordered list of TriggerReaction specs (PURE).
##   2. For each spec:
##      a. Build EffectRequest via child_from_parent(event, ...)
##         so ancestry derives from the actual triggering
##         event (no manual arithmetic).
##      b. Execute via EffectExecutor using the simulation-
##         owned world / rng / emitter / sink.
##      c. Append any newly committed events to the queue.
##
## Hard limits (see TriggerLimits):
##   - max_chain_depth: refuse EffectRequest that would exceed.
##   - max_events_per_tick: stop after N events processed.
##   - max_reactions_per_root: per-root reaction budget.
##
## No private RNG / emitter construction. No recursive
## function tree (FIFO loop).
##
## Re-dispatch protection: each event_id is processed at most
## once per process() call (seen-set).
##
## Per-process state (queue, seen, budget) cleared on each
## process() call -> two-simulation isolation.

const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const TriggerLimitsScript = preload("res://core/battle_ecs/triggers/trigger_limits.gd")

var _queue: Array = []                       # BattleEvent
var _seen: Dictionary = {}                  # event_id -> true
var _reaction_budget: Dictionary = {}        # root_action_id -> int


func _reset() -> void:
	_queue = []
	_seen = {}
	_reaction_budget = {}


## Dispatch all reactions triggered by `initial_events` and any
## downstream reaction events, bounded by `limits`. Returns
## a DispatchResult with the new committed reaction events
## (NOT including `initial_events`).
func process(
		p_initial_events: Array,
		p_world,
		p_rng,
		p_emitter,
		p_sink: Array,
		p_provider,
		p_limits: Resource) -> DispatchResult:
	_reset()
	if p_limits == null:
		p_limits = TriggerLimitsScript.new()
	var result := DispatchResult.new()
	# Seed the queue with initial events (in order).
	for ev in p_initial_events:
		_enqueue(ev)
	# FIFO loop.
	var ctx = EffectContextScript.new(p_world, p_rng, p_emitter, p_sink)
	var executor = EffectExecutorScript.new()
	var events_processed: int = 0
	while _queue.size() > 0:
		if events_processed >= int(p_limits.max_events_per_tick):
			result.truncated = true
			result.reason = DispatchResult.REASON_MAX_EVENTS
			break
		var ev = _queue.pop_front()
		var ev_id: int = int(ev.event_id)
		if _seen.has(ev_id):
			continue
		_seen[ev_id] = true
		events_processed += 1
		# Discovery (pure).
		var reactions: Array = p_provider.discover(p_world, ev, p_rng)
		for reaction in reactions:
			var outcome: int = _execute_reaction(
				reaction, ev, p_world, p_rng, p_emitter, p_sink,
				executor, p_limits)
			if outcome == DispatchResult.REASON_NONE:
				result.reactions_executed += 1
				continue
			result.truncated = true
			result.reason = outcome
			# Outer while loop continues with other queued
			# events (different root). Per-root budget only
			# affects further reactions of THIS root.
	return result


# Internal: enqueue an event. Seen-tracking is done in pop
# so we can dedupe before processing.
func _enqueue(ev) -> void:
	_queue.append(ev)


# Internal: execute one reaction; returns REASON_NONE on
# success or a REASON_* limit constant if the reaction was
# rejected.
func _execute_reaction(
		p_reaction,
		p_triggering_event,
		p_world,
		p_rng,
		p_emitter,
		p_sink: Array,
		p_executor,
		p_limits: Resource) -> int:
	# Per-root reaction budget.
	var root_id: int = int(p_triggering_event.root_action_id)
	var used: int = int(_reaction_budget.get(root_id, 0))
	if used >= int(p_limits.max_reactions_per_root):
		return DispatchResult.REASON_MAX_REACTIONS_PER_ROOT
	_reaction_budget[root_id] = used + 1

	# Build EffectRequest derived from the actual triggering
	# event (B2.3 canonical ancestry). The reaction's
	# caller-supplied request fields (kind, source_entity,
	# target_entity, amount) win; the event provides
	# parent_event_id, root_action_id, chain_depth.
	var req_in = p_reaction.request
	var req = EffectRequestScript.child_from_parent(
		int(req_in.kind),
		p_triggering_event,
		int(req_in.source_entity),
		int(req_in.target_entity),
		int(req_in.amount))

	# Depth limit: reject before executing if chain_depth
	# would exceed max_chain_depth. Per spec: depth == 32
	# is the final accepted depth; depth 33 is rejected.
	if req == null or int(req.chain_depth) > int(p_limits.max_chain_depth):
		# Refund the budget slot (no reaction was actually
		# executed).
		_reaction_budget[root_id] = used
		return DispatchResult.REASON_MAX_DEPTH

	# Execute via simulation-owned resources.
	var ctx = EffectContextScript.new(p_world, p_rng, p_emitter, p_sink)
	var exec_result = p_executor.execute(ctx, req)
	if exec_result == null:
		_reaction_budget[root_id] = used
		return DispatchResult.REASON_NONE
	# Failed-effect rule: no event -> no trigger input.
	# EffectResult.events only contains actually-committed
	# events (EffectExecutor enforces that already). We just
	# enqueue whatever is in result.events.
	for emitted in exec_result.events:
		_enqueue(emitted)
	return DispatchResult.REASON_NONE
