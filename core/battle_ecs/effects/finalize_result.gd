class_name FinalizeResult extends RefCounted
##
## Tiny result carrier returned by DamageWindowContinuation.finalize.
## Carries the events that were emitted into the canonical sink
## during finalize. The dispatcher reads this to build the
## post-commit FIFO order.
##
## Owns NO additional state. The delayed_dispatch_seeds belong to
## DamageWindowWorkItem, not here (single ownership).

var emitted: Array = []


func _init(p_emitted: Array = []) -> void:
	emitted = p_emitted