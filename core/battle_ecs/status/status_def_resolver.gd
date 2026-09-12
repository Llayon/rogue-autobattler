extends RefCounted
## Phase 3 / B1 / StatusDefResolver — resolves a StatusDef by its
## content id, using the existing ContentDB indexing path.
##
## Architectural rules (B1):
##   - StatusDef is content definition (immutable Resource).
##   - StatusInstance is runtime state (mutable).
##   - ApplyStatusEffect MUST resolve a StatusDef before
##     mutating state. Unknown status_id fails safely.
##   - Definition data is NEVER mutated by runtime state.
##
## This resolver wraps the existing ContentDB_static API. It does
## NOT introduce a second registry. If ContentDB is not loaded
## yet, it triggers ensure_loaded() automatically.

const ContentDBScript = preload("res://core/utils/content_db.gd")
const StatusDefScript = preload("res://core/data/status_def.gd")


## Returns the StatusDef for the given id, or null if not found.
## This is the canonical content lookup path.
static func resolve(status_id: StringName) -> Resource:
	if status_id == &"":
		return null
	ContentDBScript.ensure_loaded()
	var res: Resource = ContentDBScript.get_by_id(status_id)
	if res == null:
		return null
	# Confirm the resource is a StatusDef (defensive: caller
	# could pass any StringName).
	if res.get_script() != StatusDefScript:
		return null
	return res


## True iff a StatusDef exists for the given id.
static func has(status_id: StringName) -> bool:
	return resolve(status_id) != null


## Converts a StatusDef.duration (float seconds) into integer
## tick units. Phase 3 runtime unit: 1 simulation tick = 1 unit.
##
## Validation rule:
##   - Exact integer values (e.g. 5.0) are accepted.
##   - Non-integral values (e.g. 5.5) are REJECTED with an
##     explicit failure (returns -1). Fractional-tick semantics
##     are deferred to a later phase.
##   - Non-positive durations (e.g. 0.0 or -1.0) map to the
##     indefinite sentinel (-1) and are accepted.
static func convert_duration_to_ticks(p_duration: float) -> int:
	if p_duration < 0.0:
		return -1  # indefinite
	if p_duration == 0.0:
		return -1  # explicit "no duration"
	# Accept ONLY exact integer floats.
	if p_duration != floor(p_duration):
		return -1  # fractional — rejected for Phase 3
	return int(p_duration)
