class_name DamageWindowWorkItem extends RefCounted
##
## One work item per active pre-damage window. Owned by the
## TriggerDispatcher FIFO alongside BattleEvents.
##
## Pairing is STRUCTURAL: each work item carries its own event,
## continuation, and handle. No parallel-array index matching
## required.
##
## delayed_dispatch_seeds contains events that have already been
## emitted into the public trace, but whose reaction-dispatch
## should be DEFERRED until after the window commits. Set by the
## effect or phase that created this work item:
##   - PerformAttackEffect: [ATTACK_RESOLVED]
##   - PeriodicStatusProcessor after Burn: [STATUS_TICKED]
##   - Direct ROOT DamageEffect: []
##   - DamageEffect spawned from a reaction: []
##     (its triggering parent is already in the active FIFO)
##
## These seeds are NOT re-emitted into the public trace by the
## dispatcher. They are only re-enqueued for reaction discovery
## AFTER finalize().

var event: BattleEvent  # the DAMAGE_STARTED
var continuation = null
var handle = null
var delayed_dispatch_seeds: Array = []


func _init(p_event: BattleEvent, p_continuation, p_handle,
		p_delayed_seeds: Array = []) -> void:
	event = p_event
	continuation = p_continuation
	handle = p_handle
	delayed_dispatch_seeds = p_delayed_seeds