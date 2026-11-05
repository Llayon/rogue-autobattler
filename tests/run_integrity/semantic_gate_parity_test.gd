extends SceneTree

## The extracted semantic validator must AGREE with the original v4
## gate, case by case.
##
## `RunDomainSemanticValidator` is a port of
## `LegacySaveV1ToV4Migrator.validate`. If the port drops, weakens or
## adds a check, the v5 load path becomes STRONGER or WEAKER than the
## v4 one — and the v5 path is the one the production resume uses.
##
## The previous critic found exactly that: the bidirectional equipment
## consistency (the item names an owner but the unit does not list it,
## and the unit lists the item but the item has no owner) was missing
## from the port, so the v5 path ACCEPTED checkpoints the v4 path
## REJECTED.
##
## This suite is the differential: for every case the two gates must
## produce the same accept/reject decision.

const SemanticScript = preload("res://core/save/run_domain_semantic_validator.gd")
const MigratorScript = preload("res://core/save/legacy_save_v1_to_v4_migrator.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	_case_A_owner_set_unit_does_not_list_it()
	_case_B_unit_lists_it_item_has_no_owner()
	_case_C_item_listed_by_two_units()
	_case_D_unknown_item_in_equipped_list()
	_case_E_current_hp_above_max()
	_case_F_current_hp_below_sentinel()
	_case_G_negative_order()
	_case_H_duplicate_order_in_location()
	_case_I_duplicate_unit_instance_id()
	_case_J_duplicate_item_instance_id()
	_case_K_empty_definition_id()
	_case_L_sequence_counters()
	_case_M_a_clean_state_is_accepted()
	_case_N_the_missing_owner_unit()
	_case_O_an_item_with_an_unknown_owner()
	_case_P_a_float_instead_of_an_int()
	_case_Q_a_string_instead_of_a_bool()
	_case_R_a_duplicate_equipped_entry()
	_case_S_an_empty_item_definition_id()
	_case_T_an_int_instead_of_a_string()
	_case_U_a_non_array_equipped_list()
	_case_V_a_numeric_unit_instance_id()
	_case_W_a_numeric_item_instance_id()
	_case_X_a_numeric_owner_unit_id()
	_case_Y_a_signed_instance_id_sequence()
	print("")
	print("=== STAGE 3E: SEMANTIC GATE PARITY: %d pass / %d fail ===" % [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A valid, minimal v4 DTO.
func _base() -> Dictionary:
	return {
		"schema_version": 4, "game_build": "", "run_id": "run_1", "seed": 1,
		"round_index": 1, "phase": "prep", "gold": 0, "units": [], "items": [],
		"next_unit_instance_seq": 1, "next_item_instance_seq": 1,
		"shop": {}, "map": {}, "rewards": {}, "rng": {}, "wins": 0, "losses": 0,
		"units_killed": 0, "lives": 3, "xp": 0, "level": 1,
		"current_encounter_id": -1, "encounter_visited_ids": [],
		"meta_modifiers": {}, "just_visited_merchant": false,
	}


func _unit(id: Variant, order: int, hp: int, max_hp: int, equipped: Array) -> Dictionary:
	return {
		"instance_id": id, "definition_id": &"warrior", "current_hp": hp,
		"max_hp": max_hp, "bonus_attack": 0, "dead": false,
		"location": 0, "order": order, "equipped_item_ids": equipped,
	}


func _item(id: Variant, owner: Variant) -> Dictionary:
	return {
		"instance_id": id, "definition_id": &"potion_strength",
		"owner_unit_id": owner,
	}


## The two gates must agree on the accept/reject decision.
func _agree(label: String, dto: Dictionary) -> void:
	var new_gate: Dictionary = SemanticScript.validate(dto)
	var old_gate: Dictionary = MigratorScript.validate(dto)
	var new_ok: bool = bool(new_gate.get("success", false))
	var old_ok: bool = bool(old_gate.get("success", false))
	_assert(new_ok == old_ok,
		"%s: the extracted gate and the original gate agree (new=%s, old=%s)"
			% [label, str(new_ok), str(old_ok)])


func _case_A_owner_set_unit_does_not_list_it() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_000001", 0, 10, 10, [])]
	dto["items"] = [_item("item_000001", "unit_000001")]
	dto["next_unit_instance_seq"] = 2
	dto["next_item_instance_seq"] = 2
	_agree("A: the item names an owner but the unit does not list it", dto)


func _case_B_unit_lists_it_item_has_no_owner() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_000001", 0, 10, 10, ["item_000001"])]
	dto["items"] = [_item("item_000001", "")]
	dto["next_unit_instance_seq"] = 2
	dto["next_item_instance_seq"] = 2
	_agree("B: the unit lists the item but the item has no owner", dto)


func _case_C_item_listed_by_two_units() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [
		_unit("unit_000001", 0, 10, 10, ["item_000001"]),
		_unit("unit_000002", 1, 10, 10, ["item_000001"]),
	]
	dto["items"] = [_item("item_000001", "unit_000001")]
	dto["next_unit_instance_seq"] = 3
	dto["next_item_instance_seq"] = 2
	_agree("C: the same item is listed by two units", dto)


func _case_D_unknown_item_in_equipped_list() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_000001", 0, 10, 10, ["item_999999"])]
	dto["next_unit_instance_seq"] = 2
	_agree("D: the unit lists an item that does not exist", dto)


func _case_E_current_hp_above_max() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_000001", 0, 999, 10, [])]
	dto["next_unit_instance_seq"] = 2
	_agree("E: current_hp is above max_hp", dto)


func _case_F_current_hp_below_sentinel() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_000001", 0, -5, 10, [])]
	dto["next_unit_instance_seq"] = 2
	_agree("F: current_hp is below the -1 sentinel", dto)


func _case_G_negative_order() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_000001", -1, 10, 10, [])]
	dto["next_unit_instance_seq"] = 2
	_agree("G: the order is negative", dto)


func _case_H_duplicate_order_in_location() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [
		_unit("unit_000001", 0, 10, 10, []),
		_unit("unit_000002", 0, 10, 10, []),
	]
	dto["next_unit_instance_seq"] = 3
	_agree("H: two units share an order in one location", dto)


func _case_I_duplicate_unit_instance_id() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [
		_unit("unit_000001", 0, 10, 10, []),
		_unit("unit_000001", 1, 10, 10, []),
	]
	dto["next_unit_instance_seq"] = 2
	_agree("I: two units share an instance_id", dto)


func _case_J_duplicate_item_instance_id() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_000001", 0, 10, 10, [])]
	dto["items"] = [_item("item_000001", ""), _item("item_000001", "")]
	dto["next_unit_instance_seq"] = 2
	dto["next_item_instance_seq"] = 2
	_agree("J: two items share an instance_id", dto)


func _case_K_empty_definition_id() -> void:
	var dto: Dictionary = _base()
	var unit: Dictionary = _unit("unit_000001", 0, 10, 10, [])
	unit["definition_id"] = &""
	dto["units"] = [unit]
	dto["next_unit_instance_seq"] = 2
	_agree("K: the unit has an empty definition_id", dto)


func _case_L_sequence_counters() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_000001", 0, 10, 10, [])]
	dto["next_unit_instance_seq"] = 5
	_agree("L: the unit sequence counter does not match the used ids", dto)


func _case_M_a_clean_state_is_accepted() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_000001", 0, 10, 10, [])]
	dto["items"] = [_item("item_000001", "unit_000001")]
	dto["next_unit_instance_seq"] = 2
	dto["next_item_instance_seq"] = 2
	# The equipped item must be listed by its owner for a clean state.
	var unit: Dictionary = (dto["units"] as Array)[0] as Dictionary
	unit["equipped_item_ids"] = ["item_000001"]
	_agree("M: a consistent state is accepted by both gates", dto)


func _case_N_the_missing_owner_unit() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_000001", 0, 10, 10, [])]
	dto["items"] = [_item("item_000001", "unit_000009")]
	dto["next_unit_instance_seq"] = 2
	dto["next_item_instance_seq"] = 2
	_agree("N: the item names an owner that does not exist", dto)


func _case_O_an_item_with_an_unknown_owner() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_000001", 0, 10, 10, [])]
	dto["items"] = [_item("item_000001", "")]
	dto["next_unit_instance_seq"] = 2
	dto["next_item_instance_seq"] = 2
	_agree("O: a loose item with no owner is legal", dto)


## The original gate reads the unit fields with STRICT helpers: an int
## field must hold TYPE_INT, a bool field TYPE_BOOL, a string field a
## String or a StringName, and the equipped list an Array. The
## extracted gate must reject exactly the same inputs.
func _case_P_a_float_instead_of_an_int() -> void:
	var dto: Dictionary = _base()
	var unit: Dictionary = _unit("unit_000001", 0, 10, 10, [])
	unit["current_hp"] = 10.0
	dto["units"] = [unit]
	dto["next_unit_instance_seq"] = 2
	_agree("P: current_hp is a float instead of an int", dto)


func _case_Q_a_string_instead_of_a_bool() -> void:
	var dto: Dictionary = _base()
	var unit: Dictionary = _unit("unit_000001", 0, 10, 10, [])
	unit["dead"] = "no"
	dto["units"] = [unit]
	dto["next_unit_instance_seq"] = 2
	_agree("Q: dead is a string instead of a bool", dto)


func _case_R_a_duplicate_equipped_entry() -> void:
	var dto: Dictionary = _base()
	var unit: Dictionary = _unit("unit_000001", 0, 10, 10, ["item_000001", "item_000001"])
	dto["units"] = [unit]
	dto["items"] = [_item("item_000001", "unit_000001")]
	dto["next_unit_instance_seq"] = 2
	dto["next_item_instance_seq"] = 2
	_agree("R: one unit lists the same item twice", dto)


func _case_S_an_empty_item_definition_id() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_000001", 0, 10, 10, [])]
	dto["items"] = [_item("item_000001", "")]
	dto["items"][0]["definition_id"] = &""
	dto["next_unit_instance_seq"] = 2
	dto["next_item_instance_seq"] = 2
	_agree("S: the item has an empty definition_id", dto)


func _case_T_an_int_instead_of_a_string() -> void:
	var dto: Dictionary = _base()
	var unit: Dictionary = _unit("unit_000001", 0, 10, 10, [])
	unit["definition_id"] = 42
	dto["units"] = [unit]
	dto["next_unit_instance_seq"] = 2
	_agree("T: definition_id is an int instead of a string", dto)


func _case_U_a_non_array_equipped_list() -> void:
	var dto: Dictionary = _base()
	var unit: Dictionary = _unit("unit_000001", 0, 10, 10, [])
	unit["equipped_item_ids"] = "item_000001"
	dto["units"] = [unit]
	dto["next_unit_instance_seq"] = 2
	_agree("U: equipped_item_ids is not an array", dto)


## The instance ids and the owner id are read through the strict
## string helper in the original gate. The port must do the same: a
## numeric id must be REJECTED, not crash the validator (there is no
## `String(int)` constructor in Godot 4).
func _case_V_a_numeric_unit_instance_id() -> void:
	var dto: Dictionary = _base()
	var unit: Dictionary = _unit("unit_000001", 0, 10, 10, [])
	unit["instance_id"] = 1
	dto["units"] = [unit]
	dto["next_unit_instance_seq"] = 2
	_agree("V: the unit instance_id is a number", dto)


func _case_W_a_numeric_item_instance_id() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_000001", 0, 10, 10, [])]
	dto["items"] = [_item("item_000001", "")]
	dto["items"][0]["instance_id"] = 1
	dto["next_unit_instance_seq"] = 2
	dto["next_item_instance_seq"] = 2
	_agree("W: the item instance_id is a number", dto)


func _case_X_a_numeric_owner_unit_id() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_000001", 0, 10, 10, [])]
	dto["items"] = [_item("item_000001", "")]
	dto["items"][0]["owner_unit_id"] = 1
	dto["next_unit_instance_seq"] = 2
	dto["next_item_instance_seq"] = 2
	_agree("X: the item owner_unit_id is a number", dto)


## The sequence extraction accepts a signed integer, exactly like the
## original: `is_valid_int()` accepts "+5". The port read "+5" as 0,
## so it demanded a SMALLER cursor than the original and accepted a
## checkpoint the original rejects.
func _case_Y_a_signed_instance_id_sequence() -> void:
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_+5", 0, 10, 10, [])]
	# The original reads the sequence as 5, so the cursor must be > 5.
	dto["next_unit_instance_seq"] = 1
	_agree("Y: a signed instance id has the signed sequence", dto)


# ----------------------------------------------------------------


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage 3E: %s" % label)
