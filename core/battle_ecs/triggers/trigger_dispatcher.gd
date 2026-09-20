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
##
## B6 / Tick-scoped SESSIONS:
##   When a session is supplied (via begin_session() or the
##   session parameter), process() uses the session's
##   cumulative seen-set, per-root budget, and
##   events_processed counter. The queue is local per
##   call (so the FIFO loop remains a stack-safe BFS).
##   Once the session reaches MAX_EVENTS, every subsequent
##   process() call within that session returns an empty
##   result (preserves session.truncated/resetting nothing).

const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const TriggerLimitsScript = preload("res://core/battle_ecs/triggers/trigger_limits.gd")
const DispatchResultScript = preload("res://core/battle_ecs/triggers/dispatch_result.gd")
const TriggerDispatchSessionScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatch_session.gd")

var _queue: Array = []                       # BattleEvent
var _seen: Dictionary = {}                  # event_id -> true (per-call OR session-scoped)
var _reaction_budget: Dictionary = {}        # root_action_id -> int (per-call OR session-scoped)


## Begin a fresh tick-scoped trigger session. The session
## snapshots the numeric limit values from `p_limits` so the
## tick-in-progress limits do not change if the caller
## mutates the underlying TriggerLimits Resource.
##
## Pass the session back to process() to share state
## across phase calls within one simulation tick. A fresh
## process() call without a session creates an internal
## ephemeral one (B5 backward-compatible behavior).
func begin_session(p_limits: Resource) -> RefCounted:
	return TriggerDispatchSessionScript.from_limits(p_limits)


func _reset() -> void:
	_queue = []
	_seen = {}
	_reaction_budget = {}


## Dispatch all reactions triggered by `initial_events` and
## any downstream reaction events, bounded by `limits` (or
## the session's snapshotted limits). Returns a DispatchResult
## with the new committed reaction events (NOT including
## `initial_events`) plus counters + reason.
##
## `p_session` (optional):
##   null      -> fresh per-call state (B5 backward compat)
##   provided  -> use this session's cumulative seen-set /
##                per-root budget / events_processed counter.
##                Session truncated/reason remain consistent.
func process(
		p_initial_events: Array,
		p_world,
		p_rng,
		p_emitter,
		p_sink: Array,
		p_provider,
		p_limits: Resource,
		p_session = null) -> RefCounted:
	var using_session: bool = p_session != null
	if using_session:
		# Dispatcher refs alias the session accumulators.
		_seen = p_session._seen
		_reaction_budget = p_session._reaction_budget
		_queue = []
	else:
		_reset()
		if p_limits == null:
			p_limits = TriggerLimitsScript.new()
	# Effective numeric limits: from session if provided,
	# else from the limits Resource.
	var eff_max_events: int = int(
		p_session.max_events_per_tick if using_session \
			else p_limits.max_events_per_tick)
	var eff_max_chain: int = int(
		p_session.max_chain_depth if using_session \
			else p_limits.max_chain_depth)
	var eff_max_reactions_per_root: int = int(
		p_session.max_reactions_per_root if using_session \
			else p_limits.max_reactions_per_root)
	var result := DispatchResultScript.new()
	# Mirror session state (truncation that already fired
	# in a prior call of this tick) into this call's result.
	if using_session and bool(p_session.truncated):
		result.truncated = true
		result.reason = int(p_session.first_reason)
	# Seed the queue with initial events (in order).
	var executor = EffectExecutorScript.new()
	for ev in p_initial_events:
		_enqueue(ev)
	# FIFO loop. MAX_EVENTS is the ONLY global stop. The
	# canonical contract is: 4 unique events accepted with
	# cap=4 -> NOT truncated. The 5th unique event in this
	# same tick session -> truncated (try_mark returns
	# false due to cap pre-check, then we record truncation
	# and break). This means a call whose INITIAL events all
	# equal cap (e.g. r3 here: pop e4 with cap=4 already hit)
	# correctly records truncated=true and emits nothing.
	while _queue.size() > 0:
		var ev = _queue.pop_front()
		var ev_id: int = int(ev.event_id)
		# Canonical: re-dispatch protection.
		if (using_session and p_session.has_seen(ev_id)) \
				or (not using_session and _seen.has(ev_id)):
			continue
		# Canonical pre-check: try_mark is the ONE place
		# that mutates events_processed. It returns false
		# either if already seen OR cap reached.
		var accepted: bool = true
		if using_session:
			accepted = p_session.try_mark(ev_id)
		else:
			# Standalone path: mirror the session contract.
			if _seen.size() >= eff_max_events:
				accepted = false
			else:
				if not _seen.has(ev_id):
					_seen[ev_id] = true
					accepted = true
				else:
					accepted = false
		if not accepted:
			# Cap reached. Record truncation for the first
			# time, set reason, and break. No rollback.
			result.truncated = true
			if result.reason == 0:
				result.reason = int(
					DispatchResultScript.REASON_MAX_EVENTS)
			if using_session and not p_session.truncated:
				p_session.record_truncation(int(
					DispatchResultScript.REASON_MAX_EVENTS))
			break
		# Discovery (PURE per B5.1 contract).
		var reactions: Array = p_provider.discover(p_world, ev, p_rng)
		for reaction in reactions:
			if reaction == null or reaction.request == null:
				continue
			var outcome: int = _execute_reaction(
				reaction, ev, p_world, p_rng, p_emitter, p_sink,
				executor, result, eff_max_chain, eff_max_reactions_per_root,
				p_session)
			if outcome != DispatchResultScript.REASON_NONE:
				if using_session and not p_session.truncated:
					p_session.record_truncation(int(outcome))
					result.truncated = true
					result.reason = int(outcome)
				elif using_session and p_session.truncated:
					result.truncated = true
					result.reason = int(p_session.first_reason)
				else:
					# Standalone: first non-NONE wins.
					result.truncated = true
					if result.reason == 0:
						result.reason = int(outcome)
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
		p_max_chain_depth: int,
		p_max_reactions_per_root: int,
		p_session = null) -> int:
	# Per-root reaction budget (LOCAL to that root, but
	# CUMULATIVE across this session if p_session is set).
	var root_id: int = int(p_triggering_event.root_action_id)
	var used: int
	if p_session != null:
		used = int(p_session.used_budget_for(root_id))
	else:
		used = int(_reaction_budget.get(root_id, 0))
	if used >= int(p_max_reactions_per_root):
		return DispatchResultScript.REASON_MAX_REACTIONS_PER_ROOT
	var new_used: int = used + 1
	if p_session != null:
		p_session._reaction_budget[root_id] = new_used
	else:
		_reaction_budget[root_id] = new_used

	# Build EffectRequest from template.
	var req = EffectRequestScript.child_from_template(
		p_reaction.request,
		p_triggering_event)
	if req == null:
		# Refund budget slot (no reaction executed).
		if p_session != null:
			p_session._reaction_budget[root_id] = used
		else:
			_reaction_budget[root_id] = used
		return DispatchResultScript.REASON_NONE

	# Depth limit: REJECT BEFORE mutation.
	if int(req.chain_depth) > int(p_max_chain_depth):
		if p_session != null:
			p_session._reaction_budget[root_id] = used
		else:
			_reaction_budget[root_id] = used
		return DispatchResultScript.REASON_MAX_DEPTH

	# Mutations admissible; count the attempt.
	if p_session != null:
		p_session._reaction_budget[root_id] = new_used
	else:
		_reaction_budget[root_id] = new_used
	p_result.reactions_executed += 1

	# Execute via simulation-owned resources.
	var ctx = EffectContextScript.new(p_world, p_rng, p_emitter, p_sink)
	var exec_result = p_executor.execute(ctx, req)
	if exec_result == null:
		return DispatchResultScript.REASON_NONE
	# AT COMMIT TIME: append every committed event to
	# BOTH p_result.events and the queue.
	for emitted in exec_result.events:
		p_result.events.append(emitted)
		_enqueue(emitted)
	return DispatchResultScript.REASON_NONE
