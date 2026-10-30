class_name EffectResult extends RefCounted
## Phase 3 / EffectResult — explicit success/failure + events
## emitted by one effect execution.
##
## Effect chain logic uses `success` and `continues_chain`. The
## caller (TriggerDispatcher) decides what to do with a failure.
##
## Exceptions are NOT used as normal combat control flow. Failed
## effects return EffectResult with success=false and a `reason`.
##
## B6.4c: dispatch_work splits "public synchronous events" from
## "work items the caller must hand to the dispatcher". For
## ordinary (non-window) effects, dispatch_work defaults to
## events.duplicate() to preserve the legacy contract where each
## emitted event is automatically re-fed into the reaction FIFO.
## Window-opening effects (PerformAttack, DamageEffect) use
## `succeeded_with_work` to override dispatch_work with explicit
## work items (e.g. DamageWindowWorkItem).

var success: bool = true
var reason: String = ""
var events: Array = []
## Work items the dispatcher must feed into its FIFO. Default =
## events.duplicate() for backward compatibility. Window-opening
## effects may use succeeded_with_work to override this with
## DamageWindowWorkItem or other non-Event items.
var dispatch_work: Array = []
var continues_chain: bool = false


func _init(p_success: bool, p_reason: String, p_events: Array,
		p_dispatch_work, p_continues_chain: bool) -> void:
	success = p_success
	reason = String(p_reason)
	events = p_events
	# Default-rule: the caller signals its intent by null-ness:
	#   p_dispatch_work == null  -> LEGACY default. For success
	#     that is events.duplicate() (each ordinary emitted event
	#     goes back into the reaction FIFO exactly once).
	#   p_dispatch_work == []    -> EXPLICIT "no further dispatch".
	#     A window-opening effect that published its public
	#     events and wants NO re-dispatch must be able to say so.
	#     This is why the check is null-ness, NOT size(): an
	#     explicit empty array must stay empty.
	#   p_dispatch_work == [W]   -> explicit work items.
	#
	# B6.4c: the previous single-expression ternary chain was
	# right-associative and evaluated as
	#   (explicit) if (explicit non-empty)
	#   else (events.duplicate()) if (NOT success) else []
	# which returned [] for SUCCESSFUL ordinary effects — they
	# never re-entered the FIFO. Written explicitly here.
	if p_dispatch_work != null:
		dispatch_work = p_dispatch_work.duplicate()
	elif bool(p_success):
		dispatch_work = p_events.duplicate()
	else:
		dispatch_work = []
	continues_chain = p_continues_chain


## Constructs a successful EffectResult with the given events.
## dispatch_work defaults to events.duplicate() (legacy contract).
##
## B6.4c: the null-vs-empty distinction is load-bearing.
## Passing null means "use the legacy default" (events.duplicate()).
## Passing [] means "explicitly no further dispatch".
static func succeeded(events: Array, continues_chain: bool = false) -> EffectResult:
	return EffectResult.new(true, "", events, null, continues_chain)


## Constructs a successful EffectResult with explicit dispatch_work.
## The caller may provide a different list (e.g. window work
## items that are NOT public events). An explicit [] means
## "no further dispatch at all" and is honoured verbatim.
static func succeeded_with_work(events: Array, dispatch_work: Array,
		continues_chain: bool = false) -> EffectResult:
	return EffectResult.new(true, "", events, dispatch_work, continues_chain)


## Constructs a failed EffectResult. `reason` describes why.
## dispatch_work is always [] (failed effects do not enqueue).
static func failed(reason: String, events: Array = [],
		continues_chain: bool = false) -> EffectResult:
	return EffectResult.new(false, String(reason), events, [], continues_chain)