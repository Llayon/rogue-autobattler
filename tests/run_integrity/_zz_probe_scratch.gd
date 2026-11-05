extends SceneTree

## TEMPORARY SCRATCH PROBE — deleted after the review.
## Differential fuzz: RunDomainSemanticValidator.validate vs
## LegacySaveV1ToV4Migrator.validate, over mutated v4 DTOs.

const SemanticScript = preload("res://core/save/run_domain_semantic_validator.gd")
const MigratorScript = preload("res://core/save/legacy_save_v1_to_v4_migrator.gd")

var _passed: int = 0
var _failed: int = 0
var _divergences: Array = []


func _initialize() -> void:
	# --- Probe 1: duplicate_in_unit_equipped (missing from the port) ---
	var dto: Dictionary = _base()
	dto["units"] = [_unit("unit_000001", 0, 10, 10, ["item_000001", "item_000001"])]
	dto["items"] = [_item("item_000001", "unit_000001")]
	dto["next_unit_instance_seq"] = 2
	dto["next_item_instance_seq"] = 2
	_compare("P1 duplicate equipped id in one unit", dto)

	# --- Probe 2: empty_item_definition_id (missing from the port) ---
	var dto2: Dictionary = _base()
	dto2["units"] = [_unit("unit_000001", 0, 10, 10, [])]
	var it: Dictionary = _item("item_000001", "")
	it["definition_id"] = &""
	dto2["items"] = [it]
	dto2["next_unit_instance_seq"] = 2
	dto2["next_item_instance_seq"] = 2
	_compare("P2 empty item definition_id", dto2)

	# --- Probe 3: type-invalid field (float current_hp) ---
	var dto3: Dictionary = _base()
	var u3: Dictionary = _unit("unit_000001", 0, 10, 10, [])
	u3["current_hp"] = 10.0
	dto3["units"] = [u3]
	dto3["next_unit_instance_seq"] = 2
	_compare("P3 float current_hp", dto3)

	# --- Probe 4: unit location invalid -> is an order still registered? ---
	var dto4: Dictionary = _base()
	var u4: Dictionary = _unit("unit_000001", 0, 10, 10, [])
	u4["location"] = 7
	dto4["units"] = [u4]
	dto4["next_unit_instance_seq"] = 2
	_compare("P4 unit location 7, order 0", dto4)

	# --- Probe 5: duplicate unit instance_id -> counted for seq max? ---
	var dto5: Dictionary = _base()
	dto5["units"] = [
		_unit("unit_000001", 0, 10, 10, []),
		_unit("unit_000001", 1, 10, 10, []),
	]
	dto5["next_unit_instance_seq"] = 2
	_compare("P5 duplicate unit instance_id", dto5)

	# --- Probe 6: no items -> next_item_instance_seq must be 1 ---
	var dto6: Dictionary = _base()
	dto6["units"] = [_unit("unit_000001", 0, 10, 10, [])]
	dto6["next_unit_instance_seq"] = 2
	dto6["next_item_instance_seq"] = 5
	_compare("P6 no items, next_item_instance_seq=5", dto6)

	# --- Probe 7: no units -> next_unit_instance_seq must be 1 ---
	var dto7: Dictionary = _base()
	dto7["next_unit_instance_seq"] = 3
	_compare("P7 no units, next_unit_instance_seq=3", dto7)

	# --- Probe 8: dead flag type-invalid ---
	var dto8: Dictionary = _base()
	var u8: Dictionary = _unit("unit_000001", 0, 10, 10, [])
	u8["dead"] = "yes"
	dto8["units"] = [u8]
	dto8["next_unit_instance_seq"] = 2
	_compare("P8 dead is a String", dto8)

	# --- Probe 9: bonus_attack type-invalid ---
	var dto9: Dictionary = _base()
	var u9: Dictionary = _unit("unit_000001", 0, 10, 10, [])
	u9["bonus_attack"] = 1.5
	dto9["units"] = [u9]
	dto9["next_unit_instance_seq"] = 2
	_compare("P9 bonus_attack is a float", dto9)

	# --- Probe 10: equipped_item_ids is not an Array ---
	var dto10: Dictionary = _base()
	var u10: Dictionary = _unit("unit_000001", 0, 10, 10, [])
	u10["equipped_item_ids"] = "nope"
	dto10["units"] = [u10]
	dto10["next_unit_instance_seq"] = 2
	_compare("P10 equipped_item_ids is a String", dto10)

	# --- Probe 11: owner_unit_id is an int ---
	var dto11: Dictionary = _base()
	dto11["units"] = [_unit("unit_000001", 0, 10, 10, [])]
	var it11: Dictionary = _item("item_000001", "")
	it11["owner_unit_id"] = 5
	dto11["items"] = [it11]
	dto11["next_unit_instance_seq"] = 2
	dto11["next_item_instance_seq"] = 2
	_compare("P11 owner_unit_id is an int", dto11)

	# --- Probe 12: instance_id is an int ---
	var dto12: Dictionary = _base()
	var u12: Dictionary = _unit("unit_000001", 0, 10, 10, [])
	u12["instance_id"] = 77
	dto12["units"] = [u12]
	dto12["next_unit_instance_seq"] = 2
	_compare("P12 instance_id is an int", dto12)

	# --- Probe 13: definition_id is an int (unit) ---
	var dto13: Dictionary = _base()
	var u13: Dictionary = _unit("unit_000001", 0, 10, 10, [])
	u13["definition_id"] = 3
	dto13["units"] = [u13]
	dto13["next_unit_instance_seq"] = 2
	_compare("P13 unit definition_id is an int", dto13)

	# --- Probe 14: order is a float ---
	var dto14: Dictionary = _base()
	var u14: Dictionary = _unit("unit_000001", 0.0, 10, 10, [])
	dto14["units"] = [u14]
	dto14["next_unit_instance_seq"] = 2
	_compare("P14 order is a float", dto14)

	# --- Probe 15: equipped_item_ids contains a non-string ---
	var dto15: Dictionary = _base()
	var u15: Dictionary = _unit("unit_000001", 0, 10, 10, [5])
	dto15["units"] = [u15]
	dto15["next_unit_instance_seq"] = 2
	_compare("P15 equipped list contains an int", dto15)

	print("")
	print("=== PROBE SUMMARY: %d pass / %d fail ===" % [_passed, _failed])
	if _divergences.size() > 0:
		print("=== DIVERGENCES (%d) ===" % _divergences.size())
		for d in _divergences:
			print("  ", d)
	quit(0)


func _compare(label: String, dto: Dictionary) -> void:
	var new_gate: Dictionary = SemanticScript.validate(dto)
	var old_gate: Dictionary = MigratorScript.validate(dto)
	var new_ok: bool = bool(new_gate.get("success", false))
	var old_ok: bool = bool(old_gate.get("success", false))
	var new_codes: Array = _codes(new_gate)
	var old_codes: Array = _codes(old_gate)
	if new_ok == old_ok:
		_passed += 1
		print("[AGREE]   %s -> new=%s old=%s" % [label, str(new_ok), str(old_ok)])
	else:
		_failed += 1
		print("[DIVERGE] %s -> new=%s old=%s" % [label, str(new_ok), str(old_ok)])
		print("           new codes: ", new_codes)
		print("           old codes: ", old_codes)
		_divergences.append("%s :: new=%s old=%s | new=%s | old=%s"
			% [label, str(new_ok), str(old_ok), str(new_codes), str(old_codes)])


func _codes(result: Dictionary) -> Array:
	var out: Array = []
	for d in result.get("diagnostics", []):
		if d is RefCounted and "code" in d:
			out.append(str(d.code))
		else:
			out.append(str(d))
	return out


func _base() -> Dictionary:
	return {
		"schema_version": 4, "game_build": "", "run_id": "run_1", "seed": 1,
		"round_index": 1, "phase": "prep", "gold": 0, "units": [], "items": [],
		"next_unit_instance_seq": 1, "next_item_instance_seq": 1,
		"shop": {}, "map": {}, "rewards": {}, "wins": 0, "losses": 0,
		"units_killed": 0, "lives": 3, "xp": 0, "level": 1,
		"current_encounter_id": -1, "encounter_visited_ids": [],
		"meta_modifiers": {}, "just_visited_merchant": false,
	}


func _unit(id: String, order: int, hp: int, max_hp: int, equipped: Array) -> Dictionary:
	return {
		"instance_id": id, "definition_id": &"warrior", "current_hp": hp,
		"max_hp": max_hp, "bonus_attack": 0, "dead": false,
		"location": 0, "order": order, "equipped_item_ids": equipped,
	}


func _item(id: String, owner: String) -> Dictionary:
	return {
		"instance_id": id, "definition_id": &"potion_strength",
		"owner_unit_id": owner,
	}
