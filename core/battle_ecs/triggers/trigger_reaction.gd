class_name TriggerReaction extends RefCounted
## B5 / Phase-3 / TriggerReaction — value carrier for one
## trigger reaction.
##
## A reaction describes:
##   - which EffectRequest to execute
##   - on which reacting entity (may be -1 for global reactions)
##
## The dispatcher fills these in by calling
## EffectRequest.child_from_parent(triggering_event, ...) so
## ancestry is derived from the actual triggering BattleEvent.
##
## No methods. Pure data.

var reacting_entity: int = -1
var kind: String = ""
var request: EffectRequest = null
