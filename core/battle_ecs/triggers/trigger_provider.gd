class_name TriggerProvider extends RefCounted
## B5 / Phase-3 / TriggerProvider — pure discovery interface for
## the TriggerDispatcher.
##
## Implementations read committed BattleEvents + BattleWorld and
## return an ORDERED list of TriggerReaction specs. The list
## order IS the reaction execution order for that event (1:
## reacting entity battle id, 2: trigger insertion order).
##
## Implementations MUST NOT mutate world, RNG, emitter, or
## events. Mutation belongs to EffectExecutor.
##
## Default: no reactions.

func discover(
		p_world,
		p_event,
		p_rng) -> Array:
	return []
