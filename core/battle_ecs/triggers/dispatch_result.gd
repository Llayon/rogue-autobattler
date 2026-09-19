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
