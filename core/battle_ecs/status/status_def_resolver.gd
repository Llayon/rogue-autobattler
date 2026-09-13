extends RefCounted
## Phase 3 / B1.1 / StatusDefResolver — resolves a StatusDef by its
## content id, using the existing ContentDB indexing path.
##
## Architectural rules (B1):
##   - StatusDef is content definition (immutable Resource).
##   - StatusInstance is runtime state (mutable).
##   - ApplyStatusEffect MUST resolve a StatusDef before
##     mutating state. Unknown status_id fails safely.
##   - Definition data is NEVER mutated by runtime state.
##
## B1.1 duration validation:
##   - StatusDef.duration is a float. Three distinct semantics:
##       TIMED:    duration > 0 AND exact integral float (5.0, 1.0)
##                 -> converts to integer ticks (5, 1)
##       INSTANT:  duration == 0
##                 -> canonical StatusDef says "instantaneous"
##                 -> Phase-3 has no persistent runtime model for
##                    instant statuses yet
##                 -> ApplyStatusEffect must REJECT (deferred)
##       INVALID:  duration < 0 OR fractional (5.5, 1.25) OR
##                 NaN / INF
##                 -> ApplyStatusEffect must FAIL SAFELY
##
##   - The result is an explicit Dictionary {ok, kind, ticks, reason}.
##     "ok=false" must be checked BEFORE container creation or
##     StatusInstance construction.
##   - No integer sentinel collision: -1 is reserved for runtime
##     "indefinite" semantics on StatusInstance.remaining, NOT for
##     validation failure.

const ContentDBScript = preload("res://core/utils/content_db.gd")
const StatusDefScript = preload("res://core/data/status_def.gd")

## Kinds emitted by convert_duration.
const KIND_TIMED: StringName = &"timed"
const KIND_INSTANT: StringName = &"instant"
const KIND_INVALID: StringName = &"invalid"


## Returns the StatusDef for the given id, or null if not found.
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


## Validates a StatusDef.duration (float seconds) and converts it to
## the B1.1 explicit result Dictionary:
##   { ok: bool,
##     kind: KIND_TIMED | KIND_INSTANT | KIND_INVALID,
##     ticks: int (only meaningful when ok && kind == KIND_TIMED),
##     reason: String (only populated when !ok) }
##
## Rules:
##   duration > 0 AND integral (5.0, 1.0):
##     -> { ok=true, kind=KIND_TIMED, ticks=N, reason="" }
##   duration == 0:
##     -> { ok=false, kind=KIND_INSTANT, ticks=0,
##           reason="status duration=0 is INSTANT; execution
##                   deferred to a later Phase" }
##   duration < 0:
##     -> { ok=false, kind=KIND_INVALID, ticks=0,
##           reason="negative duration rejected" }
##   fractional (5.5, 1.25):
##     -> { ok=false, kind=KIND_INVALID, ticks=0,
##           reason="fractional duration rejected for Phase 3" }
##   NaN / INF:
##     -> { ok=false, kind=KIND_INVALID, ticks=0,
##           reason="non-finite duration rejected" }
static func convert_duration(p_duration: float) -> Dictionary:
	# NaN / INF detection (NaN compares false to everything, including itself).
	if not (p_duration == p_duration):
		return _invalid("non-finite duration rejected")
	if p_duration == INF or p_duration == -INF:
		return _invalid("non-finite duration rejected")
	if p_duration < 0.0:
		return _invalid("negative duration rejected")
	if p_duration == 0.0:
		return {
			"ok": false,
			"kind": KIND_INSTANT,
			"ticks": 0,
			"reason": "status duration=0 is INSTANT; execution deferred to a later Phase",
		}
	# Accept ONLY exact integer floats.
	if p_duration != floor(p_duration):
		return _invalid("fractional duration rejected for Phase 3")
	return {
		"ok": true,
		"kind": KIND_TIMED,
		"ticks": int(p_duration),
		"reason": "",
	}


static func _invalid(p_reason: String) -> Dictionary:
	return {
		"ok": false,
		"kind": KIND_INVALID,
		"ticks": 0,
		"reason": p_reason,
	}
