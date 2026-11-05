extends SceneTree

## The instance-sequence counters are a MONOTONIC ALLOCATION CURSOR,
## not "max live id + 1".
##
## The allocator never reuses or wraps a consumed id: "the allocator is
## monotonic and never reuses or wraps a consumed id"
## (core/progression/run_domain_state.gd:42). Removing an entity does
## NOT roll the cursor back, so a gap is normal:
##
##     live ids [1, 2, 3], next_seq = 4
##     remove 3
##     live ids [1, 2],    next_seq = 4   <- valid
##
## The old gate required `next_seq == max_live_id + 1`, which rejects
## that perfectly valid state: 4 == 2 + 1 is false. The run could then
## never be saved again. The defect exists in the baseline as well.
##
## The invariant that actually matters:
##
##     next_seq > max_live_id   -- the next id cannot collide
##     next_seq >= 1            -- the cursor starts at 1
##
## A gap is valid: live ids [1, 5] with next_seq = 100 is valid. But
## next_seq = 5 or next_seq = 4 with those live ids is NOT: the future
## allocation could collide with an existing identity.

const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const SemanticScript = preload("res://core/save/run_domain_semantic_validator.gd")
const MigratorScript = preload("res://core/save/legacy_save_v1_to_v4_migrator.gd")
const RunDomainStateScript = preload("res://core/progression/run_domain_state.gd")
const RunItemScript = preload("res://core/progression/run_item.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_A_the_live_state_stays_saveable_after_a_removal()
	await _test_B_a_gap_is_valid()
	await _test_C_a_cursor_at_the_max_live_id_is_invalid()
	await _test_D_a_cursor_below_the_max_live_id_is_invalid()
	await _test_E_a_cursor_below_one_is_invalid()
	await _test_F_the_two_gates_agree_on_the_cursor()
	print("")
	print("=== STAGE 3E: SEQUENCE CURSOR CONTRACT: %d pass / %d fail ===" % [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## The live state: grant three items, remove the highest, and the DTO
## built from it must still pass the gate and still be saveable.
func _test_A_the_live_state_stays_saveable_after_a_removal() -> void:
	var state = RunDomainStateScript.new()
	state.seed = 555
	for i in 3:
		var item = RunItemScript.new()
		item.instance_id = state.allocate_item_instance_id()
		item.definition_id = &"potion_strength"
		state.items.append(item)
	var before: int = state.next_item_instance_seq
	var removed: bool = state.remove_item("item_000003")
	_assert(removed, "the highest item is removed")
	_assert(state.next_item_instance_seq == before,
		"the cursor does NOT roll back after a removal (got %d, want %d)"
			% [state.next_item_instance_seq, before])
	var dto: Dictionary = {
		"schema_version": 4, "game_build": "", "run_id": "run_555", "seed": 555,
		"round_index": 1, "phase": "prep", "gold": 0,
		"units": [], "items": [],
		"next_unit_instance_seq": 1, "next_item_instance_seq": state.next_item_instance_seq,
		"shop": {}, "map": {}, "rewards": {}, "rng": {}, "wins": 0, "losses": 0,
		"units_killed": 0, "lives": 3, "xp": 0, "level": 1,
		"current_encounter_id": -1, "encounter_visited_ids": [],
		"meta_modifiers": {}, "just_visited_merchant": false,
	}
	for item in state.items:
		dto["items"].append({
			"instance_id": item.instance_id,
			"definition_id": item.definition_id,
			"owner_unit_id": item.owner_unit_id,
		})
	var gate: Dictionary = SemanticScript.validate(dto)
	_assert(bool(gate.get("success", false)),
		"the live state after a removal passes the gate (%s)"
			% str(_first_code(gate)))


## A gap is valid: the cursor may be far ahead.
func _test_B_a_gap_is_valid() -> void:
	var dto: Dictionary = _dto_with_item_ids(["item_000001", "item_000005"], 100)
	var gate: Dictionary = SemanticScript.validate(dto)
	_assert(bool(gate.get("success", false)),
		"a cursor far ahead of the live ids is valid (%s)"
			% str(_first_code(gate)))


## The cursor must be STRICTLY above the max live id.
func _test_C_a_cursor_at_the_max_live_id_is_invalid() -> void:
	var dto: Dictionary = _dto_with_item_ids(["item_000001", "item_000005"], 5)
	var gate: Dictionary = SemanticScript.validate(dto)
	_assert(not bool(gate.get("success", true)),
		"a cursor equal to the max live id is rejected")


func _test_D_a_cursor_below_the_max_live_id_is_invalid() -> void:
	var dto: Dictionary = _dto_with_item_ids(["item_000001", "item_000005"], 4)
	var gate: Dictionary = SemanticScript.validate(dto)
	_assert(not bool(gate.get("success", true)),
		"a cursor below the max live id is rejected")


func _test_E_a_cursor_below_one_is_invalid() -> void:
	var dto: Dictionary = _dto_with_item_ids([], 0)
	var gate: Dictionary = SemanticScript.validate(dto)
	_assert(not bool(gate.get("success", true)),
		"a cursor below one is rejected")


## The extracted gate and the original gate must agree.
func _test_F_the_two_gates_agree_on_the_cursor() -> void:
	var cases: Array = [
		_dto_with_item_ids([], 1),
		_dto_with_item_ids([], 0),
		_dto_with_item_ids(["item_000001"], 2),
		_dto_with_item_ids(["item_000001"], 1),
		_dto_with_item_ids(["item_000001", "item_000005"], 6),
		_dto_with_item_ids(["item_000001", "item_000005"], 5),
		_dto_with_item_ids(["item_000001", "item_000005"], 100),
		_dto_with_item_ids(["item_000001", "item_000005"], 0),
	]
	for dto in cases:
		var new_ok: bool = bool(SemanticScript.validate(dto).get("success", false))
		var old_ok: bool = bool(MigratorScript.validate(dto).get("success", false))
		_assert(new_ok == old_ok,
			"the two gates agree on the cursor %d" % int(dto.get("next_item_instance_seq", 0)))


# ----------------------------------------------------------------


func _dto_with_item_ids(ids: Array, cursor: int) -> Dictionary:
	var dto: Dictionary = {
		"schema_version": 4, "game_build": "", "run_id": "run_555", "seed": 555,
		"round_index": 1, "phase": "prep", "gold": 0,
		"units": [], "items": [],
		"next_unit_instance_seq": 1, "next_item_instance_seq": cursor,
		"shop": {}, "map": {}, "rewards": {}, "rng": {}, "wins": 0, "losses": 0,
		"units_killed": 0, "lives": 3, "xp": 0, "level": 1,
		"current_encounter_id": -1, "encounter_visited_ids": [],
		"meta_modifiers": {}, "just_visited_merchant": false,
	}
	for id in ids:
		dto["items"].append({
			"instance_id": String(id),
			"definition_id": &"potion_strength",
			"owner_unit_id": "",
		})
	return dto


func _first_code(gate: Dictionary) -> String:
	var diagnostics: Array = gate.get("diagnostics", []) as Array
	if diagnostics.is_empty():
		return ""
	var first: Object = diagnostics[0] as Object
	return String(first.get("code"))


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage 3E: %s" % label)
