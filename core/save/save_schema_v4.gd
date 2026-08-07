class_name SaveSchemaV4 extends RefCounted
## Canonical v4 save schema. The DTO is an explicit Dictionary; no
## Godot object graph is persisted.
##
## See `docs/LEGACY_V1_TO_V4_MAPPING.md` for the field origins.

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


## Returns `true` if the given `Dictionary` is structurally a v4 DTO
## (has all required top-level keys with the correct types).
static func is_v4_dto(data: Dictionary) -> bool:
	if not data.has("schema_version"):
		return false
	if int(data.get("schema_version", 0)) != SCHEMA_VERSION:
		return false
	for key in TOP_LEVEL_KEYS:
		if not data.has(key):
			return false
	return true


## Returns an empty, structurally valid v4 DTO with default values
## and empty units/items arrays.
static func empty_dto() -> Dictionary:
	var units: Array = []
	var items: Array = []
	var d: Dictionary = {
		"schema_version": SCHEMA_VERSION,
		"game_build": "",
		"run_id": "",
		"seed": 0,
		"round_index": 1,
		"phase": "prep",
		"gold": 0,
		"units": units,
		"items": items,
		"next_unit_instance_seq": 0,
		"next_item_instance_seq": 0,
		"shop": {},
		"map": {},
		"rewards": {},
		"wins": 0,
		"losses": 0,
		"units_killed": 0,
		"lives": 0,
		"xp": 0,
		"level": 0,
		"current_encounter_id": -1,
		"encounter_visited_ids": [],
		"meta_modifiers": {},
		"just_visited_merchant": false,
	}
	return d
