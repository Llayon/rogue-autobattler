class_name TriggerDispatchSession extends RefCounted
## B6 / Phase-3 / TriggerDispatchSession — tick-scoped
## mutable state for ONE simulation tick.
##
## Holds the cumulative cross-call bookkeeping that the B5
## TriggerDispatcher previously reset per process() call:
##
##   - seen event_ids (re-dispatch protection across phases)
##   - per-root_action_id reaction budget
##   - events_processed counter
##   - truncated flag
##   - first non-NONE truncation reason
##   - snapshot of TriggerLimits numeric values at construction
##
## Limit snapshot contract:
##   The session snapshots the numeric max_* values at
##   construction. Mutating the original TriggerLimits
##   Resource after construction does NOT change the in-
##   progress tick's limits.
##
## Usage:
##   var session = dispatcher.begin_session(limits)
##   dispatcher.process(initial_events_a, ..., session)
##   dispatcher.process(initial_events_b, ..., session)
##   # session.truncated / session.first_reason are
##   # cumulative across the two calls.
##
## Disposal:
##   Sessions are owned by BattleSimulation per tick.
##   When the tick ends the session is discarded. A new
##   tick creates a fresh session with empty state. No
##   session state leaks across ticks.
##
## No global singleton. No shared static state.

var max_chain_depth: int = 0
var max_events_per_tick: int = 0
var max_reactions_per_root: int = 0

var _seen: Dictionary = {}                  # event_id -> true
var _reaction_budget: Dictionary = {}        # root_action_id -> int
var events_processed: int = 0
var truncated: bool = false
var first_reason: int = 0  # DispatchResult.REASON_NONE


## Snapshot limits at construction. TriggerLimits numeric
## values are read once; subsequent mutations of the
## original Resource do not affect this session.
static func from_limits(p_limits: Resource) -> TriggerDispatchSession:
	var s := TriggerDispatchSession.new()
	if p_limits == null:
		s.max_chain_depth = 32
		s.max_events_per_tick = 10000
		s.max_reactions_per_root = 256
		return s
	s.max_chain_depth = int(p_limits.max_chain_depth)
	s.max_events_per_tick = int(p_limits.max_events_per_tick)
	s.max_reactions_per_root = int(p_limits.max_reactions_per_root)
	return s


## True if the event_id has already been processed in
## this session (re-dispatch protection).
func has_seen(p_event_id: int) -> bool:
	return _seen.has(int(p_event_id))


## Atomically test-and-mark:
##   - if event_id already seen -> returns false, no mutation
##   - if NOT seen -> checks MAX_EVENTS cap BEFORE marking:
##       - if events_processed >= max_events_per_tick:
##           returns false (cap reached), no mark, no count
##       - else:
##           marks seen, increments events_processed, returns true
##
## This is the ONLY entry allowed to increment
## events_processed. The dispatcher MUST go through
## this method, NOT mutate _seen / events_processed
## directly.
func try_mark(p_event_id: int) -> bool:
	var id: int = int(p_event_id)
	if _seen.has(id):
		return false
	# Pre-check cap BEFORE marking. cap is "max N events
	# may be processed". Processed count == N -> cap hit.
	if events_processed >= int(max_events_per_tick):
		return false
	_seen[id] = true
	events_processed = int(events_processed) + 1
	return true


## True if this session has reached its MAX_EVENTS cap
## during the current tick. Future process() calls in
## this same tick should return truncated + empty events.
func cap_reached() -> bool:
	return int(events_processed) >= int(max_events_per_tick)


## Record the session's first truncation reason. Caller
## must only invoke this once (the first non-NONE reason).
## Subsequent calls are ignored (first wins).
func record_truncation(p_reason: int) -> void:
	if int(first_reason) == 0 and int(p_reason) != 0:
		first_reason = int(p_reason)
		truncated = true


## Number of unique event_ids currently tracked.
func seen_size() -> int:
	return len(_seen)


## Returns used reaction count for a root (0 if absent).
func used_budget_for(p_root_id: int) -> int:
	return int(_reaction_budget.get(int(p_root_id), 0))


## Increment the reaction counter for a root.
func increment_budget_for(p_root_id: int) -> int:
	var n: int = used_budget_for(p_root_id)
	_reaction_budget[int(p_root_id)] = n + 1
	return n + 1


## Reduce the reaction counter for a root (refund on
## rejection BEFORE exec).
func refund_budget_for(p_root_id: int, p_remaining: int) -> void:
	_reaction_budget[int(p_root_id)] = int(p_remaining)


## Returns the remaining reaction budget for a root
## (max - used), never negative.
func remaining_budget_for(p_root_id: int) -> int:
	return maxi(0, int(max_reactions_per_root) - used_budget_for(p_root_id))
