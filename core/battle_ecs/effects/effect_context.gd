class_name EffectContext extends RefCounted
## Phase 3 / EffectContext — read/write access for effect
## execution.
##
## Holds:
##   - BattleWorld (mutate state through it)
##   - DeterministicRng (any random effect must use this)
##   - Array sink for emitted events (NOT a Node)
##
## EffectContext does NOT expose RunDomain, Node, or scene
## references. Effects cannot reach outside the battle spine.

var _world = null
var _rng = null
var _sink: Array = []


func _init(p_world, p_rng, p_sink: Array) -> void:
	_world = p_world
	_rng = p_rng
	_sink = p_sink


## Returns the BattleWorld (RefCounted).
func world() -> RefCounted:
	return _world


## Returns the simulation-owned DeterministicRng.
func rng() -> RefCounted:
	return _rng


## Returns the underlying event sink array. Mutations to the
## returned array propagate to the caller.
func event_sink() -> Array:
	return _sink


## Appends a single event Dictionary to the underlying sink.
## Effects emit logical events as Dictionaries with at least:
##   { type, tick, source_entity, target_entity, amount, ... }
func emit(event: Dictionary) -> void:
	_sink.append(event)
