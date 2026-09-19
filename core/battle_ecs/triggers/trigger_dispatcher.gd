class_name TriggerDispatcher extends RefCounted
## B5 / Phase-3 / TriggerDispatcher — bounded FIFO event
## dispatcher.
##
## Consumes committed BattleEvents. For each event:
##   1. Calls provider.discover(world, event, rng) to get an
##      ordered list of TriggerReaction specs (PURE — must
##      NOT mutate RNG; spec B5.1). RNG is passed but may
##      NOT be advanced.
##   2. For each spec:
##      a. Build EffectRequest via
##         EffectRequest.child_from_template(reaction.request,
##         triggering_event) — the SINGLE canonical
##         factory that preserves template semantics
##         (definition_id, payload deep-copy) while
##         deriving ancestry from the triggering event.
##         No kind-specific branches.
##      b. Validate per-root reaction budget BEFORE
##         mutation. Exhausted roots return
##         REASON_MAX_REACTIONS_PER_ROOT without
##         committing.
##      c. Validate chain_depth BEFORE mutation. Depth
##         == max accepted; max+1 rejected.
##      d. Execute via EffectExecutor with simulation-
##         owned world / rng / emitter / sink.
##      e. AT COMMIT TIME: append every emitted event to
##         both result.events AND the queue (no
##         post-pop re-record). Initial input events are
##         NEVER re-emitted by the dispatcher.
##
## Hard limits (see TriggerLimits):
##   - max_chain_depth: refuse EffectRequest whose
##     chain_depth would exceed this BEFORE any
##     mutation. depth==max accepted; max+1 rejected.
##   - max_events_per_tick: stop processing newly-
##     committed events for trigger discovery after N
##     UNIQUE events have been processed. Already-committed
##     events REMAIN in result.events (they were committed
##     before the cap fired). MAX_EVENTS is the only
##     GLOBAL processing stop; per-root budget is LOCAL.
##   - max_reactions_per_root: per-root_action_id budget.
##     One root's exhaustion cannot affect another root's
##     reactions.
##
## Reactions executed semantics: number of EffectExecutor
## attempts actually admitted and executed after depth,
## per-root, and validation gates. An admitted reaction
## may fail / no-op / emit zero events and still count
## as executed. NOT the number of committed reaction
## events.
##
## Truncation reason policy: REASON_NONE on success.
## First non-NONE reason wins and is recorded. Subsequent
## per-root / per-depth truncation in the same call does
## NOT overwrite the first reason (avoids ambiguity).
## `truncated=true` means at least one branch was bounded.
##
## No private RNG / emitter construction. No recursive
## function tree (FIFO loop).
##
## Re-dispatch protection: each event_id is processed at
## most once per process() call (seen-set).
##
## Per-process state (queue, seen, budget) cleared on each
## process() call -> true same-instance isolation between
## back-to-back calls.

const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const TriggerLimitsScript = preload("res://core/battle_ecs/triggers/trigger_limits.gd")
const DispatchResultScript = preload("res://core/battle_ecs/triggers/dispatch_result.gd")

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
## (NOT including `initial_events`) plus counters + reason.
func process(
		p_initial_events: Array,
		p_world,
		p_rng,
		p_emitter,
		p_sink: Array,
		p_provider,
		p_limits: Resource) -> RefCounted:
	_reset()
	if p_limits == null:
		p_limits = TriggerLimitsScript.new()
	var result := DispatchResultScript.new()
	# Seed the queue with initial events (in order). Initial
	# events are NOT appended to result.events (they were
	# already committed by the caller). Duplicates are
	# deduped by the seen-set when popped.
	var executor = EffectExecutorScript.new()
	for ev in p_initial_events:
		_enqueue(ev)
	# FIFO loop. MAX_EVENTS is the ONLY global stop.
	while _queue.size() > 0:
		var ev = _queue.pop_front()
		var ev_id: int = int(ev.event_id)
		if _seen.has(ev_id):
			continue
		_seen[ev_id] = true
		# Cap fires BEFORE further processing. Already-
		# committed events from prior iterations stay in
		# result.events.
		if _seen.size() > int(p_limits.max_events_per_tick):
			# Decrement seen (we did not actually add
			# this id) and stop. Removing the id avoids
			# drift if the caller re-enters.
			_seen.erase(ev_id)
			if not result.truncated:
				result.truncated = true
				result.reason = DispatchResultScript.REASON_MAX_EVENTS
			break
		# Discovery (PURE per B5.1 contract). Provider must
		# not advance RNG.
		var reactions: Array = p_provider.discover(p_world, ev, p_rng)
		for reaction in reactions:
			# Malformed reaction hardening: skip without
			# mutation, do not report as MAX_DEPTH.
			if reaction == null or reaction.request == null:
				continue
			var outcome: int = _execute_reaction(
				reaction, ev, p_world, p_rng, p_emitter, p_sink,
				executor, result, p_limits)
			# outcome == REASON_NONE on success
			if outcome != DispatchResultScript.REASON_NONE and not result.truncated:
				result.truncated = true
				result.reason = outcome
	return result


# Internal: enqueue an event.
func _enqueue(ev) -> void:
	_queue.append(ev)


# Internal: execute one reaction; returns REASON_NONE on
# success or a REASON_* limit constant if the reaction was
# rejected. AT COMMIT TIME: appends every emitted event to
# BOTH result.events AND the queue.
func _execute_reaction(
		p_reaction,
		p_triggering_event,
		p_world,
		p_rng,
		p_emitter,
		p_sink: Array,
		p_executor,
		p_result: RefCounted,
		p_limits: Resource) -> int:
	# Per-root reaction budget (LOCAL to that root).
	var root_id: int = int(p_triggering_event.root_action_id)
	var used: int = int(_reaction_budget.get(root_id, 0))
	if used >= int(p_limits.max_reactions_per_root):
		return DispatchResultScript.REASON_MAX_REACTIONS_PER_ROOT
	_reaction_budget[root_id] = used + 1

	# Build EffectRequest from template. ANCESTRY derives
	# ONLY from parent_event. SEMANTIC FIELDS (kind,
	# source, target, amount, definition_id, payload) come
	# from the template. No kind-specific branching here.
	var req = EffectRequestScript.child_from_template(
		p_reaction.request,
		p_triggering_event)
	if req == null:
		# Refund budget slot (no reaction executed).
		_reaction_budget[root_id] = used
		return DispatchResultScript.REASON_NONE

	# Depth limit: REJECT BEFORE mutation. depth == max
	# accepted; max+1 rejected.
	if int(req.chain_depth) > int(p_limits.max_chain_depth):
		_reaction_budget[root_id] = used
		return DispatchResultScript.REASON_MAX_DEPTH

	# Mutations admissible; count the attempt regardless
	# of effect outcome (per spec: admitted reaction that
	# fails / no-ops still counts as executed).
	_reaction_budget[root_id] = used + 1  # keep consumed
	p_result.reactions_executed += 1

	# Execute via simulation-owned resources.
	var ctx = EffectContextScript.new(p_world, p_rng, p_emitter, p_sink)
	var exec_result = p_executor.execute(ctx, req)
	if exec_result == null:
		return DispatchResultScript.REASON_NONE
	# Failed-effect rule: no event -> no trigger input.
	# AT COMMIT TIME: append every committed event to
	# BOTH p_result.events and the queue (in EXACT
	# emission order). Don't re-record on pop.
	for emitted in exec_result.events:
		p_result.events.append(emitted)
		_enqueue(emitted)
	return DispatchResultScript.REASON_NONE
