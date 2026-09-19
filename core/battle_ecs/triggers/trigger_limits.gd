class_name TriggerLimits extends Resource
## B5 / Phase-3 / TriggerLimits — immutable hard limits for
## the bounded TriggerDispatcher.
##
## These are SAFETY BOUNDARIES, not tuning knobs. Defaults are
## production values; tests inject smaller values via the
## TriggerDispatcher constructor to keep the suite fast.

const DEFAULT_MAX_CHAIN_DEPTH: int = 32
const DEFAULT_MAX_EVENTS_PER_TICK: int = 10000
const DEFAULT_MAX_REACTIONS_PER_ROOT: int = 256

var max_chain_depth: int = DEFAULT_MAX_CHAIN_DEPTH
var max_events_per_tick: int = DEFAULT_MAX_EVENTS_PER_TICK
var max_reactions_per_root: int = DEFAULT_MAX_REACTIONS_PER_ROOT


func _init(
		p_max_chain_depth: int = DEFAULT_MAX_CHAIN_DEPTH,
		p_max_events_per_tick: int = DEFAULT_MAX_EVENTS_PER_TICK,
		p_max_reactions_per_root: int = DEFAULT_MAX_REACTIONS_PER_ROOT) -> void:
	max_chain_depth = p_max_chain_depth
	max_events_per_tick = p_max_events_per_tick
	max_reactions_per_root = p_max_reactions_per_root
