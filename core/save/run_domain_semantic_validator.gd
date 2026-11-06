class_name RunDomainSemanticValidator
## The semantic validation of the run domain collections.
##
## The checks live here and not in the v1->v4 migrator, because BOTH
## the v4 and the v5 load paths need them.
##
## This module is a FAITHFUL PORT of the semantic gate in
## `LegacySaveV1ToV4Migrator.validate`: the same checks, the same
## codes and the same accept/reject decision. The differential suite
## tests/run_integrity/semantic_gate_parity_test.gd proves it: for
## every case the two gates must agree.
##
## The validator is PURE: it never mutates the input and never raises.
##
## Returns `{success: bool, diagnostics: Array[RefCounted]}`.

const REQUIRED_UNIT_KEYS: Array[StringName] = [
	&"instance_id", &"definition_id", &"current_hp", &"max_hp",
	&"bonus_attack", &"dead", &"location", &"order", &"equipped_item_ids",
]

const REQUIRED_ITEM_KEYS: Array[StringName] = [
	&"instance_id", &"definition_id", &"owner_unit_id",
]


## Validates the unit and item collections of a run DTO.
##
## `data` may be a v4 or a v5 DTO: the validator only reads the
## `units`, `items`, `next_unit_instance_seq` and
## `next_item_instance_seq` fields, and those exist in both schemas.
static func validate(data: Dictionary) -> Dictionary:
	var result: Dictionary = {
		"success": true,
		"diagnostics": [] as Array,
	}
	if not (data is Dictionary):
		result["success"] = false
		return result

	var unit_instance_to_idx: Dictionary = {}
	# unit instance_id -> the item ids it lists as equipped.
	var unit_owner_listings: Dictionary = {}
	# location -> order -> instance_id.
	var units_by_location: Dictionary = {0: {}, 1: {}}
	var max_unit_seq: int = 0

	var units_value: Variant = data.get("units", [])
	if units_value is Array:
		var units: Array = units_value
		for i in units.size():
			var u_value: Variant = units[i]
			if not (u_value is Dictionary):
				result["success"] = false
				result["diagnostics"].append(_error(
					"unit_not_dict", "unit[%d] is not a Dictionary" % i, str(i)))
				continue
			var u: Dictionary = u_value
			# The required-key check runs BEFORE the type checks: a
			# missing key is never silently defaulted.
			for req_key in REQUIRED_UNIT_KEYS:
				if not u.has(req_key):
					result["success"] = false
					result["diagnostics"].append(_error(
						"unit_required_key_missing",
						"unit[%d] missing required key %s" % [i, req_key],
						str(i)))
			var instance_id_v: Variant = _strict_str(
				u.get("instance_id", ""), "instance_id", str(i),
				result["diagnostics"])
			if instance_id_v == null:
				result["success"] = false
				instance_id_v = ""
			var instance_id: String = String(instance_id_v)
			if instance_id == "":
				result["success"] = false
				result["diagnostics"].append(_error(
					"empty_unit_instance_id",
					"unit[%d] has empty instance_id" % i, str(i)))
			elif unit_instance_to_idx.has(instance_id):
				result["success"] = false
				result["diagnostics"].append(_error(
					"duplicate_unit_instance_id",
					"duplicate unit instance_id %s" % instance_id, instance_id))
			else:
				unit_instance_to_idx[instance_id] = i
				var seq: int = _seq_from_instance_id(instance_id, "unit_")
				if seq > max_unit_seq:
					max_unit_seq = seq
			var definition_id_v: Variant = _strict_str(
				u.get("definition_id", ""), "definition_id", instance_id,
				result["diagnostics"])
			if definition_id_v == null:
				result["success"] = false
				definition_id_v = ""
			var definition_id: String = String(definition_id_v)
			if definition_id == "":
				result["success"] = false
				result["diagnostics"].append(_error(
					"empty_unit_definition_id",
					"unit[%d] (%s) has empty definition_id" % [i, instance_id],
					instance_id))
			var current_hp_v: Variant = _strict_int(
				u.get("current_hp", 0), "current_hp", instance_id,
				result["diagnostics"])
			if current_hp_v == null:
				result["success"] = false
				current_hp_v = 0
			var current_hp: int = int(current_hp_v)
			var max_hp_v: Variant = _strict_int(
				u.get("max_hp", 0), "max_hp", instance_id,
				result["diagnostics"])
			if max_hp_v == null:
				result["success"] = false
				max_hp_v = 0
			var max_hp: int = int(max_hp_v)
			var bonus_attack_v: Variant = _strict_int(
				u.get("bonus_attack", 0), "bonus_attack", instance_id,
				result["diagnostics"])
			if bonus_attack_v == null:
				result["success"] = false
				bonus_attack_v = 0
			var location_v: Variant = _strict_int(
				u.get("location", -1), "location", instance_id,
				result["diagnostics"])
			if location_v == null:
				result["success"] = false
				location_v = 0
			var location: int = int(location_v)
			var order_v: Variant = _strict_int(
				u.get("order", -1), "order", instance_id,
				result["diagnostics"])
			if order_v == null:
				result["success"] = false
				order_v = 0
			var order: int = int(order_v)
			var dead_v: Variant = _strict_bool(
				u.get("dead", false), "dead", instance_id,
				result["diagnostics"])
			if dead_v == null:
				result["success"] = false
				dead_v = false

			# Location must be 0 or 1.
			if location != 0 and location != 1:
				result["success"] = false
				result["diagnostics"].append(_error(
					"unit_location_invalid",
					"unit %s location %d not in {0,1}" % [instance_id, location],
					instance_id))
			# order must be >= 0 and unique within its location.
			if order < 0:
				result["success"] = false
				result["diagnostics"].append(_error(
					"unit_order_negative",
					"unit %s order %d < 0" % [instance_id, order], instance_id))
			elif location == 0 or location == 1:
				var loc_orders: Dictionary = units_by_location[location]
				if loc_orders.has(order):
					result["success"] = false
					result["diagnostics"].append(_error(
						"duplicate_unit_order_in_location",
						"duplicate order %d in location %d" % [order, location],
						str(location)))
				else:
					loc_orders[order] = instance_id
			# current_hp: -1 is the "not initialised" sentinel; 0..max_hp
			# is valid; below -1 is invalid; above max_hp is invalid.
			if current_hp < -1:
				result["success"] = false
				result["diagnostics"].append(_error(
					"current_hp_below_sentinel",
					"unit %s current_hp %d < -1" % [instance_id, current_hp],
					instance_id))
			elif current_hp > max_hp:
				result["success"] = false
				result["diagnostics"].append(_error(
					"hp_out_of_range",
					"unit %s current_hp %d > max_hp %d"
						% [instance_id, current_hp, max_hp], instance_id))

			# The equipped item ids of this unit.
			var equipped_v: Variant = _strict_array(
				u.get("equipped_item_ids", []), "equipped_item_ids",
				instance_id, result["diagnostics"])
			if equipped_v == null:
				result["success"] = false
				equipped_v = [] as Array
			var equipped: Array = equipped_v
			# A duplicate entry inside one unit's list is an error.
			var seen_equipped: Dictionary = {}
			for itm in equipped:
				var itm_str_v: Variant = _strict_str(
					itm, "equipped_item_ids_entry", instance_id,
					result["diagnostics"])
				if itm_str_v == null:
					result["success"] = false
					itm_str_v = ""
				var itm_str: String = String(itm_str_v)
				if seen_equipped.has(itm_str):
					result["success"] = false
					result["diagnostics"].append(_error(
						"duplicate_in_unit_equipped",
						"unit %s has duplicate equipped item id %s"
							% [instance_id, itm_str], instance_id))
				seen_equipped[itm_str] = true
			unit_owner_listings[instance_id] = equipped

	var max_item_seq: int = 0
	var item_instance_to_idx: Dictionary = {}
	var items_value: Variant = data.get("items", [])
	if items_value is Array:
		var items: Array = items_value
		for i in items.size():
			var it_value: Variant = items[i]
			if not (it_value is Dictionary):
				result["success"] = false
				result["diagnostics"].append(_error(
					"item_not_dict", "item[%d] is not a Dictionary" % i, str(i)))
				continue
			var it: Dictionary = it_value
			for req_key in REQUIRED_ITEM_KEYS:
				if not it.has(req_key):
					result["success"] = false
					result["diagnostics"].append(_error(
						"item_required_key_missing",
						"item[%d] missing required key %s" % [i, req_key],
						str(i)))
			var item_id_v: Variant = _strict_str(
				it.get("instance_id", ""), "instance_id", str(i),
				result["diagnostics"])
			if item_id_v == null:
				result["success"] = false
				item_id_v = ""
			var item_id: String = String(item_id_v)
			if item_id == "":
				result["success"] = false
				result["diagnostics"].append(_error(
					"empty_item_instance_id",
					"item[%d] has empty instance_id" % i, str(i)))
			elif item_instance_to_idx.has(item_id):
				result["success"] = false
				result["diagnostics"].append(_error(
					"duplicate_item_instance_id",
					"duplicate item instance_id %s" % item_id, item_id))
			else:
				item_instance_to_idx[item_id] = i
				var seq: int = _seq_from_instance_id(item_id, "item_")
				if seq > max_item_seq:
					max_item_seq = seq
				# The CANONICAL form: the live gate requires it, so
				# the persistence gate must require it too. Otherwise
				# a checkpoint that passes every v5 gate produces a
				# live inventory in which the whole item subsystem
				# fails closed forever -- and the poison is re-written
				# unchanged on every save.
				if item_id != "item_%06d" % seq or seq < 1:
					result["success"] = false
					result["diagnostics"].append(_error(
						"non_canonical_item_instance_id",
						"item[%d] has a non-canonical instance_id %s"
							% [i, item_id], item_id))
			var item_definition_v: Variant = _strict_str(
				it.get("definition_id", ""), "definition_id", item_id,
				result["diagnostics"])
			if item_definition_v == null:
				result["success"] = false
				item_definition_v = ""
			if String(item_definition_v) == "":
				result["success"] = false
				result["diagnostics"].append(_error(
					"empty_item_definition_id",
					"item[%d] has empty definition_id" % i, item_id))
			var owner_v: Variant = _strict_str(
				it.get("owner_unit_id", ""), "owner_unit_id", item_id,
				result["diagnostics"])
			if owner_v == null:
				result["success"] = false
				owner_v = ""
			var owner: String = String(owner_v)
			# A loose item (no owner) is legal. An owner that names a
			# unit which does not exist is not.
			if owner != "" and not unit_instance_to_idx.has(owner):
				result["success"] = false
				result["diagnostics"].append(_error(
					"unknown_item_owner",
					"item %s owner %s does not exist" % [item_id, owner],
					item_id))

	# Bidirectional equipment consistency.
	for instance_id in item_instance_to_idx.keys():
		var it2: Dictionary = items_value[item_instance_to_idx[instance_id]] as Dictionary
		# The owner id was validated by the strict string helper in the
		# item loop, so it is a String here. The re-read must not crash
		# either: there is no `String(int)` constructor in Godot 4.
		var owner2_value: Variant = it2.get("owner_unit_id", "")
		var owner2: String = owner2_value if owner2_value is String or owner2_value is StringName else ""
		# Invariant A: the item names an owner, but the unit does not
		# list it.
		if owner2 != "" and unit_instance_to_idx.has(owner2):
			var unit_equipped: Array = unit_owner_listings.get(owner2, []) as Array
			if not unit_equipped.has(instance_id):
				result["success"] = false
				result["diagnostics"].append(_error(
					"inconsistent_equip",
					"item %s owned by %s but unit does not list it"
						% [instance_id, owner2], instance_id))
		# Invariant C: the same item id listed by two units.
		var item_in_unit_count: int = 0
		for unit_id in unit_owner_listings.keys():
			var listed: Array = unit_owner_listings[unit_id] as Array
			if listed.has(instance_id):
				item_in_unit_count += 1
		if item_in_unit_count > 1:
			result["success"] = false
			result["diagnostics"].append(_error(
				"item_listed_by_multiple_units",
				"item %s listed by %d units" % [instance_id, item_in_unit_count],
				instance_id))

	# Invariant B: a unit lists an item, but the item has no owner.
	for unit_id in unit_owner_listings.keys():
		var listed2: Array = unit_owner_listings[unit_id] as Array
		for itm2 in listed2:
			var itm_str2: String = String(itm2)
			if not item_instance_to_idx.has(itm_str2):
				result["success"] = false
				result["diagnostics"].append(_error(
					"unknown_item_in_equipped_list",
					"unit %s lists unknown item id %s" % [unit_id, itm_str2],
					unit_id))
				continue
			# The owner id was validated by the strict string helper in the
			# item loop. The re-read must not crash either.
			var owner3_value: Variant = (items_value[item_instance_to_idx[itm_str2]] as Dictionary).get("owner_unit_id", "")
			var owner3: String = owner3_value if owner3_value is String or owner3_value is StringName else ""
			if owner3 == "":
				result["success"] = false
				result["diagnostics"].append(_error(
					"inconsistent_equip",
					"item %s listed by unit %s has empty owner"
						% [itm_str2, unit_id], unit_id))

	# The sequence counters are a MONOTONIC ALLOCATION CURSOR, not
	# "max live id + 1".
	#
	# The allocator never reuses or wraps a consumed id, and a removal
	# does NOT roll the cursor back. A gap between the cursor and the
	# live ids is therefore normal and valid:
	#
	#     live ids [1, 2, 3], next_seq = 4
	#     remove 3
	#     live ids [1, 2],    next_seq = 4   <- valid
	#
	# The invariant that matters is that the cursor is STRICTLY above
	# every live id, so the next allocation can never collide with an
	# existing identity, and that the cursor starts at 1.
	var unit_cursor: int = int(data.get("next_unit_instance_seq", 0))
	if unit_cursor < 1 or unit_cursor <= max_unit_seq:
		result["success"] = false
		result["diagnostics"].append(_error(
			"next_unit_instance_seq_invalid",
			"next_unit_instance_seq must be above every live unit id and at least 1 (max live id %d, got %d)"
				% [max_unit_seq, unit_cursor],
			str(max_unit_seq)))
	var item_cursor: int = int(data.get("next_item_instance_seq", 0))
	if item_cursor < 1 or item_cursor <= max_item_seq:
		result["success"] = false
		result["diagnostics"].append(_error(
			"next_item_instance_seq_invalid",
			"next_item_instance_seq must be above every live item id and at least 1 (max live id %d, got %d)"
				% [max_item_seq, item_cursor],
			str(max_item_seq)))

	return result


## Extracts the numeric sequence of an instance id.
##
## The canonical form is `unit_000001` / `item_000001`: the digits at
## the end are the sequence. An id without the expected prefix or
## without digits has no sequence.
## Extracts the numeric sequence of an instance id.
##
## The canonical form is `unit_000001` / `item_000001`: the digits at
## the end are the sequence. The semantics are EXACTLY the original
## gate's: the remainder must be a valid integer, so a signed form
## such as "+5" is a sequence of 5. A hand-rolled digit loop would
## read "+5" as 0, and the port would then demand a smaller cursor
## than the original and accept a checkpoint the original rejects.
static func _seq_from_instance_id(instance_id: String, prefix: String) -> int:
	if not instance_id.begins_with(prefix):
		return 0
	var rest: String = instance_id.substr(prefix.length(), instance_id.length() - prefix.length())
	if not rest.is_valid_int():
		return 0
	return int(rest)


## Strict string check: the canonical validator accepts a String or a
## StringName only.
static func _strict_str(value: Variant, key: String,
		instance_id: String, diags: Array) -> Variant:
	if typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME:
		return value
	diags.append(_error(
		"unit_field_type_invalid",
		"%s.%s has wrong type %s"
			% [instance_id, key, type_string(typeof(value))],
		instance_id))
	return null


## Strict int check: the canonical validator accepts TYPE_INT only.
##
## The wire layer (SaveSchemaV4._wire_int) is the only place that
## coerces an integral float to an int. A canonical DTO must hold
## ints, not floats.
static func _strict_int(value: Variant, key: String,
		instance_id: String, diags: Array) -> Variant:
	if typeof(value) == TYPE_INT:
		return value
	diags.append(_error(
		"unit_field_type_invalid",
		"%s.%s has wrong type %s (canonical validator accepts only TYPE_INT)"
			% [instance_id, key, type_string(typeof(value))],
		instance_id))
	return null


## Strict bool check: the canonical validator accepts TYPE_BOOL only.
static func _strict_bool(value: Variant, key: String,
		instance_id: String, diags: Array) -> Variant:
	if typeof(value) == TYPE_BOOL:
		return value
	diags.append(_error(
		"unit_field_type_invalid",
		"%s.%s has wrong type %s"
			% [instance_id, key, type_string(typeof(value))],
		instance_id))
	return null


## Strict array check: the canonical validator accepts an Array only.
static func _strict_array(value: Variant, key: String,
		instance_id: String, diags: Array) -> Variant:
	if value is Array:
		return value
	diags.append(_error(
		"unit_field_type_invalid",
		"%s.%s has wrong type %s"
			% [instance_id, key, type_string(typeof(value))],
		instance_id))
	return null


static func _error(code: String, detail: String, context: String) -> RefCounted:
	# MigrationDiagnostic is a class_name, so it is always available.
	# The guard is a safety net only: ClassDB.class_exists() does NOT
	# see a class_name script, so the branch below is the live one.
	if ClassDB.class_exists("MigrationDiagnostic"):
		return MigrationDiagnostic.error(code, detail, context)
	var holder: MigrationDiagnostic = MigrationDiagnostic.new()
	holder.severity = MigrationDiagnostic.Severity.ERROR
	holder.code = code
	holder.detail = detail
	holder.context = context
	return holder
