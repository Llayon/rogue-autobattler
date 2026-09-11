class_name EffectResult extends RefCounted
## Phase 3 / EffectResult — explicit success/failure + events
## emitted by one effect execution.
##
## Effect chain logic uses `success` and `continues_chain`. The
## caller (TriggerDispatcher) decides what to do with a failure.
##
## Exceptions are NOT used as normal combat control flow. Failed
## effects return EffectResult with success=false and a `reason`.

var success: bool = true
var reason: String = ""
var events: Array = []
var continues_chain: bool = false


func _init(p_success: bool, p_reason: String, p_events: Array, p_continues_chain: bool) -> void:
	success = p_success
	reason = String(p_reason)
	events = p_events
	continues_chain = p_continues_chain


## Constructs a successful EffectResult with the given events.
static func succeeded(events: Array, continues_chain: bool = false) -> EffectResult:
	return EffectResult.new(true, "", events, continues_chain)


## Constructs a failed EffectResult. `reason` describes why.
static func failed(reason: String, events: Array = [], continues_chain: bool = false) -> EffectResult:
	return EffectResult.new(false, String(reason), events, continues_chain)
