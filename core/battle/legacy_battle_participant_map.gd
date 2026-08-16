class_name LegacyBattleParticipantMap extends RefCounted
## Battle-lifetime mapping between transient legacy Combatant references
## and stable RunUnit instance ids.
##
## Phase 1 / T3E.
##
## This bridge exists for ONE reason: in T3F, when RunController
## stops carrying a frozen RunState Resource and starts carrying
## RunDomainState, the legacy Combatant still only knows
## `definition_id` and its own runtime state. To write the battle
## result back into the right RunUnit after the battle, we need a
## side-table keyed by Combatant reference and RunUnit.instance_id.
##
## This bridge is NOT an identity system. It is a transient
## lookup table scoped to a single battle. After the battle ends,
## the caller MUST `clear()` it. The bridge is not serialised,
## not stored on disk, not in the v4 DTO, not on RunDomainState.
## When the legacy battle backend is removed, this entire file is
## deleted in one piece.
##
## Canonical identity remains `RunUnit.instance_id`. The Combatant
## reference here is a transient key, no more.
##
## Invariants enforced by `bind`:
##   - one Combatant -> at most one RunUnit instance id
##   - one RunUnit instance id -> at most one Combatant
##   - empty / null inputs are rejected (no silent overwrites)
##   - duplicate bindings are rejected (no fallback to def_id,
##     no fallback to board index)

const ERR_NONE: int = 0
const ERR_ALREADY_BOUND_TO_SAME_COMBATANT: int = 1
const ERR_ALREADY_BOUND_TO_SAME_RUN_UNIT: int = 2
const ERR_NULL_COMBATANT: int = 3
const ERR_EMPTY_RUN_UNIT_INSTANCE_ID: int = 4


var _combatant_to_run_unit: Dictionary = {}
var _run_unit_to_combatant: Dictionary = {}
var _last_error: int = ERR_NONE


## Returns the most recent error code from a failed `bind()`.
## Reset to `ERR_NONE` on every successful bind. Useful for
## diagnostics in the caller.
func get_last_error() -> int:
	return _last_error


## Binds `combatant` to `run_unit_instance_id`. Both sides of the
## one-to-one map are updated atomically. If either side is
## already bound, the call is rejected with no state mutation and
## `get_last_error()` returns the corresponding code.
func bind(combatant: Object, run_unit_instance_id: String) -> bool:
	if combatant == null:
		_last_error = ERR_NULL_COMBATANT
		return false
	if run_unit_instance_id == "":
		_last_error = ERR_EMPTY_RUN_UNIT_INSTANCE_ID
		return false
	# One Combatant -> at most one RunUnit instance id.
	if _combatant_to_run_unit.has(combatant):
		_last_error = ERR_ALREADY_BOUND_TO_SAME_COMBATANT
		return false
	# One RunUnit instance id -> at most one Combatant.
	if _run_unit_to_combatant.has(run_unit_instance_id):
		_last_error = ERR_ALREADY_BOUND_TO_SAME_RUN_UNIT
		return false
	_combatant_to_run_unit[combatant] = run_unit_instance_id
	_run_unit_to_combatant[run_unit_instance_id] = combatant
	_last_error = ERR_NONE
	return true


## Returns the RunUnit instance id bound to `combatant`, or `""`
## if the combatant is unknown. Returns `""` for null / non-Object
## inputs (never raises). An empty result is a diagnostic signal
## for the caller — it means the participant was not registered
## before the battle, or the battle lifetime ended and the bridge
## was cleared.
func get_run_unit_id(combatant: Object) -> String:
	if combatant == null:
		return ""
	if not _combatant_to_run_unit.has(combatant):
		return ""
	return String(_combatant_to_run_unit[combatant])


## Returns the Combatant bound to `run_unit_instance_id`, or
## `null` if the instance id is unknown. Returns null for empty /
## null inputs (never raises).
func get_combatant(run_unit_instance_id: String) -> Object:
	if run_unit_instance_id == "":
		return null
	if not _run_unit_to_combatant.has(run_unit_instance_id):
		return null
	return _run_unit_to_combatant[run_unit_instance_id]


## Returns true if `combatant` is currently bound.
func has_combatant(combatant: Object) -> bool:
	if combatant == null:
		return false
	return _combatant_to_run_unit.has(combatant)


## Returns true if `run_unit_instance_id` is currently bound.
func has_run_unit(run_unit_instance_id: String) -> bool:
	if run_unit_instance_id == "":
		return false
	return _run_unit_to_combatant.has(run_unit_instance_id)


## Returns the number of bound pairs on each side. Both sides must
## always be equal.
func size() -> int:
	return _combatant_to_run_unit.size()


## Removes every binding. Battle-lifetime only: after the battle
## is over, the caller MUST clear the bridge. There is no
## `unbind_single` because the bridge is intentionally
## all-or-nothing — partial state would be a leak.
func clear() -> void:
	_combatant_to_run_unit.clear()
	_run_unit_to_combatant.clear()
	_last_error = ERR_NONE