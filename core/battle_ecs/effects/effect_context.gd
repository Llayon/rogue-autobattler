class_name EffectContext extends RefCounted
## Phase 3 / EffectContext — runtime environment passed to every
## effect execution.
##
## Holds:
##   - BattleWorld (mutate state through it)
##   - DeterministicRng (any random effect must use this)
##   - BattleEventEmitter (central event allocator / factory)
##   - An Array sink for COMMITTED events the caller wants to
##     observe externally. Effects still return the BattleEvent
##     objects they emit through their EffectResult. The sink is
##     a convenience for tests / snapshot output.
##   - B6.4c: an optional DamageWindowHandle. Set ONLY when this
##     effect is being executed as a DIRECT pre-damage reaction
##     discovered from a DAMAGE_STARTED work item. Outside that
##     context, damage_window is null.
##
## EffectContext does NOT expose RunDomain, Node, or scene
## references. Effects cannot reach outside the battle spine.

var _world = null
var _rng = null
var _emitter = null
var _sink: Array = []
var _damage_window = null


func _init(p_world, p_rng, p_emitter, p_sink: Array = []) -> void:
	_world = p_world
	_rng = p_rng
	_emitter = p_emitter
	_sink = p_sink
	_damage_window = null


## Returns the BattleWorld (RefCounted).
func world() -> RefCounted:
	return _world


## Returns the simulation-owned DeterministicRng.
func rng() -> RefCounted:
	return _rng


## Returns the BattleEventEmitter. Effects call ctx.emitter().emit()
## to construct events. This is the ONLY event ID allocator.
func emitter() -> RefCounted:
	return _emitter


## Returns the underlying event sink array. Mutations to the
## returned array propagate to the caller. The sink is for
## caller-side observation; it is NOT an event identity authority.
func event_sink() -> Array:
	return _sink


## Convenience: emit a BattleEvent through the emitter AND append
## it to the sink. Effects should prefer this helper when they
## want a one-step "construct + publish" path. Returns the
## constructed BattleEvent.
func emit_through_sink(ev) -> RefCounted:
	if ev != null:
		_sink.append(ev)
	return ev


## B6.4c: returns the active DamageWindowHandle, or null if this
## effect is not being executed inside a pre-damage window.
func damage_window():
	return _damage_window


## B6.4c: BATTLE-SIMULATION-OWNED setter. Only the work-pump
## sets this when constructing an EffectContext for a direct
## pre-damage reaction. Never set by an effect.
func _set_damage_window_for_window_reaction(p_handle) -> void:
	_damage_window = p_handle