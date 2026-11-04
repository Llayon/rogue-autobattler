class_name TriggerDispatcher extends RefCounted
## B6 / Phase-3 / TriggerDispatcher — bounded FIFO event
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
## B6.4c: process_work() accepts a heterogeneous work array
## containing BattleEvent AND DamageWindowWorkItem. Window
## items trigger the pre-damage reaction window, then
## finalize, then re-enqueue delayed seeds + collected
## dispatch work + finalize-emitted events. Legacy
## process() is preserved for the standalone (non-window)
## path used by tests that drive the dispatcher directly.
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
##
## B6.4c invariants:
##   - No Effect/EffectExecutor/Continuation calls
##     TriggerDispatcher.process*. Dispatcher entrypoints
##     are invoked only by BattleSimulation-owned
##     scheduler/phase code (including _resolve_or_move)
##     or by explicit tests.
##   - Each DamageWindowWorkItem is processed exactly
##     once. finalize() is called inline within the work
##     loop. The handle is closed by finalize itself.
##   - pending_count tracks the number of work items
##     currently queued or in-flight. BattleSimulation
##     asserts pending_count == 0 at end of tick.

const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const TriggerLimitsScript = preload("res://core/battle_ecs/triggers/trigger_limits.gd")
const DispatchResultScript = preload("res://core/battle_ecs/triggers/dispatch_result.gd")
const TriggerDispatchSessionScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatch_session.gd")

var _queue: Array = []                       # BattleEvent | DamageWindowWorkItem
var _seen: Dictionary = {}                  # event_id -> true (per-call OR session-scoped)
var _reaction_budget: Dictionary = {}        # root_action_id -> int (per-call OR session-scoped)
var _pending_count: int = 0                 # B6.4c: window work items in flight + queued


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
	# B6.4c: process() is a BACKWARD-COMPATIBLE WRAPPER around
	# process_work(). It must NOT contain its own copy of the
	# work-pump state machine. Two divergent cycles were a
	# refactor accident that we explicitly removed. All queue
	# logic, seen-set, MAX_EVENTS, window handling, finalize,
	# delayed seeds, collector mode, and post-commit FIFO live
	# in EXACTLY ONE place: process_work(). This wrapper just
	# routes the call there. The return value of process_work
	# (DispatchResult) is compatible with the legacy return
	# contract: legacy callers (b64a, b62b-counters, etc.) only
	# read .events / .truncated / .reason / .reactions_executed.
	return process_work(
		p_initial_events,
		p_world, p_rng, p_emitter, p_sink,
		p_provider, p_limits, p_session)


# Internal: enqueue an event.
func _enqueue(ev) -> void:
	_queue.append(ev)
	# B6.4c: DamageWindowWorkItem counts toward pending_count
	# while in the queue. BattleEvent and other items do not.
	if ev != null and ev.get_script() != null \
			and ev.get_script().get_global_name() == "DamageWindowWorkItem":
		_pending_count += 1


# B6.4c: number of DamageWindowWorkItem instances currently
# in the queue. BattleSimulation asserts this is 0 at end of
# step_tick to detect dangling windows.
func pending_count() -> int:
	return int(_pending_count)


# B6.4c: process a heterogeneous work array. BattleEvent
# items go through the existing FIFO reaction path. Window
# items trigger their pre-damage window, finalize, and
# re-enqueue post-commit work. This is the ONE work pump.
#
# Does NOT recursively call process/process_work.
func process_work(
		p_initial_items: Array,
		p_world,
		p_rng,
		p_emitter,
		p_sink: Array,
		p_provider,
		p_limits: Resource,
		p_session = null) -> RefCounted:
	var using_session: bool = p_session != null
	if using_session:
		_seen = p_session._seen
		_reaction_budget = p_session._reaction_budget
		_queue = []
	else:
		_reset()
		if p_limits == null:
			p_limits = TriggerLimitsScript.new()
	_reset()
	_pending_count = 0
	# Re-attach session aliases AFTER _reset (which clears
	# _seen / _reaction_budget / _queue for the standalone
	# path; the session path re-aliases them).
	if using_session:
		_seen = p_session._seen
		_reaction_budget = p_session._reaction_budget
		_queue = []
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
	if using_session and bool(p_session.truncated):
		result.truncated = true
		result.reason = int(p_session.first_reason)
	var executor = EffectExecutorScript.new()
	for item in p_initial_items:
		_enqueue(item)
	while _queue.size() > 0:
		var item = _queue.pop_front()
		if item == null:
			continue
		# B6.4c window branch: handle DamageWindowWorkItem
		# specially. finalize() emits DAMAGE_APPLIED / UNIT_DIED
		# directly into p_sink. delayed_dispatch_seeds and the
		# direct-reaction outputs go into _queue for the next
		# iterations.
		var item_name: String = ""
		if item.get_script() != null:
			item_name = String(item.get_script().get_global_name())
		if item_name == "DamageWindowWorkItem":
			# B6.4c: the ONE implementation of the pre-damage
			# window state machine. See _process_window_item.
			_process_window_item(
				item, p_world, p_rng, p_emitter, p_sink,
				p_provider, result, executor,
				eff_max_chain, eff_max_reactions_per_root, p_session,
				eff_max_events)
			# Drain pending_count: this work item is done.
			_pending_count = maxi(0, int(_pending_count) - 1)
			continue
		# BattleEvent legacy path
		var ev: BattleEvent = item
		var ev_id: int = int(ev.event_id)
		if (using_session and p_session.has_seen(ev_id)) \
				or (not using_session and _seen.has(ev_id)):
			continue
		var accepted: bool = true
		if using_session:
			accepted = p_session.try_mark(ev_id)
		else:
			if _seen.size() >= eff_max_events:
				accepted = false
			else:
				if not _seen.has(ev_id):
					_seen[ev_id] = true
					accepted = true
				else:
					accepted = false
		if not accepted:
			result.truncated = true
			if result.reason == 0:
				result.reason = int(
					DispatchResultScript.REASON_MAX_EVENTS)
			if using_session and not p_session.truncated:
				p_session.record_truncation(int(
					DispatchResultScript.REASON_MAX_EVENTS))
			break
		var reactions_b: Array = p_provider.discover(p_world, ev, p_rng)
		for reaction in reactions_b:
			if reaction == null or reaction.request == null:
				continue
			var outcome_b: int = _execute_reaction(
				reaction, ev, p_world, p_rng, p_emitter, p_sink,
				executor, result, eff_max_chain, eff_max_reactions_per_root,
				p_session, p_provider)
			# B6.4c: REASON_NONE means success / chance miss /
			# invalid-chance fail-closed / malformed skip. It MUST
			# NOT mark truncation. Truncation happens ONLY for
			# bounded reasons (MAX_DEPTH, MAX_REACTIONS_PER_ROOT,
			# MAX_EVENTS). There is deliberately NO sibling else:
			# an `else: result.truncated = true` here made every
			# ordinary chance miss look truncated.
			if outcome_b != DispatchResultScript.REASON_NONE:
				if using_session and not p_session.truncated:
					p_session.record_truncation(int(outcome_b))
				result.truncated = true
				if result.reason == DispatchResultScript.REASON_NONE:
					result.reason = int(outcome_b)
			elif using_session and p_session.truncated:
				result.truncated = true
				result.reason = int(p_session.first_reason)
	# B6.4c DRAINED-WINDOW INVARIANT (fail-safe).
	#
	# The loop above can break early (MAX_EVENTS cap) with
	# DamageWindowWorkItem entries still queued. Such a window has
	# been OPENED but never finalized: its HP mutation would be
	# SILENTLY LOST, and the battle-level pending_count would not
	# reflect it (it was reset at the top of this call).
	#
	# Every window that was opened MUST be closed. We drain the
	# remaining windows: each is finalized with its CURRENT
	# pending amount (no modifiers — discovery is already
	# bounded) so the damage is applied exactly once and the
	# window is closed.
	#
	# The drain LOOPS: finalizing a leftover window can itself
	# enqueue another window (a reaction inside that window that
	# opens a nested damage window). A single pass would leave
	# that nested window queued and it would be discarded by the
	# next process_work() call — its damage silently lost. The
	# loop closes that hole.
	#
	# Post-commit DISCOVERY of those windows stays deferred: the
	# pump has already reported truncation, and re-entering the
	# discovery path would exceed the very cap that stopped us.
	var drained_windows: int = 0
	while true:
		var leftover_windows: Array = []
		for item in _queue:
			if item == null or item.get_script() == null:
				continue
			if String(item.get_script().get_global_name()) \
					== "DamageWindowWorkItem":
				leftover_windows.append(item)
		if leftover_windows.is_empty():
			break
		for w in leftover_windows:
			_process_window_item(
				w, p_world, p_rng, p_emitter, p_sink,
				p_provider, result, executor,
				eff_max_chain, eff_max_reactions_per_root, p_session)
			drained_windows += 1
		# The drained windows are closed; remove them from the
		# queue so they cannot be finalized a second time.
		for w in leftover_windows:
			_queue.erase(w)
	if drained_windows > 0:
		# The drain is a bounded-execution completion: the windows
		# are closed, but their post-commit discovery is NOT run.
		result.truncated = true
		if int(result.reason) == 0:
			result.reason = int(
				DispatchResultScript.REASON_MAX_EVENTS)
	# The counter must reflect what is STILL queued, not the
	# arithmetic of this call: a window enqueued by a drained
	# window's reaction must still be visible to the caller.
	_pending_count = 0
	for item in _queue:
		if item != null and item.get_script() != null \
				and String(item.get_script().get_global_name()) \
				== "DamageWindowWorkItem":
			_pending_count += 1
	return result


# ============================================================
# B6.4c — the ONE pre-damage window state machine.
#
# Called from the single canonical work pump when a
# DamageWindowWorkItem is popped. It:
#   1. discovers direct reactions on DAMAGE_STARTED and runs
#      them in COLLECTOR mode (their dispatch_work is collected,
#      not enqueued yet);
#   2. finalizes the window (HP mutation + DAMAGE_APPLIED /
#      UNIT_DIED allocation);
#   3. enqueues the post-commit FIFO: delayed seeds, collected
#      work, finalize-emitted.
#
# IMPORTANT: the sibling-reaction ordering contract.
#
# Legacy a5dd87d executed a damage-producing reaction
# SYNCHRONOUSLY: it mutated HP before the NEXT sibling
# reaction on the same event was even admitted. A sibling
# reaction therefore observed the POST-damage world state, and
# a reaction whose target had just died was rejected by the
# is_alive() pre-guard (no ATTACK_RESOLVED was published).
#
# B6.4c splits intent from commit (DAMAGE_STARTED /
# DAMAGE_APPLIED). To preserve legacy world-state semantics,
# the window that a reaction opened must be COMPLETE (its HP
# mutation done) before the NEXT sibling reaction on the same
# event is admitted.
#
# This is achieved WITHOUT a second pump and WITHOUT recursion:
# the reaction execution path, when it opens a window, drives
# the window to completion inline via _process_window_item and
# then continues with the next sibling. Post-commit DISCOVERY
# (the delayed seeds / finalize-emitted) stays in the canonical
# FIFO and may be drained later.
# ============================================================
func _process_window_item(
		p_item,
		p_world, p_rng, p_emitter, p_sink: Array,
		p_provider,
		p_result: RefCounted,
		p_executor,
		p_max_chain_depth: int, p_max_reactions_per_root: int,
		p_session,
		p_max_events: int = 0) -> void:
	var using_session: bool = p_session != null
	# B6.4c MAX_EVENTS policy at work-item level: if the
	# event budget is already spent, finalize the window with
	# the current pending amount and skip discovery.
	#
	# The cap MUST be checked in BOTH paths. The session path uses
	# the session's own counter; the no-session path uses the
	# dispatcher's seen-set, exactly like the ordinary BattleEvent
	# branch does. Checking only the session made a capped run
	# behave differently depending on whether a session was passed:
	# the no-session path kept discovering and executing reactions
	# after the budget was spent.
	var budget_spent: bool = false
	if using_session:
		budget_spent = bool(p_session.cap_reached())
	else:
		budget_spent = _seen.size() >= int(p_max_events)
	if budget_spent:
		# B6.4c: the bounded execution MUST be reported, not
		# silent. The window is finalized with the current pending
		# amount and discovery is skipped, but the caller has to
		# learn that the MAX_EVENTS cap was hit.
		#
		# Before this fix the window path silently finalized
		# without setting result.truncated / result.reason, so a
		# capped run looked identical to an uncapped one.
		p_result.truncated = true
		if int(p_result.reason) == 0:
			p_result.reason = int(
				DispatchResultScript.REASON_MAX_EVENTS)
		if using_session and not bool(p_session.truncated):
			p_session.record_truncation(int(
				DispatchResultScript.REASON_MAX_EVENTS))
		# The window MUST still finalize: the pending damage is
		# committed as it stands and the window is closed, so no
		# pending damage is leaked and no window dangles.
		# Discovery, modifier execution and RNG draws are skipped.
		var fr_pre = p_item.continuation.finalize(
			p_world, p_sink, p_emitter)
		if fr_pre != null:
			for ev in fr_pre.emitted:
				p_result.events.append(ev)
		for ev in p_item.delayed_dispatch_seeds:
			_enqueue(ev)
		return
	# Normal path: discover direct reactions on DAMAGE_STARTED,
	# run them in collector mode.
	var dmg_started: BattleEvent = p_item.event
	var dmg_id: int = int(dmg_started.event_id)
	if using_session:
		p_session.try_mark(dmg_id)
	else:
		_seen[dmg_id] = true
	var window_collected_work: Array = []
	var reactions: Array = p_provider.discover(
		p_world, dmg_started, p_rng)
	for reaction in reactions:
		if reaction == null or reaction.request == null:
			continue
		var outcome: int = _execute_reaction_window(
			reaction, dmg_started, p_world, p_rng, p_emitter,
			p_sink, p_executor, p_result, p_provider,
			p_max_chain_depth,
			p_max_reactions_per_root, p_session,
			p_item.handle, window_collected_work)
		if outcome != DispatchResultScript.REASON_NONE:
			if using_session and not p_session.truncated:
				p_session.record_truncation(int(outcome))
			p_result.truncated = true
			if p_result.reason == DispatchResultScript.REASON_NONE:
				p_result.reason = int(outcome)
			break
	# Finalize the window. This is the HP mutation point.
	var fr = p_item.continuation.finalize(
		p_world, p_sink, p_emitter)
	if fr != null:
		for ev in fr.emitted:
			p_result.events.append(ev)
	# Post-commit FIFO order:
	#   1. delayed_dispatch_seeds (already-public events whose
	#      DISCOVERY is delayed until after commit)
	#   2. window_collected_work (downstream work from direct
	#      reactions that fired in the window)
	#   3. finalize_result.emitted (DAMAGE_APPLIED / UNIT_DIED,
	#      freshly allocated by finalize)
	for ev in p_item.delayed_dispatch_seeds:
		_enqueue(ev)
	for ev in window_collected_work:
		_enqueue(ev)
	if fr != null:
		for ev in fr.emitted:
			_enqueue(ev)


# B6.4c window-mode execution of a single direct reaction.
# Collector mode: the result's dispatch_work is collected
# into p_collected_work instead of being enqueued. Public
# events are still appended to p_sink and result.events.
# p_handle is the active window handle; wctx is built locally
# with ctx.damage_window = p_handle so direct reactions can
# read/modify the pending damage.
func _execute_reaction_window(
		p_reaction,
		p_triggering_event,
		p_world, p_rng, p_emitter, p_sink: Array,
		p_executor, p_result: RefCounted,
		p_provider,
		p_max_chain_depth: int, p_max_reactions_per_root: int,
		p_session,
		p_handle,
		p_collected_work: Array) -> int:
	var root_id: int = int(p_triggering_event.root_action_id)
	var used: int
	if p_session != null:
		used = int(p_session.used_budget_for(root_id))
	else:
		used = int(_reaction_budget.get(root_id, 0))
	var req = EffectRequestScript.child_from_template(
		p_reaction.request, p_triggering_event)
	if req == null:
		return DispatchResultScript.REASON_NONE
	if int(req.chain_depth) > int(p_max_chain_depth):
		return DispatchResultScript.REASON_MAX_DEPTH
	if used >= int(p_max_reactions_per_root):
		return DispatchResultScript.REASON_MAX_REACTIONS_PER_ROOT
	var chance: float = float(p_reaction.trigger_chance)
	if is_nan(chance) or is_inf(chance) \
			or chance < 0.0 or chance > 1.0:
		return DispatchResultScript.REASON_NONE
	var hit: bool = false
	if chance >= 1.0:
		hit = true
	elif chance <= 0.0:
		hit = false
	else:
		var roll: float = float(p_rng.randf())
		hit = roll < chance
	if not hit:
		return DispatchResultScript.REASON_NONE
	var new_used: int = used + 1
	if p_session != null:
		p_session._reaction_budget[root_id] = new_used
	else:
		_reaction_budget[root_id] = new_used
	p_result.reactions_executed += 1
	# Build wctx locally with damage_window set. This is the
	# ONLY mechanism by which direct window reactions access
	# the live transaction.
	var wctx = EffectContextScript.new(p_world, p_rng, p_emitter, p_sink)
	wctx._set_damage_window_for_window_reaction(p_handle)
	var exec_result = p_executor.execute(wctx, req)
	if exec_result == null:
		return DispatchResultScript.REASON_NONE
	# Collector mode: append public events to result and sink
	# normally, but COLLECT the downstream dispatch work
	# instead of immediately enqueueing.
	for emitted in exec_result.events:
		p_result.events.append(emitted)
	# p_sink appends happen inside execute() through
	# ctx.emit_through_sink, but if the effect bypassed that
	# helper, ensure public events are in p_sink too.
	for emitted in exec_result.events:
		if not p_sink.has(emitted):
			p_sink.append(emitted)
	# B6.4c WINDOW-PATH SIBLING ORDERING (regression fix).
	#
	# The sibling-ordering contract requires that a sibling
	# observes all synchronous commits of the PREVIOUS siblings.
	# The legacy path (_execute_reaction) honours it by driving a
	# window-opening sibling's window INLINE.
	#
	# The window path used to COLLECT the sibling's dispatch_work
	# and enqueue it only AFTER the outer window finalizes — so a
	# sibling that opened a nested damage window had that nested
	# window commit LATE, and the NEXT sibling observed the
	# PRE-commit world (no room for a heal, an extra attack
	# intent, ...).
	#
	# Here the nested window is driven INLINE, exactly like the
	# legacy path: its HP mutation completes before the next
	# sibling is admitted. The nested window's own POST-COMMIT
	# discovery (delayed seeds, collected work, finalize-emitted)
	# stays in the collector and is enqueued after the outer
	# window finalizes, which is the canonical FIFO order.
	for dw in exec_result.dispatch_work:
		if dw == null or dw.get_script() == null:
			p_collected_work.append(dw)
			continue
		if String(dw.get_script().get_global_name()) \
				!= "DamageWindowWorkItem":
			p_collected_work.append(dw)
			continue
		# Drive the nested window to completion inline.
		_process_window_item(
			dw, p_world, p_rng, p_emitter, p_sink,
			p_provider, p_result, p_executor,
			p_max_chain_depth, p_max_reactions_per_root, p_session)
	return DispatchResultScript.REASON_NONE


# Internal: execute one reaction; returns REASON_NONE on
# success or a REASON_* limit constant if the reaction was
# rejected. AT COMMIT TIME: appends every emitted event to
# BOTH result.events AND the queue.
#
# B6.4a chance admission. Gate order is normative:
#   1. validate template presence (null check)
#   2. build EffectRequest via child_from_template (may be null
#      -> rejected with REASON_NONE, no budget change)
#   3. check chain_depth limit (REASON_MAX_DEPTH)
#   4. peek per-root budget (REASON_MAX_REACTIONS_PER_ROOT)
#      SAFETY BOUNDS WIN BEFORE CHANCE: zero chance draws.
#   5. validate trigger_chance metadata (fail-closed for
#      NaN/+/-Inf or out-of-domain). REASON_NONE on invalid.
#   6. chance gate:
#        chance == 1.0 -> guaranteed admit, zero draws
#        chance == 0.0 -> guaranteed miss, zero draws
#        0 < chance < 1 -> exactly one randf() draw
#                         hit iff roll < chance
#   7. ONLY ON HIT:
#        consume budget slot
#        increment reactions_executed
#        execute EffectExecutor
#   8. publish committed events normally
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
		p_session = null,
		p_provider = null) -> int:
	# Per-root reaction budget PEEK (do not mutate until hit).
	var root_id: int = int(p_triggering_event.root_action_id)
	var used: int
	if p_session != null:
		used = int(p_session.used_budget_for(root_id))
	else:
		used = int(_reaction_budget.get(root_id, 0))
	# Build EffectRequest from template.
	var req = EffectRequestScript.child_from_template(
		p_reaction.request,
		p_triggering_event)
	if req == null:
		# Malformed template. NO budget mutation. NO chance draw.
		return DispatchResultScript.REASON_NONE

	# Depth limit: REJECT BEFORE mutation.
	if int(req.chain_depth) > int(p_max_chain_depth):
		# NO budget mutation. NO chance draw.
		return DispatchResultScript.REASON_MAX_DEPTH

	# Per-root budget PEEK: reject BEFORE chance gate.
	# Safety bounds win before chance.
	if used >= int(p_max_reactions_per_root):
		# NO budget mutation. NO chance draw.
		return DispatchResultScript.REASON_MAX_REACTIONS_PER_ROOT

	# B6.4a: validate trigger_chance metadata fail-closed.
	# Reject NaN / +/-Inf / out-of-domain without RNG draw.
	var chance: float = float(p_reaction.trigger_chance)
	if is_nan(chance) or is_inf(chance) \
			or chance < 0.0 or chance > 1.0:
		# Invalid chance: skip silently. NO budget mutation.
		# NO chance draw.
		return DispatchResultScript.REASON_NONE

	# B6.4a chance gate.
	# chance == 1.0 -> guaranteed admit, ZERO draws.
	# chance == 0.0 -> guaranteed miss, ZERO draws.
	# 0 < chance < 1 -> exactly one randf() draw.
	var hit: bool = false
	if chance >= 1.0:
		hit = true
	elif chance <= 0.0:
		hit = false
	else:
		var roll: float = float(p_rng.randf())
		hit = roll < chance
	if not hit:
		# Chance miss. NO budget mutation. NO executor call.
		# NO committed events. NOT truncation.
		return DispatchResultScript.REASON_NONE

	# ON HIT: consume budget slot, increment reactions_executed.
	var new_used: int = used + 1
	if p_session != null:
		p_session._reaction_budget[root_id] = new_used
	else:
		_reaction_budget[root_id] = new_used
	p_result.reactions_executed += 1

	# B6.4c contract (FINAL): the work-pump channels are STRICTLY
	# separated. Failure to keep them separated creates the
	# recurrent-timing bug we built B6.4c to eliminate.
	#
	#   events          = public synchronous events, observable
	#                    to callers. NOT enqueued for future
	#                    trigger discovery. Going to result.events
	#                    ONLY.
	#   dispatch_work   = the SOLE channel that drives future
	#                    trigger discovery. Going to queue ONLY.
	#                    Window work items (e.g.
	#                    DamageWindowWorkItem) live here, NOT in
	#                    events. Pre-damage window for reaction-
	#                    origin attacks depends on this contract:
	#                    the work item gates discovery until
	#                    finalize() commits.
	#
	# Legacy effects (HEAL, APPLY_STATUS, etc.) have
	# dispatch_work == events.duplicate() (set by
	# EffectResult.succeeded default). They are enqueued ONCE
	# via the dispatch_work path. No double-dispatch.
	#
	# Window-opening effects (PerformAttack, DamageEffect) have
	# events == [ATK, DMG_STARTED] and dispatch_work ==
	# [WindowWorkItem]. Only the work item is enqueued. The
	# public events stay out of the FIFO so reaction discovery
	# for them is controlled by the window handler.
	#
	# Critically: NEVER _enqueue() from exec_result.events.
	var ctx = EffectContextScript.new(p_world, p_rng, p_emitter, p_sink)
	var exec_result = p_executor.execute(ctx, req)
	if exec_result == null:
		return DispatchResultScript.REASON_NONE
	for emitted in exec_result.events:
		p_result.events.append(emitted)
	if exec_result.dispatch_work != null:
		for w in exec_result.dispatch_work:
			# B6.4c SIBLING-REACTION ORDERING.
			#
			# Legacy a5dd87d executed a damage-producing reaction
			# SYNCHRONOUSLY: it mutated HP before the NEXT
			# sibling reaction on the same event was admitted. A
			# sibling therefore observed the POST-damage world
			# state, and a reaction whose target had just died
			# was rejected by the is_alive() pre-guard — its
			# ATTACK_RESOLVED was NEVER published.
			#
			# B6.4c splits intent from commit, so the window
			# this reaction opened is not yet finalized when the
			# next sibling is admitted. To preserve legacy
			# world-state semantics we complete the window
			# INLINE here (same pump, no recursion, no second
			# dispatcher): the HP mutation and the
			# DAMAGE_APPLIED / UNIT_DIED allocation happen
			# BEFORE the next sibling reaction is admitted.
			#
			# Post-commit DISCOVERY (delayed seeds, collected
			# work, finalize-emitted) stays in the canonical
			# FIFO and is drained by the pump's next
			# iterations — it does NOT need to precede the
			# sibling.
			if w != null and w.get_script() != null \
					and String(w.get_script().get_global_name()) \
					== "DamageWindowWorkItem" \
					and p_provider != null:
				_process_window_item(
					w, p_world, p_rng, p_emitter, p_sink,
					p_provider, p_result, p_executor,
					p_max_chain_depth, p_max_reactions_per_root,
					p_session)
				continue
			_enqueue(w)
	return DispatchResultScript.REASON_NONE
