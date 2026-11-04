class_name RunDomainSemanticValidator
## The semantic validation of the run domain collections.
##
## The checks live here and not in the v1->v4 migrator, because BOTH
## the v4 and the v5 load paths need them:
##
##   - a unit must carry every required key;
##   - a unit instance_id must be present and unique;
##   - a unit location must be 0 or 1;
##   - two units in the same location must not share an order;
##   - current_hp must not exceed max_hp;
##   - an item must have a known owner;
##   - an equipped item must be carried by its owner;
##   - the instance sequence counters must match the highest used id.
##
## The validator is PURE: it never mutates the input and never raises.
##
## Returns `{success: bool, diagnostics: Array[RefCounted]}`.

## The canonical v4 unit shape. The unit carries no `level`: the level
## belongs to the run, not to a unit.
const REQUIRED_UNIT_KEYS: Array[StringName] = [
	&"instance_id", &"definition_id", &"current_hp", &"max_hp",
	&"bonus_attack", &"dead", &"location", &"order", &"equipped_item_ids",
]

## The canonical v4 item shape.
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
	var unit_owner_listings: Dictionary = {}
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
			var instance_id: String = str(u.get("instance_id", ""))
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
				var seq: int = _sequence_of(instance_id)
				if seq > max_unit_seq:
					max_unit_seq = seq
			var location: int = int(u.get("location", -1))
			if location != 0 and location != 1:
				result["success"] = false
				result["diagnostics"].append(_error(
					"unit_location_invalid",
					"unit %s location %d not in {0,1}" % [instance_id, location],
					instance_id))
				continue
			var order: int = int(u.get("order", -1))
			var orders: Dictionary = units_by_location[location]
			if orders.has(order):
				result["success"] = false
				result["diagnostics"].append(_error(
					"duplicate_unit_order_in_location",
					"unit %s duplicates order %d in location %d"
						% [instance_id, order, location], instance_id))
			else:
				orders[order] = instance_id
			units_by_location[location] = orders
			var current_hp: int = int(u.get("current_hp", -1))
			var max_hp: int = int(u.get("max_hp", -1))
			# current_hp = -1 means "not initialised yet"; max_hp = -1
			# means "not known yet". Neither is a violation.
			if current_hp >= 0 and max_hp >= 0 and current_hp > max_hp:
				result["success"] = false
				result["diagnostics"].append(_error(
					"unit_hp_exceeds_max",
					"unit %s current_hp %d exceeds max_hp %d"
						% [instance_id, current_hp, max_hp], instance_id))
			var equipped: Array = u.get("equipped_item_ids", []) as Array
			for e in equipped:
				unit_owner_listings[str(e)] = instance_id

	var max_item_seq: int = 0
	var item_instance_ids: Dictionary = {}
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
			var item_id: String = str(it.get("instance_id", ""))
			if item_id == "":
				result["success"] = false
				result["diagnostics"].append(_error(
					"empty_item_instance_id",
					"item[%d] has empty instance_id" % i, str(i)))
			elif item_instance_ids.has(item_id):
				result["success"] = false
				result["diagnostics"].append(_error(
					"duplicate_item_instance_id",
					"duplicate item instance_id %s" % item_id, item_id))
			else:
				item_instance_ids[item_id] = i
				var seq: int = _sequence_of(item_id)
				if seq > max_item_seq:
					max_item_seq = seq
			var owner: String = str(it.get("owner_unit_id", ""))
			# An item with no owner is a LOOSE item in the inventory:
			# that is legal. Only an owner that names a unit which does
			# not exist is an error.
			if owner != "" and not unit_instance_to_idx.has(owner):
				result["success"] = false
				result["diagnostics"].append(_error(
					"unknown_item_owner",
					"item %s owner %s does not exist" % [item_id, owner], item_id))
			elif owner != "" and unit_owner_listings.has(item_id):
				var declared_owner: String = str(unit_owner_listings[item_id])
				if declared_owner != owner:
					result["success"] = false
					result["diagnostics"].append(_error(
						"inconsistent_equip",
						"item %s is equipped by %s but owned by %s"
							% [item_id, declared_owner, owner], item_id))

	# The sequence counters must match the highest used id plus one.
	var next_unit_seq: int = int(data.get("next_unit_instance_seq", 1))
	if max_unit_seq > 0 and next_unit_seq != max_unit_seq + 1:
		result["success"] = false
		result["diagnostics"].append(_error(
			"unit_instance_seq_mismatch",
			"next_unit_instance_seq %d does not match max used %d + 1"
				% [next_unit_seq, max_unit_seq], "next_unit_instance_seq"))
	var next_item_seq: int = int(data.get("next_item_instance_seq", 1))
	if max_item_seq > 0 and next_item_seq != max_item_seq + 1:
		result["success"] = false
		result["diagnostics"].append(_error(
			"item_instance_seq_mismatch",
			"next_item_instance_seq %d does not match max used %d + 1"
				% [next_item_seq, max_item_seq], "next_item_instance_seq"))

	return result


## Extracts the numeric sequence of an instance id.
##
## The canonical form is `unit_000001` / `item_000001`: the digits at
## the end are the sequence. An id without digits has no sequence.
static func _sequence_of(instance_id: String) -> int:
	var digits: String = ""
	for i in range(instance_id.length() - 1, -1, -1):
		var ch: String = instance_id[i]
		if ch >= "0" and ch <= "9":
			digits = ch + digits
		else:
			break
	if digits.is_empty():
		return 0
	return int(digits)


static func _error(code: String, detail: String, context: String) -> RefCounted:
	if ClassDB.class_exists("MigrationDiagnostic"):
		return MigrationDiagnostic.error(code, detail, context)
	# The fallback keeps the same shape, but it is a plain Dictionary
	# rather than a RefCounted, so it is wrapped.
	var fallback: Dictionary = {
		"code": code,
		"detail": detail,
		"context": context,
		"severity": "error",
	}
	var holder: RefCounted = RefCounted.new()
	holder.set_meta("diagnostic", fallback)
	return holder
