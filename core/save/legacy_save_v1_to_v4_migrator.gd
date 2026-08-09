class_name LegacySaveV1ToV4Migrator extends RefCounted
## Pure, in-memory migrator from the legacy on-disk v1 run shape
## (`RunState` with `unit_states` as embedded
## `Object(RefCounted,...)` blocks) to the v4 DTO defined by
## `SaveSchemaV4`.
##
## Inputs: a `RunState` resource loaded from the production
## save path, or any `Dictionary` that structurally matches the
## legacy v1 shape.
##
## Outputs: a `Dictionary` matching the v4 DTO, plus diagnostics.
##
## This migrator never writes to `user://`. It does not modify the
## source. It never throws for expected validation failures; an
## invalid equip index or a missing state row produces a diagnostic
## and a predictable fallback.

const ID_FORMAT_UNIT: String = "unit_%06d"
const ID_FORMAT_ITEM: String = "item_%06d"
const SOURCE_SCHEMA: int = 1
const TARGET_SCHEMA: int = 4
const CODE_UNIT_STATES_COUNT_MISMATCH: String = "unit_states_count_mismatch"
const CODE_ITEM_EQUIP_BOARD_IDX_OUT_OF_RANGE: String = "item_equip_board_idx_out_of_range"
const CODE_ITEM_EQUIP_BOARD_IDX_NOT_INT: String = "item_equip_board_idx_not_int"
const CODE_ITEM_EQUIP_BOARD_IDX_NEGATIVE: String = "item_equip_board_idx_negative"
const CODE_SOURCE_NOT_LEGACY: String = "source_not_legacy_v1"


## Returns a `MigrationResult` Dictionary with the following keys:
##   success: bool
##   data: Dictionary (v4 DTO when success==true; empty otherwise)
##   diagnostics: Array[RefCounted]
##   source_schema: int
##   target_schema: int
static func migrate_run(source: Variant) -> Dictionary:
	var result: Dictionary = _empty_result()
	if source == null:
		_add(result, MigrationDiagnostic.error(CODE_SOURCE_NOT_LEGACY, "source is null", ""))
		return result
	# Source may be a RunState resource or a plain Dictionary that
	# structurally matches the legacy v1 shape.
	var src: Dictionary = _read_source(source)
	if src.is_empty():
		_add(result, MigrationDiagnostic.error(CODE_SOURCE_NOT_LEGACY, "source is not legacy v1", ""))
		return result
	var player_unit_ids: Array = src.get("player_unit_ids", [])
	var bench_unit_ids: Array = src.get("bench_unit_ids", [])
	var unit_states: Array = src.get("unit_states", [])
	var item_ids: Array = src.get("item_ids", [])
	var item_equip_board_idx: Array = src.get("item_equip_board_idx", [])

	# Build deterministic ordered unit list: board, then bench.
	var ordered_definitions: Array = []
	for id in player_unit_ids:
		ordered_definitions.append({"definition_id": id, "location": 0})
	for id in bench_unit_ids:
		ordered_definitions.append({"definition_id": id, "location": 1})

	# Validate unit_states length.
	if unit_states.size() != ordered_definitions.size():
		_add(result, MigrationDiagnostic.warning(
			CODE_UNIT_STATES_COUNT_MISMATCH,
			"expected %d unit_states, got %d" % [ordered_definitions.size(), unit_states.size()],
			""))

	var v4: Dictionary = SaveSchemaV4.empty_dto()
	v4["run_id"] = "run_%d" % int(src.get("seed", 0))
	v4["seed"] = int(src.get("seed", 0))
	v4["round_index"] = int(src.get("round_index", 1))
	v4["gold"] = int(src.get("gold", 0))
	v4["wins"] = int(src.get("wins", 0))
	v4["losses"] = int(src.get("losses", 0))
	v4["units_killed"] = int(src.get("units_killed", 0))
	v4["lives"] = int(src.get("lives", 0))
	v4["xp"] = int(src.get("xp", 0))
	v4["level"] = int(src.get("level", 0))
	v4["current_encounter_id"] = int(src.get("current_encounter_id", -1))
	v4["just_visited_merchant"] = bool(src.get("just_visited_merchant", false))
	var phase_visited: Array = src.get("encounter_visited_ids", [])
	if phase_visited is Array:
		v4["encounter_visited_ids"] = (phase_visited as Array).duplicate()
	var meta_modifiers: Variant = src.get("meta_modifiers", {})
	if meta_modifiers is Dictionary:
		v4["meta_modifiers"] = (meta_modifiers as Dictionary).duplicate()
	# Phase is a runtime-only field in the legacy save. We surface
	# "prep" by default; the production repository task is the one
	# that sources it from RunController.
	v4["phase"] = "prep"

	# Build units.
	var units: Array = []
	var unit_id_to_instance: Dictionary = {}
	var next_unit_seq: int = 1
	var board_order: int = 0
	var bench_order: int = 0
	for i in ordered_definitions.size():
		var definition_id: StringName = StringName(String(ordered_definitions[i]["definition_id"]))
		var location: int = int(ordered_definitions[i]["location"])
		var order: int = board_order if location == 0 else bench_order
		if location == 0:
			board_order += 1
		else:
			bench_order += 1
		var instance_id: String = ID_FORMAT_UNIT % next_unit_seq
		next_unit_seq += 1
		var state: Dictionary = _read_unit_state(unit_states, i, result, definition_id)
		var u: Dictionary = {
			"instance_id": instance_id,
			"definition_id": definition_id,
			"current_hp": int(state.get("current_hp", -1)),
			"max_hp": int(state.get("max_hp", -1)),
			"bonus_attack": int(state.get("bonus_attack", 0)),
			"dead": _is_dead(state),
			"location": location,
			"order": order,
			"equipped_item_ids": [] as Array,
		}
		units.append(u)
		unit_id_to_instance[String(definition_id) + "@" + str(i)] = instance_id
	v4["units"] = units
	# next_*_instance_seq is the FIRST UNUSED sequence (max_used + 1).
	v4["next_unit_instance_seq"] = next_unit_seq

	# Build items in source order.
	var items: Array = []
	var next_item_seq: int = 1
	var board_units: Array = []
	for u in units:
		if int(u.get("location", -1)) == 0:
			board_units.append(u)
	for i in item_ids.size():
		var item_def: StringName = StringName(String(item_ids[i]))
		var instance_id: String = ID_FORMAT_ITEM % next_item_seq
		next_item_seq += 1
		var owner: String = ""
		if i < item_equip_board_idx.size():
			var raw_idx: Variant = item_equip_board_idx[i]
			if typeof(raw_idx) != TYPE_INT:
				_add(result, MigrationDiagnostic.warning(
					CODE_ITEM_EQUIP_BOARD_IDX_NOT_INT,
					"item_equip_board_idx is not an int",
					str(i)))
			else:
				var idx: int = int(raw_idx)
				if idx < 0:
					owner = ""
				elif idx < board_units.size():
					owner = String(board_units[idx].get("instance_id", ""))
					(board_units[idx]["equipped_item_ids"] as Array).append(instance_id)
				else:
					_add(result, MigrationDiagnostic.warning(
						CODE_ITEM_EQUIP_BOARD_IDX_OUT_OF_RANGE,
						"item_equip_board_idx %d out of range" % idx,
						str(idx)))
					owner = ""
		var item_record: Dictionary = {
			"instance_id": instance_id,
			"definition_id": item_def,
			"owner_unit_id": owner,
		}
		items.append(item_record)
	v4["items"] = items
	# next_*_instance_seq is the FIRST UNUSED sequence (max_used + 1).
	v4["next_item_instance_seq"] = next_item_seq

	result["data"] = v4
	result["success"] = true
	result["source_schema"] = SOURCE_SCHEMA
	result["target_schema"] = TARGET_SCHEMA
	return result


## Serialize a v4 DTO into a canonical Dictionary. The output is
## the only byte-faithful wire form. The input must already satisfy
## `SaveSchemaV4.is_v4_dto`; missing keys are emitted as zero values.
static func serialize(data: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in SaveSchemaV4.TOP_LEVEL_KEYS:
		if data.has(key):
			out[key] = _clone_value(data[key])
		else:
			out[key] = _zero_for(key)
	return out


## Deserialize a previously serialized v4 DTO. Defensive: missing
## keys are filled with zero values; extra keys are dropped.
static func deserialize(serialized: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in SaveSchemaV4.TOP_LEVEL_KEYS:
		if serialized.has(key):
			out[key] = _clone_value(serialized[key])
		else:
			out[key] = _zero_for(key)
	return out


## Returns a canonical encoding of a v4 DTO with all keys in
## `SaveSchemaV4.TOP_LEVEL_KEYS` order and nested values cloned
## so callers can hash without aliasing.
static func canonicalize(data: Dictionary) -> Dictionary:
	return serialize(data)


## Validates a v4 DTO. Returns `{success: bool, diagnostics:
## Array[RefCounted]}`. The validator never mutates the input.
## Type-defensive: malformed input produces diagnostics, never
## SCRIPT ERROR or runtime type errors.
static func validate(data: Dictionary) -> Dictionary:
	var result: Dictionary = {
		"success": true,
		"diagnostics": [] as Array,
	}
	if not SaveSchemaV4.is_v4_dto(data):
		result["success"] = false
		result["diagnostics"].append(MigrationDiagnostic.error(
			"not_v4_dto",
			"data does not satisfy SaveSchemaV4.is_v4_dto",
			""))
		return result

	# Unit checks: each entry must be a Dictionary with the right
	# field types. No SCRIPT ERROR on malformed input.
	var unit_instance_to_idx: Dictionary = {}
	var unit_owner_listings: Dictionary = {}  # instance_id -> Array[String]
	var units_by_location: Dictionary = {0: {}, 1: {}}  # location -> {order -> instance_id}
	var max_unit_seq: int = 0

	var units_value: Variant = data.get("units", [])
	if units_value is Array:
		var units: Array = units_value
		for i in units.size():
			var u_value: Variant = units[i]
			if not (u_value is Dictionary):
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"unit_not_dict",
					"unit[%d] is not a Dictionary" % i,
					str(i)))
				continue
			var u: Dictionary = u_value
			var instance_id: String = _safe_str(u.get("instance_id", ""))
			if instance_id == "":
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"empty_unit_instance_id",
					"unit[%d] has empty instance_id" % i,
					str(i)))
			elif unit_instance_to_idx.has(instance_id):
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"duplicate_unit_instance_id",
					"duplicate unit instance_id %s" % instance_id,
					instance_id))
			unit_instance_to_idx[instance_id] = i
			var definition_id: String = _safe_str(u.get("definition_id", ""))
			if definition_id == "":
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"empty_unit_definition_id",
					"unit[%d] (%s) has empty definition_id" % [i, instance_id],
					instance_id))
			var current_hp: int = _safe_int(u.get("current_hp", 0))
			var max_hp: int = _safe_int(u.get("max_hp", 0))
			var bonus_attack: int = _safe_int(u.get("bonus_attack", 0))
			var location: int = _safe_int(u.get("location", -1))
			var order: int = _safe_int(u.get("order", -1))
			var dead_v: Variant = u.get("dead", false)
			var dead: bool = (dead_v is bool) and (dead_v as bool)
			var equipped: Array = []
			var equipped_value: Variant = u.get("equipped_item_ids", [])
			if equipped_value is Array:
				equipped = equipped_value
			# Location must be 0 or 1.
			if location != 0 and location != 1:
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"unit_location_invalid",
					"unit %s location %d not in {0,1}" % [instance_id, location],
					instance_id))
			# order must be >= 0 and unique within location.
			if order < 0:
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"unit_order_negative",
					"unit %s order %d < 0" % [instance_id, order],
					instance_id))
			elif location == 0 or location == 1:
				var loc_orders: Dictionary = units_by_location[location]
				if loc_orders.has(order):
					result["success"] = false
					result["diagnostics"].append(MigrationDiagnostic.error(
						"duplicate_unit_order_in_location",
						"duplicate order %d in location %d" % [order, location],
						str(location)))
				else:
					loc_orders[order] = instance_id
			# current_hp: -1 is sentinel; 0..max_hp valid; < -1 invalid.
			if current_hp < -1:
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"current_hp_below_sentinel",
					"unit %s current_hp %d < -1" % [instance_id, current_hp],
					instance_id))
			elif current_hp > max_hp:
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"hp_out_of_range",
					"unit %s current_hp %d > max_hp %d" % [instance_id, current_hp, max_hp],
					instance_id))
			# Duplicate equipped_item_id entries inside one unit.
			var seen_equipped: Dictionary = {}
			for itm in equipped:
				var itm_str: String = _safe_str(itm)
				if seen_equipped.has(itm_str):
					result["success"] = false
					result["diagnostics"].append(MigrationDiagnostic.error(
						"duplicate_in_unit_equipped",
						"unit %s has duplicate equipped item id %s" % [instance_id, itm_str],
						instance_id))
				seen_equipped[itm_str] = true
			unit_owner_listings[instance_id] = equipped
			var seq: int = _seq_from_instance_id(instance_id, "unit_")
			if seq > max_unit_seq:
				max_unit_seq = seq

	# Item checks.
	var item_instance_to_idx: Dictionary = {}
	var max_item_seq: int = 0
	var items_value: Variant = data.get("items", [])
	if items_value is Array:
		var items: Array = items_value
		for i in items.size():
			var it_value: Variant = items[i]
			if not (it_value is Dictionary):
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"item_not_dict",
					"item[%d] is not a Dictionary" % i,
					str(i)))
				continue
			var it: Dictionary = it_value
			var instance_id: String = _safe_str(it.get("instance_id", ""))
			if instance_id == "":
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"empty_item_instance_id",
					"item[%d] has empty instance_id" % i,
					str(i)))
			elif item_instance_to_idx.has(instance_id):
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"duplicate_item_instance_id",
					"duplicate item instance_id %s" % instance_id,
					instance_id))
			item_instance_to_idx[instance_id] = i
			var definition_id: String = _safe_str(it.get("definition_id", ""))
			if definition_id == "":
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"empty_item_definition_id",
					"item[%d] (%s) has empty definition_id" % [i, instance_id],
					instance_id))
			var owner: String = _safe_str(it.get("owner_unit_id", ""))
			if owner != "" and not unit_instance_to_idx.has(owner):
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"unknown_item_owner",
					"item %s owner %s does not exist" % [instance_id, owner],
					instance_id))
			var seq2: int = _seq_from_instance_id(instance_id, "item_")
			if seq2 > max_item_seq:
				max_item_seq = seq2

	# Bidirectional equipment consistency (H5 A-E).
	for instance_id in item_instance_to_idx.keys():
		var it2: Dictionary = items_value[item_instance_to_idx[instance_id]] as Dictionary
		var owner2: String = _safe_str(it2.get("owner_unit_id", ""))
		# Invariant A: item.owner set but unit does not list it.
		if owner2 != "" and unit_instance_to_idx.has(owner2):
			var unit_equipped: Array = unit_owner_listings.get(owner2, [])
			if not unit_equipped.has(instance_id):
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"inconsistent_equip",
					"item %s owned by %s but unit does not list it" % [instance_id, owner2],
					instance_id))
		# Invariant C: same item id listed by two units.
		var item_in_unit_count: int = 0
		for unit_id in unit_owner_listings.keys():
			var listed: Array = unit_owner_listings[unit_id]
			if listed.has(instance_id):
				item_in_unit_count += 1
		if item_in_unit_count > 1:
			result["success"] = false
			result["diagnostics"].append(MigrationDiagnostic.error(
				"item_listed_by_multiple_units",
				"item %s listed by %d units" % [instance_id, item_in_unit_count],
				instance_id))

	# Invariant B: unit lists item but item.owner is empty.
	for unit_id in unit_owner_listings.keys():
		var listed2: Array = unit_owner_listings[unit_id]
		for itm2 in listed2:
			var itm_str2: String = _safe_str(itm2)
			if not item_instance_to_idx.has(itm_str2):
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"unknown_item_in_equipped_list",
					"unit %s lists unknown item id %s" % [unit_id, itm_str2],
					unit_id))
				continue
			var owner3: String = _safe_str((items_value[item_instance_to_idx[itm_str2]] as Dictionary).get("owner_unit_id", ""))
			if owner3 == "":
				result["success"] = false
				result["diagnostics"].append(MigrationDiagnostic.error(
					"inconsistent_equip",
					"item %s listed by unit %s has empty owner" % [itm_str2, unit_id],
					unit_id))

	# next_*_instance_seq must be exactly max_used + 1 (first unused).
	if int(data.get("next_unit_instance_seq", 0)) != max_unit_seq + 1:
		result["success"] = false
		result["diagnostics"].append(MigrationDiagnostic.error(
			"next_unit_instance_seq_invalid",
			"next_unit_instance_seq must be first unused sequence (expected %d, got %d)" % [max_unit_seq + 1, int(data.get("next_unit_instance_seq", 0))],
			str(max_unit_seq + 1)))
	if int(data.get("next_item_instance_seq", 0)) != max_item_seq + 1:
		result["success"] = false
		result["diagnostics"].append(MigrationDiagnostic.error(
			"next_item_instance_seq_invalid",
			"next_item_instance_seq must be first unused sequence (expected %d, got %d)" % [max_item_seq + 1, int(data.get("next_item_instance_seq", 0))],
			str(max_item_seq + 1)))

	return result


## Safe coercion helpers used by validate(). Never crash; never
## mutate the input. Each helper returns a typed default on type
## mismatch.
static func _safe_str(value: Variant) -> String:
	if typeof(value) == TYPE_STRING:
		return value
	if typeof(value) == TYPE_STRING_NAME:
		return String(value)
	return ""


static func _safe_int(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		return int(value)
	if typeof(value) == TYPE_FLOAT:
		var f: float = float(value)
		if is_finite(f) and f == floor(f):
			return int(f)
	return 0


static func _safe_bool(value: Variant) -> bool:
	if typeof(value) == TYPE_BOOL:
		return bool(value)
	return false


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

static func _empty_result() -> Dictionary:
	return {
		"success": false,
		"data": {},
		"diagnostics": [] as Array,
		"source_schema": SOURCE_SCHEMA,
		"target_schema": TARGET_SCHEMA,
	}


static func _add(result: Dictionary, diagnostic: RefCounted) -> void:
	if diagnostic != null:
		result["diagnostics"].append(diagnostic)


static func _read_source(source: Variant) -> Dictionary:
	if source is Dictionary:
		if source.has("player_unit_ids") and source.has("unit_states") and source.has("item_ids"):
			return source
		return {}
	if source is Resource:
		var d: Dictionary = {}
		for key in [
			"version", "seed", "round_index", "gold", "xp", "level", "lives",
			"player_unit_ids", "bench_unit_ids", "item_ids", "item_equip_board_idx",
			"just_visited_merchant", "wins", "losses", "units_killed",
			"current_encounter_id", "encounter_visited_ids", "meta_modifiers",
			"unit_states",
		]:
			if key in source:
				d[key] = source.get(key)
		return d
	return {}


static func _read_unit_state(unit_states: Array, ordered_index: int, result: Dictionary, definition_id: StringName) -> Dictionary:
	if ordered_index >= unit_states.size():
		return {}
	var s: Variant = unit_states[ordered_index]
	if s is Dictionary:
		return s
	# Legacy .tres files embed `Object(RefCounted,...)` blocks.
	# RunUnitState is a RefCounted (not a Resource), so check both.
	if s is Resource or (s != null and s is RefCounted):
		var d: Dictionary = {}
		for key in ["unit_id", "current_hp", "max_hp", "bonus_attack"]:
			if key in s:
				d[key] = s.get(key)
		return d
	return {}


static func _is_dead(state: Dictionary) -> bool:
	var current_hp: int = int(state.get("current_hp", -1))
	var max_hp: int = int(state.get("max_hp", -1))
	if current_hp == 0 and max_hp == 0:
		return false
	if current_hp == -1:
		return false
	return current_hp <= 0


static func _clone_value(value: Variant) -> Variant:
	if value is Array:
		return (value as Array).duplicate(true)
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return value


static func _zero_for(key: String) -> Variant:
	match key:
		"schema_version": return TARGET_SCHEMA
		"game_build": return ""
		"run_id": return ""
		"seed": return 0
		"round_index": return 1
		"phase": return "prep"
		"gold": return 0
		"units": return [] as Array
		"items": return [] as Array
		"next_unit_instance_seq": return 0
		"next_item_instance_seq": return 0
		"shop": return {}
		"map": return {}
		"rewards": return {}
		"wins": return 0
		"losses": return 0
		"units_killed": return 0
		"lives": return 0
		"xp": return 0
		"level": return 0
		"current_encounter_id": return -1
		"encounter_visited_ids": return [] as Array
		"meta_modifiers": return {}
		"just_visited_merchant": return false
		_: return null


static func _seq_from_instance_id(instance_id: String, prefix: String) -> int:
	if not instance_id.begins_with(prefix):
		return 0
	var rest: String = instance_id.substr(prefix.length(), instance_id.length() - prefix.length())
	if not rest.is_valid_int():
		return 0
	return int(rest)
