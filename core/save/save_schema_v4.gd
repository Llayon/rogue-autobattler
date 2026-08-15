class_name SaveSchemaV4 extends RefCounted
## Canonical v4 save schema. The DTO is an explicit Dictionary; no
## Godot object graph is persisted.
##
## See `docs/LEGACY_V1_TO_V4_MAPPING.md` for the field origins.
##
## Public API:
##   is_v4_dto(data) -> bool
##       Bool API preserved for backward compatibility. Delegates to
##       validate_shape(data).success.
##   validate_shape(data) -> Dictionary
##       Returns {success: bool, diagnostics: Array[RefCounted]}.
##       Used by the migrator's validator. Walks the top-level keys
##       and asserts GDScript types AFTER wire normalization.
##   empty_dto() -> Dictionary
##       Empty structurally valid v4 DTO.
##   _wire_int / _wire_bool / _wire_string / _wire_array / _wire_dict
##       Wire helpers used by the repository when JSON-decoding the
##       on-disk file. JSON numeric types are accepted as GDScript
##       int only when the float is integral and finite.

const SCHEMA_VERSION: int = 4


## Top-level keys, in canonical order. Used by the serializer to
## emit keys in a deterministic order; the deserializer accepts any
## order.
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


## GDScript types expected on the canonical DTO. Wire normalization
## has already coerced JSON numbers; these types are post-coercion.
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


## Returns `true` if the given `Dictionary` is structurally a v4 DTO.
## Bool API preserved for backward compatibility; delegates to
## validate_shape(data).success.
static func is_v4_dto(data) -> bool:
	if not (data is Dictionary):
		return false
	return validate_shape(data).success


## Returns `{success: bool, diagnostics: Array[RefCounted]}`. Never
## raises; never mutates the input. Use this instead of
## `is_v4_dto` when diagnostics are needed.
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
	return result


## Returns an empty, structurally valid v4 DTO with default values
## and empty units/items arrays.
static func empty_dto() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"game_build": "",
		"run_id": "",
		"seed": 0,
		"round_index": 1,
		"phase": "prep",
		"gold": 0,
		"units": [] as Array,
		"items": [] as Array,
		"next_unit_instance_seq": 1,
		"next_item_instance_seq": 1,
		"shop": {} as Dictionary,
		"map": {} as Dictionary,
		"rewards": {} as Dictionary,
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


# ---------------------------------------------------------------------------
# Wire helpers
# ---------------------------------------------------------------------------

## JSON numeric -> GDScript int. Accepts TYPE_INT and integral
## TYPE_FLOAT. Rejects non-integral floats, NaN, Infinity, strings,
## bools, nulls.
static func _wire_int(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) == TYPE_FLOAT:
		var f: float = float(value)
		if not is_finite(f):
			return {"ok": false}
		if f != floor(f):
			return {"ok": false}
		return {"ok": true, "value": int(f)}
	return {"ok": false}


static func _wire_bool(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_BOOL:
		return {"ok": true, "value": bool(value)}
	return {"ok": false}


static func _wire_string(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME:
		return {"ok": true, "value": String(value)}
	return {"ok": false}


static func _wire_array(value: Variant) -> Dictionary:
	if value is Array:
		return {"ok": true, "value": value}
	return {"ok": false}


static func _wire_dict(value: Variant) -> Dictionary:
	if value is Dictionary:
		return {"ok": true, "value": value}
	return {"ok": false}


# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

static func _err(code: String, detail: String, context: String):
	# Lazy import to avoid a load-order cycle with MigrationDiagnostic.
	if not ClassDB.class_exists("MigrationDiagnostic"):
		return {"code": code, "detail": detail, "context": context, "severity": "error"}
	return MigrationDiagnostic.error(code, detail, context)