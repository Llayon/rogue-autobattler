class_name SaveSchemaV5
## Canonical save schema v5 — the RUN CHECKPOINT.
##
## v4 described only the domain state. Everything else was hardcoded:
##
##     phase   = "prep"
##     shop    = {}
##     map     = {}
##     rewards = {}
##
## v5 keeps every canonical domain field of v4 and adds the missing
## checkpoint layers:
##
##   phase   : the stable flow phase, as a stable WIRE NAME
##   shop    : the unit-shop offer and the merchant offer
##   map     : the encounter-map snapshot
##   rewards : the reward offer
##   rng     : the RNG continuation state
##
## The on-disk data stays primitive DTO data: Dictionary, Array,
## String, int, float, bool. No Godot object graph is serialized.

const SCHEMA_VERSION: int = 5

## Top-level keys, in canonical order. The serializer emits the keys
## in this order, so two semantically identical checkpoints serialize
## identically.
const TOP_LEVEL_KEYS: Array = [
	"schema_version",
	"game_build",
	"run_id",
	"seed",
	"round_index",
	"phase",
	"gold",
	"units",
	"items",
	"next_unit_instance_seq",
	"next_item_instance_seq",
	"shop",
	"map",
	"rewards",
	"rng",
	"wins",
	"losses",
	"units_killed",
	"lives",
	"xp",
	"level",
	"current_encounter_id",
	"encounter_visited_ids",
	"meta_modifiers",
	"just_visited_merchant",
]

## The stable wire names of the resumable flow phases.
##
## The runtime has no MERCHANT phase: the merchant visit is the PREP
## phase with the `just_visited_merchant` flag set. The wire contract
## keeps the two apart, so a merchant checkpoint is distinguishable
## from a plain prep checkpoint.
const PHASE_PREP: String = "prep"
const PHASE_MAP: String = "map"
const PHASE_REWARD: String = "reward"
const PHASE_MERCHANT: String = "merchant"

## The resumable phases. BATTLE is deliberately absent: a mid-battle
## resume is out of scope, and GAMEOVER is not an active run.
const RESUMABLE_PHASES: Array = [PHASE_PREP, PHASE_MAP, PHASE_REWARD, PHASE_MERCHANT]

## The top-level fields that are integers on the wire. A JSON parser
## returns them as floats, so the wire normalization coerces them
## back.
const INTEGER_FIELDS: Array[StringName] = [
	&"schema_version", &"seed", &"round_index", &"gold",
	&"next_unit_instance_seq", &"next_item_instance_seq",
	&"wins", &"losses", &"units_killed", &"lives",
	&"xp", &"level", &"current_encounter_id",
]

## GDScript types expected on the canonical DTO, after wire
## normalization.
const REQUIRED_TYPES: Dictionary = {
	"schema_version": TYPE_INT,
	"game_build": TYPE_STRING,
	"run_id": TYPE_STRING,
	"seed": TYPE_INT,
	"round_index": TYPE_INT,
	"phase": TYPE_STRING,
	"gold": TYPE_INT,
	"units": TYPE_ARRAY,
	"items": TYPE_ARRAY,
	"next_unit_instance_seq": TYPE_INT,
	"next_item_instance_seq": TYPE_INT,
	"shop": TYPE_DICTIONARY,
	"map": TYPE_DICTIONARY,
	"rewards": TYPE_DICTIONARY,
	"rng": TYPE_DICTIONARY,
	"wins": TYPE_INT,
	"losses": TYPE_INT,
	"units_killed": TYPE_INT,
	"lives": TYPE_INT,
	"xp": TYPE_INT,
	"level": TYPE_INT,
	"current_encounter_id": TYPE_INT,
	"encounter_visited_ids": TYPE_ARRAY,
	"meta_modifiers": TYPE_DICTIONARY,
	"just_visited_merchant": TYPE_BOOL,
}


## Returns true when the given Dictionary is structurally a v5 DTO.
static func is_v5_dto(data) -> bool:
	if not (data is Dictionary):
		return false
	return validate_shape(data).success


## Returns `{success: bool, diagnostics: Array[RefCounted]}`. Never
## raises; never mutates the input.
static func validate_shape(data) -> Dictionary:
	var result: Dictionary = {
		"success": true,
		"diagnostics": [] as Array,
	}
	if not (data is Dictionary):
		result.success = false
		result.diagnostics.append(_err("not_dict", "data is not a Dictionary", ""))
		return result
	for key in REQUIRED_TYPES:
		if not data.has(key):
			result.success = false
			result.diagnostics.append(_err(
				"missing_top_level_key", "top-level key missing: %s" % key, key))
			continue
		var got: int = typeof(data[key])
		var want: int = REQUIRED_TYPES[key]
		if got != want:
			result.success = false
			result.diagnostics.append(_err(
				"top_level_type_mismatch",
				"%s expected type %d got %d" % [key, want, got],
				key))
	if result.success:
		var phase: String = str(data.get("phase", ""))
		if not (phase in RESUMABLE_PHASES):
			result.success = false
			result.diagnostics.append(_err(
				"unknown_phase",
				"phase is not a resumable wire name: '%s'" % phase,
				"phase"))
	# The rng continuation is validated at the SHAPE level too.
	#
	# The PRNG machine state is a lossless decimal string: a JSON
	# number cannot hold the low bits of a 64-bit state. Without this
	# check a DTO with a numeric state passed the shape gate AND the
	# semantic gate (the gate does not look at `rng`), was written to
	# the disk, and could then NOT be read back: the load rejected it
	# in the wire normaliser. A save that cannot be read back is a
	# poison slot.
	if result.success:
		var rng_value: Variant = data.get("rng", {})
		if not (rng_value is Dictionary):
			result.success = false
			result.diagnostics.append(_err(
				"rng_not_dict", "rng is not a Dictionary", "rng"))
		else:
			var rng_dict: Dictionary = rng_value as Dictionary
			for key in ["seed", "state"]:
				if not rng_dict.has(key):
					result.success = false
					result.diagnostics.append(_err(
						"rng_key_missing",
						"rng is missing the key %s" % key, "rng"))
			var rng_state: Variant = rng_dict.get("state", null)
			if rng_dict.has("state") and not (rng_state is String):
				result.success = false
				result.diagnostics.append(_err(
					"rng_state_not_a_string",
					"rng.state must be a lossless decimal string, got %s"
						% type_string(typeof(rng_state)), "rng"))
			elif rng_state is String:
				var decoded: Dictionary = decode_int64(rng_state)
				if not bool(decoded.get("ok", false)):
					result.success = false
					result.diagnostics.append(_err(
						"rng_state_malformed",
						"rng.state is not a canonical decimal int64: '%s'"
							% str(rng_state), "rng"))
	return result


## Returns an empty, structurally valid v5 DTO.
static func empty_dto() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"game_build": "",
		"run_id": "",
		"seed": 0,
		"round_index": 1,
		"phase": PHASE_PREP,
		"gold": 0,
		"units": [] as Array,
		"items": [] as Array,
		"next_unit_instance_seq": 1,
		"next_item_instance_seq": 1,
		"shop": {} as Dictionary,
		"map": {} as Dictionary,
		"rewards": {} as Dictionary,
		"rng": {} as Dictionary,
		"wins": 0,
		"losses": 0,
		"units_killed": 0,
		"lives": 0,
		"xp": 0,
		"level": 0,
		"current_encounter_id": -1,
		"encounter_visited_ids": [] as Array,
		"meta_modifiers": {} as Dictionary,
		"just_visited_merchant": false,
	}


## ---------------------------------------------------------------------------
## Lossless int64 wire encoding
## ---------------------------------------------------------------------------
##
## The PRNG machine state is a full-width 64-bit value. It is NOT an
## IEEE-754 safe integer: around 1.45e18 the double spacing is 256, so
## a JSON number loses the low bits BEFORE any normalizer can see it
## (and INT64_MAX even overflows to INT64_MIN).
##
## Therefore the machine state is carried as a canonical decimal
## STRING. The ordinary gameplay integers (round, gold, HP, node ids,
## sequence counters) are all far below 2^53 and stay JSON numbers —
## the string encoding is deliberately narrow.

## The largest and smallest signed 64-bit values.
const INT64_MAX: int = 9223372036854775807
const INT64_MIN: int = -9223372036854775808


## Encodes a signed 64-bit value as its canonical decimal string.
static func encode_int64(value: int) -> String:
	return str(value)


## Decodes a canonical decimal int64 string.
##
## The decoder is strict on purpose:
##   - only a String is accepted (a JSON number would have lost the
##     low bits already);
##   - the text must be a canonical decimal integer: an optional
##     minus, then digits, with no plus sign, no leading zeros and no
##     whitespace;
##   - the value must fit the signed 64-bit range.
##
## Returns `{ok: bool, value: int, reason: String}`.
static func decode_int64(value: Variant) -> Dictionary:
	if not (value is String):
		return {"ok": false, "value": 0, "reason": "not_a_string"}
	var text: String = String(value)
	if text.is_empty():
		return {"ok": false, "value": 0, "reason": "empty"}
	var digits: String = text
	if digits.begins_with("-"):
		digits = digits.substr(1)
		if digits.is_empty():
			return {"ok": false, "value": 0, "reason": "malformed"}
	# Canonical decimal: digits only, no leading zero unless the value
	# is exactly "0".
	if not digits.is_valid_int():
		return {"ok": false, "value": 0, "reason": "not_a_decimal_integer"}
	if digits.length() > 1 and digits.begins_with("0"):
		return {"ok": false, "value": 0, "reason": "not_canonical"}
	var parsed: int = text.to_int()
	# A value outside the signed 64-bit range would not round-trip.
	if parsed < INT64_MIN or parsed > INT64_MAX:
		return {"ok": false, "value": 0, "reason": "out_of_int64_range"}
	if encode_int64(parsed) != text:
		return {"ok": false, "value": 0, "reason": "not_canonical"}
	return {"ok": true, "value": parsed, "reason": ""}


## Maps the runtime phase to the stable wire name.
##
## The runtime phases are RunController.Phase:
##   PREP = 0, BATTLE = 1, REWARD = 2, GAMEOVER = 3, MAP = 4, SERVICE = 5
##
## The merchant state is PREP plus the `just_visited_merchant` flag, so
## the flag decides between the two wire names.
static func wire_phase_for(runtime_phase: int, merchant_flag: bool) -> String:
	match runtime_phase:
		4:
			return PHASE_MAP
		2:
			return PHASE_REWARD
		_:
			return PHASE_MERCHANT if merchant_flag else PHASE_PREP


# ---------------------------------------------------------------------------
# Wire helpers
# ---------------------------------------------------------------------------

## JSON numeric -> GDScript int. Accepts TYPE_INT and integral
## TYPE_FLOAT. Rejects non-integral floats, strings, bools, nulls.
static func _wire_int(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) == TYPE_FLOAT:
		var f: float = float(value)
		if not is_finite(f):
			return {"ok": false, "reason": "not_finite"}
		if f != floor(f):
			return {"ok": false, "reason": "not_integral"}
		return {"ok": true, "value": int(f)}
	return {"ok": false, "reason": "not_a_number"}


## JSON bool -> GDScript bool.
static func _wire_bool(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_BOOL:
		return {"ok": true, "value": bool(value)}
	return {"ok": false, "reason": "not_a_bool"}


## JSON string -> GDScript String.
static func _wire_string(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_STRING:
		return {"ok": true, "value": str(value)}
	return {"ok": false, "reason": "not_a_string"}


## JSON array -> GDScript Array.
static func _wire_array(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_ARRAY:
		return {"ok": true, "value": value}
	return {"ok": false, "reason": "not_an_array"}


## JSON object -> GDScript Dictionary.
static func _wire_dict(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_DICTIONARY:
		return {"ok": true, "value": value}
	return {"ok": false, "reason": "not_a_dictionary"}


static func _err(code: String, detail: String, context: String) -> RefCounted:
	# MigrationDiagnostic is a class_name, so it is directly available.
	#
	# The ClassDB check is NOT a valid test for a class_name script:
	# ClassDB only knows the engine's own classes, so it always reports
	# false for a project script. The earlier fallback returned a plain
	# Dictionary, and the caller passed it to SaveLoadResult.
	# add_diagnostic(), which expects a RefCounted -> the load path
	# CRASHED on a shape-invalid file.
	var diagnostic: MigrationDiagnostic = MigrationDiagnostic.new()
	diagnostic.severity = MigrationDiagnostic.Severity.ERROR
	diagnostic.code = code
	diagnostic.detail = detail
	diagnostic.context = context
	return diagnostic
