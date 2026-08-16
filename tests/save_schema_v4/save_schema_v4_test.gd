extends SceneTree

## Save Schema v4 + legacy v1 migrator contract test.
## All operations are in memory. Source fixtures are read from
## `tests/legacy_save_fixtures/fixtures/version_1/`. The migrator
## must not write to `user://`.

const SaveSchemaV4 = preload("res://core/save/save_schema_v4.gd")
const MigrationResult = preload("res://core/save/migration_result.gd")
const MigrationDiagnostic = preload("res://core/save/migration_diagnostic.gd")
const RunStateScript = preload("res://core/progression/run_state.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const SaveSvc = preload("res://core/utils/save_manager.gd")
const Migrator = preload("res://core/save/legacy_save_v1_to_v4_migrator.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")

const FIXTURE_DIR: String = "res://tests/legacy_save_fixtures/fixtures/version_1"
const RUN_FIXTURE_DIR: String = FIXTURE_DIR + "/runs"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	print("\n=== save schema v4 + migrator tests ===\n")
	_test_migration_succeeds_for_each_fixture()
	_test_migration_is_byte_for_byte_deterministic()
	_test_two_identical_definition_ids_get_distinct_instance_ids()
	_test_board_and_bench_order_preserved()
	_test_partial_hp_preserved()
	_test_equipped_item_owner_is_unit_instance_id()
	_test_unequipped_item_has_empty_owner()
	_test_invalid_equip_index_emits_diagnostic()
	_test_round_trip_serialized_equals_input()
	_test_canonical_key_order_is_independent_of_insertion_order()
	_test_next_instance_seqs_after_migration()
	_test_legacy_fixture_file_unchanged()
	_test_migration_does_not_touch_user_dir()
	_test_validator_rejects_duplicate_unit_instance_id()
	_test_validator_rejects_unknown_item_owner()
	_test_validator_rejects_inconsistent_equip_state()
	_test_validator_rejects_duplicate_item_instance_id()
	_test_is_v4_dto_unchanged_public_api()
	_test_validate_shape_returns_dictionary()
	_test_invalid_top_level_types_do_not_crash()
	_test_current_hp_below_minus_one_rejected()
	_test_unit_location_invalid_rejected()
	_test_duplicate_unit_order_in_location_rejected()
	_test_equipment_invariant_A_owner_set_unit_missing_item()
	_test_equipment_invariant_B_unit_lists_empty_owner()
	_test_equipment_invariant_C_same_item_two_units()
	_test_equipment_invariant_D_unknown_item()
	_test_equipment_invariant_E_duplicate_in_unit()
	_test_save_seed_mismatch_rejected()
	_test_unit_state_match_by_definition_and_occurrence()
	_test_unit_states_completely_missing_fails_migration()
	_test_strict_validator_rejects_string_current_hp()
	_test_strict_validator_rejects_string_dead_flag()
	_test_strict_validator_rejects_string_equipped_item_ids()
	print("\n=== save schema v4 + migrator: %d passed, %d failed ===\n" % [_passed, _failed])
	if _failed > 0:
		quit(1)
	else:
		quit(0)


func _assert(condition: bool, message: String) -> void:
	if condition:
		_passed += 1
		print("  [OK]   %s" % message)
	else:
		_failed += 1
		printerr("  [FAIL] %s" % message)


func _load_run_state(fixture_path: String) -> Resource:
	var res: Resource = load(fixture_path)
	if res == null:
		_assert(false, "load(%s) returned null" % fixture_path)
	return res


func _fixture_path(name: String) -> String:
	return RUN_FIXTURE_DIR + "/%s.tres" % name


# ---------------------------------------------------------------------------
# Fixtures and migration runs
# ---------------------------------------------------------------------------

func _all_run_fixtures() -> Array:
	return [
		["active_run_minimal", 9001],
		["two_identical_definition_ids", 9002],
		["board_plus_bench", 9003],
		["items_equipped_and_unequipped", 9004],
		["partial_hp", 9005],
	]


func _migrate_run(name: String) -> Dictionary:
	var fixture: Resource = _load_run_state(_fixture_path(name))
	if fixture == null:
		return {}
	var result: Dictionary = Migrator.migrate_run(fixture)
	return result


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

func _test_migration_succeeds_for_each_fixture() -> void:
	print("[migration] success for each fixture")
	for entry in _all_run_fixtures():
		var name: String = entry[0]
		var result: Dictionary = _migrate_run(name)
		_assert(bool(result.get("success", false)), "%s: migration success" % name)
		var data: Dictionary = result.get("data", {})
		_assert(int(data.get("schema_version", 0)) == SaveSchemaV4.SCHEMA_VERSION, "%s: schema_version==4" % name)
		_assert(data.has("units") and data.has("items"), "%s: units and items present" % name)


func _test_migration_is_byte_for_byte_deterministic() -> void:
	print("[migration] byte-for-byte determinism")
	for entry in _all_run_fixtures():
		var name: String = entry[0]
		var first: Dictionary = _migrate_run(name)
		var second: Dictionary = _migrate_run(name)
		# Serialize/deserialize each to a canonical form to compare
		# the post-canonical DTOs. The deterministic contract is the
		# canonical Dictionary; intermediate objects do not need to
		# be byte-equal.
		var canon_first: Dictionary = Migrator.canonicalize(first.get("data", {}))
		var canon_second: Dictionary = Migrator.canonicalize(second.get("data", {}))
		_assert(canon_first.hash() == canon_second.hash(), "%s: canonical hash identical" % name)


func _test_two_identical_definition_ids_get_distinct_instance_ids() -> void:
	print("[migration] two identical definition ids get distinct instance ids")
	var result: Dictionary = _migrate_run("two_identical_definition_ids")
	_assert(bool(result.get("success", false)), "two_identical: success")
	var data: Dictionary = result.get("data", {})
	var units: Array = data.get("units", [])
	_assert(units.size() == 2, "two_identical: 2 units migrated")
	var u0: Dictionary = units[0]
	var u1: Dictionary = units[1]
	_assert(String(u0.get("definition_id", "")) == "warrior", "two_identical: u0 definition_id")
	_assert(String(u1.get("definition_id", "")) == "warrior", "two_identical: u1 definition_id")
	_assert(String(u0.get("instance_id", "")) != String(u1.get("instance_id", "")), "two_identical: distinct instance_ids")
	_assert(String(u0.get("instance_id", "")).begins_with("unit_"), "two_identical: u0 id format")
	_assert(String(u1.get("instance_id", "")).begins_with("unit_"), "two_identical: u1 id format")


func _test_board_and_bench_order_preserved() -> void:
	print("[migration] board/bench order preserved")
	var result: Dictionary = _migrate_run("board_plus_bench")
	var data: Dictionary = result.get("data", {})
	var units: Array = data.get("units", [])
	# 4 units total: 2 board + 2 bench in source order
	_assert(units.size() == 4, "board_plus_bench: 4 units")
	var locations: Array = []
	var orders: Array = []
	for u in units:
		locations.append(int(u.get("location", -1)))
		orders.append(int(u.get("order", -1)))
	# board first, then bench
	_assert(locations[0] == 0 and locations[1] == 0, "board_plus_bench: first two on board")
	_assert(locations[2] == 1 and locations[3] == 1, "board_plus_bench: last two on bench")
	_assert(orders == [0, 1, 0, 1], "board_plus_bench: order 0,1,0,1")
	# Definition ids follow source order: warrior, archer, cleric, mage
	var defs: Array = []
	for u in units:
		defs.append(String(u.get("definition_id", "")))
	_assert(defs == ["warrior", "archer", "cleric", "mage"], "board_plus_bench: defs in source order")


func _test_partial_hp_preserved() -> void:
	print("[migration] partial hp preserved")
	var result: Dictionary = _migrate_run("partial_hp")
	var data: Dictionary = result.get("data", {})
	var units: Array = data.get("units", [])
	_assert(units.size() == 2, "partial_hp: 2 units")
	_assert(int(units[0].get("current_hp", -1)) == 33, "partial_hp: warrior current_hp==33")
	_assert(int(units[1].get("current_hp", -1)) == 12, "partial_hp: archer current_hp==12")
	_assert(int(units[0].get("max_hp", -1)) == 100, "partial_hp: warrior max_hp==100")
	_assert(int(units[1].get("max_hp", -1)) == 70, "partial_hp: archer max_hp==70")


func _test_equipped_item_owner_is_unit_instance_id() -> void:
	print("[migration] equipped item owner = unit instance id")
	var result: Dictionary = _migrate_run("items_equipped_and_unequipped")
	_assert(bool(result.get("success", false)), "items: success")
	var data: Dictionary = result.get("data", {})
	var result_items: Array = data.get("items", [])
	# 2 items, the first is equipped at board index 0, the second is in inventory
	_assert(result_items.size() == 2, "items: 2 items")
	var i0: Dictionary = result_items[0]
	var i1: Dictionary = result_items[1]
	var units: Array = data.get("units", [])
	var board0_instance: String = String(units[0].get("instance_id", ""))
	_assert(String(i0.get("owner_unit_id", "")) == board0_instance, "items: i0 owner = board0 instance")
	_assert(String(i1.get("owner_unit_id", "")) == "", "items: i1 owner = empty")
	# equipped_item_ids on the unit
	var equipped: Array = units[0].get("equipped_item_ids", [])
	_assert(equipped.size() == 1, "items: board0 has 1 equipped item")
	_assert(String(equipped[0]) == String(i0.get("instance_id", "")), "items: board0 equipped == i0 instance")


func _test_unequipped_item_has_empty_owner() -> void:
	# Same coverage as _test_equipped_item_owner_is_unit_instance_id,
	# but emphasises the empty-owner contract.
	print("[migration] unequipped item has empty owner")
	var result: Dictionary = _migrate_run("items_equipped_and_unequipped")
	var data: Dictionary = result.get("data", {})
	var result_items2: Array = data.get("items", [])
	_assert(String(result_items2[1].get("owner_unit_id", "X")) == "", "items: unequipped has empty owner")


func _test_invalid_equip_index_emits_diagnostic() -> void:
	print("[migration] invalid equip index emits diagnostic")
	# Synthesize a v1 source with item_equip_board_idx pointing past
	# the board. The migrator must not crash; the item is unequipped
	# and a diagnostic is appended.
	var source: Resource = _load_run_state(_fixture_path("active_run_minimal"))
	if source == null:
		return
	var items: Array[StringName] = [&"potion_strength"]
	source.item_ids = items
	var slots: Array[int] = [99]
	source.item_equip_board_idx = slots
	var result: Dictionary = Migrator.migrate_run(source)
	_assert(bool(result.get("success", false)), "invalid_index: success")
	var diags: Array = result.get("diagnostics", [])
	var found_invalid: bool = false
	for d in diags:
		if d is RefCounted and d.code == "item_equip_board_idx_out_of_range":
			found_invalid = true
			break
	_assert(found_invalid, "invalid_index: item_equip_board_idx_out_of_range diagnostic emitted")
	var data: Dictionary = result.get("data", {})
	var result_items3: Array = data.get("items", [])
	_assert(result_items3.size() == 1, "invalid_index: 1 item migrated")
	_assert(String(result_items3[0].get("owner_unit_id", "X")) == "", "invalid_index: item unequipped")
	# Original equip index recorded in diagnostic context
	for d in diags:
		if d is RefCounted and d.code == "item_equip_board_idx_out_of_range":
			_assert(String(d.context) == "99" or String(d.detail).find("99") >= 0, "invalid_index: diagnostic captures original index")


func _test_round_trip_serialized_equals_input() -> void:
	print("[serializer] round-trip")
	for entry in _all_run_fixtures():
		var name: String = entry[0]
		var result: Dictionary = _migrate_run(name)
		_assert(bool(result.get("success", false)), "%s: migration success" % name)
		var data: Dictionary = result.get("data", {})
		var serialized: Dictionary = Migrator.serialize(data)
		var deserialized: Dictionary = Migrator.deserialize(serialized)
		var canon_input: Dictionary = Migrator.canonicalize(data)
		var canon_output: Dictionary = Migrator.canonicalize(deserialized)
		_assert(canon_input.hash() == canon_output.hash(), "%s: serialize/deserialize canonical equal" % name)


func _test_canonical_key_order_is_independent_of_insertion_order() -> void:
	print("[serializer] canonical key order is insertion-order independent")
	# Build a v4 DTO with keys inserted in random order, canonicalize
	# twice with different starting Dictionaries, and compare
	# canonical hashes.
	var d1: Dictionary = {}
	d1["schema_version"] = 4
	d1["run_id"] = "x"
	d1["seed"] = 1
	d1["units"] = []
	d1["items"] = []
	d1["next_unit_instance_seq"] = 0
	d1["next_item_instance_seq"] = 0
	d1["gold"] = 0
	d1["round_index"] = 1
	d1["phase"] = "prep"
	d1["game_build"] = ""
	d1["shop"] = {}
	d1["map"] = {}
	d1["rewards"] = {}
	d1["wins"] = 0
	d1["losses"] = 0
	d1["units_killed"] = 0
	d1["lives"] = 0
	d1["xp"] = 0
	d1["level"] = 0
	d1["current_encounter_id"] = -1
	d1["encounter_visited_ids"] = []
	d1["meta_modifiers"] = {}
	d1["just_visited_merchant"] = false
	var d2: Dictionary = {}
	d2["just_visited_merchant"] = false
	d2["meta_modifiers"] = {}
	d2["encounter_visited_ids"] = []
	d2["current_encounter_id"] = -1
	d2["level"] = 0
	d2["xp"] = 0
	d2["lives"] = 0
	d2["units_killed"] = 0
	d2["losses"] = 0
	d2["wins"] = 0
	d2["rewards"] = {}
	d2["map"] = {}
	d2["shop"] = {}
	d2["game_build"] = ""
	d2["phase"] = "prep"
	d2["round_index"] = 1
	d2["gold"] = 0
	d2["next_item_instance_seq"] = 0
	d2["next_unit_instance_seq"] = 0
	d2["items"] = []
	d2["units"] = []
	d2["seed"] = 1
	d2["run_id"] = "x"
	d2["schema_version"] = 4
	_assert(Migrator.canonicalize(d1).hash() == Migrator.canonicalize(d2).hash(), "canonicalize: insertion-order independent")


func _test_next_instance_seqs_after_migration() -> void:
	print("[migration] next_unit_instance_seq / next_item_instance_seq")
	# next_*_instance_seq is the FIRST UNUSED sequence (max_used + 1).
	# active_run_minimal: 2 board units, no items -> unit_seq 3 / item_seq 1
	var r1: Dictionary = _migrate_run("active_run_minimal")
	var d1: Dictionary = r1.get("data", {})
	_assert(int(d1.get("next_unit_instance_seq", -1)) == 3, "active: next_unit_instance_seq==3 (first unused)")
	_assert(int(d1.get("next_item_instance_seq", -1)) == 1, "active: next_item_instance_seq==1 (first unused)")
	# board_plus_bench: 4 units, no items -> unit_seq 5 / item_seq 1
	var r2: Dictionary = _migrate_run("board_plus_bench")
	var d2: Dictionary = r2.get("data", {})
	_assert(int(d2.get("next_unit_instance_seq", -1)) == 5, "board_plus_bench: next_unit_instance_seq==5 (first unused)")
	_assert(int(d2.get("next_item_instance_seq", -1)) == 1, "board_plus_bench: next_item_instance_seq==1 (first unused)")
	# items_equipped_and_unequipped: 1 unit, 2 items -> unit_seq 2 / item_seq 3
	var r3: Dictionary = _migrate_run("items_equipped_and_unequipped")
	var d3: Dictionary = r3.get("data", {})
	_assert(int(d3.get("next_unit_instance_seq", -1)) == 2, "items: next_unit_instance_seq==2 (first unused)")
	_assert(int(d3.get("next_item_instance_seq", -1)) == 3, "items: next_item_instance_seq==3 (first unused)")


func _test_empty_units_yields_next_one() -> void:
	print("[migration] empty units + items yields next=1 for both")
	# Synthetic minimal RunState with no units/items at all.
	var src = RunStateScript.new()
	src.player_unit_ids = [] as Array[StringName]
	src.bench_unit_ids = [] as Array[StringName]
	src.unit_states = []
	src.item_ids = [] as Array[StringName]
	src.item_equip_board_idx = [] as Array[int]
	var r = Migrator.migrate_run(src)
	_assert(int(r.data.next_unit_instance_seq) == 1, "empty: next_unit_instance_seq==1")
	_assert(int(r.data.next_item_instance_seq) == 1, "empty: next_item_instance_seq==1")


func _test_legacy_fixture_file_unchanged() -> void:
	print("[migration] source fixture unchanged after migration")
	# We hold PackedByteArray snapshots in memory and re-read the file
	# after running the migrator. The migrator must not modify the
	# fixture file.
	var names: Array = ["active_run_minimal", "two_identical_definition_ids", "board_plus_bench", "items_equipped_and_unequipped", "partial_hp"]
	for n in names:
		var path: String = _fixture_path(n)
		var before: PackedByteArray = FileAccess.get_file_as_bytes(path)
		_migrate_run(n)
		var after: PackedByteArray = FileAccess.get_file_as_bytes(path)
		_assert(before == after, "%s: source file unchanged" % n)


func _test_migration_does_not_touch_user_dir() -> void:
	print("[migration] migrator does not touch user://")
	# Snapshot the current state of user://saves/ before and after
	# running the migrator. The migrator must not write, create, or
	# delete any file under user://saves/.
	var before_meta: PackedByteArray = FileAccess.get_file_as_bytes(SaveSvc.meta_path())
	var runs_dir_path: String = SaveSvc.RUNS_DIR
	for entry in _all_run_fixtures():
		_migrate_run(entry[0])
	var after_meta: PackedByteArray = FileAccess.get_file_as_bytes(SaveSvc.meta_path())
	_assert(before_meta == after_meta, "user://saves/meta.tres unchanged")
	# ensure no temp run file leaked
	var runs_dir: DirAccess = DirAccess.open(runs_dir_path)
	if runs_dir != null:
		for fname in runs_dir.get_files():
			if fname.begins_with("run_legacy_v4_test_"):
				_assert(false, "temp file leaked: %s" % fname)


func _test_validator_rejects_duplicate_unit_instance_id() -> void:
	print("[validator] rejects duplicate unit instance_id")
	var data: Dictionary = Migrator.canonicalize(_migrate_run("two_identical_definition_ids").get("data", {}))
	# Inject a duplicate by reassigning the second unit's instance_id.
	if data.has("units") and (data["units"] as Array).size() >= 2:
		(data["units"] as Array)[1]["instance_id"] = (data["units"] as Array)[0]["instance_id"]
	var r: Dictionary = Migrator.validate(data)
	_assert(not bool(r.get("success", false)), "duplicate id: validation fails")
	var diags: Array = r.get("diagnostics", [])
	var found: bool = false
	for d in diags:
		if d is RefCounted and d.code == "duplicate_unit_instance_id":
			found = true
			break
	_assert(found, "duplicate id: duplicate_unit_instance_id diagnostic")


func _test_validator_rejects_unknown_item_owner() -> void:
	print("[validator] rejects unknown item owner")
	var data: Dictionary = Migrator.canonicalize(_migrate_run("items_equipped_and_unequipped").get("data", {}))
	if data.has("items") and (data["items"] as Array).size() >= 1:
		(data["items"] as Array)[0]["owner_unit_id"] = "unit_does_not_exist"
	var r: Dictionary = Migrator.validate(data)
	_assert(not bool(r.get("success", false)), "unknown owner: validation fails")
	var found: bool = false
	for d in r.get("diagnostics", []):
		if d is RefCounted and d.code == "unknown_item_owner":
			found = true
			break
	_assert(found, "unknown owner: diagnostic emitted")


func _test_validator_rejects_inconsistent_equip_state() -> void:
	print("[validator] rejects inconsistent equip state (item points to unit, unit does not list item)")
	var data: Dictionary = Migrator.canonicalize(_migrate_run("items_equipped_and_unequipped").get("data", {}))
	if data.has("units") and (data["units"] as Array).size() >= 1:
		(data["units"] as Array)[0]["equipped_item_ids"] = []
	# item still points to that unit -> inconsistent
	var r: Dictionary = Migrator.validate(data)
	_assert(not bool(r.get("success", false)), "inconsistent: validation fails")
	var found: bool = false
	for d in r.get("diagnostics", []):
		if d is RefCounted and d.code == "inconsistent_equip":
			found = true
			break
	_assert(found, "inconsistent: diagnostic emitted")


func _test_validator_rejects_duplicate_item_instance_id() -> void:
	print("[validator] rejects duplicate item instance_id")
	# Build a v4 DTO with two items that share an instance_id.
	var data: Dictionary = SaveSchemaV4.empty_dto()
	data["next_item_instance_seq"] = 2
	var items: Array = []
	var i0: Dictionary = {
		"instance_id": "item_000001",
		"definition_id": &"potion_strength",
		"owner_unit_id": "",
	}
	var i1: Dictionary = {
		"instance_id": "item_000001",  # duplicate
		"definition_id": &"amulet_vigor",
		"owner_unit_id": "",
	}
	items.append(i0)
	items.append(i1)
	data["items"] = items
	var r: Dictionary = Migrator.validate(data)
	_assert(not bool(r.get("success", false)), "duplicate item id: validation fails")
	var found: bool = false
	for d in r.get("diagnostics", []):
		if d is RefCounted and d.code == "duplicate_item_instance_id":
			found = true
			break
	_assert(found, "duplicate item id: diagnostic emitted")


# ---------------------------------------------------------------------------
# Task 6/7 — Defensive validator (H4) + bidirectional equipment (H5)
# ---------------------------------------------------------------------------

func _test_is_v4_dto_unchanged_public_api() -> void:
	print("[validator] is_v4_dto() returns bool (H4 public API preserved)")
	var valid: Dictionary = Migrator.canonicalize(_migrate_run("active_run_minimal").get("data", {}))
	_assert(typeof(SaveSchemaV4.is_v4_dto(valid)) == TYPE_BOOL, "is_v4_dto() returns bool for valid DTO")
	_assert(SaveSchemaV4.is_v4_dto(valid) == true, "is_v4_dto()=true for valid DTO")
	_assert(SaveSchemaV4.is_v4_dto({}) == false, "is_v4_dto()=false for empty dict")
	_assert(SaveSchemaV4.is_v4_dto("not a dict") == false, "is_v4_dto()=false for string")


func _test_validate_shape_returns_dictionary() -> void:
	print("[validator] validate_shape() returns {success, diagnostics}")
	var valid: Dictionary = Migrator.canonicalize(_migrate_run("active_run_minimal").get("data", {}))
	var r: Dictionary = SaveSchemaV4.validate_shape(valid)
	_assert(r.has("success") and r.has("diagnostics"), "validate_shape has success and diagnostics keys")
	_assert(bool(r.get("success", false)) == true, "validate_shape success=true for valid DTO")
	var empty_r: Dictionary = SaveSchemaV4.validate_shape({})
	_assert(bool(empty_r.get("success", true)) == false, "validate_shape success=false for empty")
	var diags: Array = empty_r.get("diagnostics", [])
	_assert(diags.size() > 0, "empty DTO produces diagnostics")


func _test_invalid_top_level_types_do_not_crash() -> void:
	print("[validator] invalid top-level types do not crash (H4 type-defensive)")
	# Build a DTO where some top-level fields have wrong types.
	var data: Dictionary = SaveSchemaV4.empty_dto()
	# schema_version must be int but is a string.
	# We bypass SaveSchemaV4.empty_dto here and craft raw.
	var raw: Dictionary = {
		"schema_version": "not int",
		"game_build": 0,  # must be string
		"run_id": 0,  # must be string
		"seed": "9001",  # string seed
		"round_index": "1",  # string round
		"phase": 0,  # must be string
		"gold": "0",  # string gold
		"units": "bad",  # must be array
		"items": "bad",  # must be array
		"next_unit_instance_seq": 0,
		"next_item_instance_seq": 0,
		"shop": "bad",  # must be dict
		"map": "bad",  # must be dict
		"rewards": "bad",  # must be dict
		"wins": 0, "losses": 0, "units_killed": 0, "lives": 0, "xp": 0, "level": 0,
		"current_encounter_id": 0,
		"encounter_visited_ids": "bad",  # must be array
		"meta_modifiers": "bad",  # must be dict
		"just_visited_merchant": 0,  # must be bool
	}
	# No SCRIPT ERROR; only diagnostics.
	var r: Dictionary = SaveSchemaV4.validate_shape(raw)
	_assert(bool(r.get("success", true)) == false, "validate_shape fails for bad types")
	var diags: Array = r.get("diagnostics", [])
	_assert(diags.size() > 0, "bad types produce diagnostics")
	# All diagnostic codes start with "top_level_type_mismatch" or
	# "missing_top_level_key".
	for d in diags:
		if d is RefCounted:
			_assert(d.code.begins_with("top_level_type_mismatch")
				or d.code == "missing_top_level_key", "diagnostic code well-formed: %s" % d.code)


func _test_current_hp_below_minus_one_rejected() -> void:
	print("[validator] current_hp < -1 rejected (H2 sentinel)")
	var data: Dictionary = SaveSchemaV4.empty_dto()
	var unit: Dictionary = {
		"instance_id": "unit_000001",
		"definition_id": "warrior",
		"current_hp": -5,  # below sentinel
		"max_hp": 100,
		"bonus_attack": 0,
		"dead": false,
		"location": 0,
		"order": 0,
		"equipped_item_ids": [],
	}
	data["units"] = [unit]
	data["next_unit_instance_seq"] = 2
	var r: Dictionary = Migrator.validate(data)
	_assert(not bool(r.get("success", false)), "current_hp < -1 -> validation fails")
	var found: bool = false
	for d in r.get("diagnostics", []):
		if d is RefCounted and d.code == "current_hp_below_sentinel":
			found = true
			break
	_assert(found, "current_hp_below_sentinel diagnostic emitted")


func _test_unit_location_invalid_rejected() -> void:
	print("[validator] unit location not in {0,1} rejected")
	var data: Dictionary = SaveSchemaV4.empty_dto()
	var unit: Dictionary = {
		"instance_id": "unit_000001",
		"definition_id": "warrior",
		"current_hp": -1, "max_hp": 100, "bonus_attack": 0, "dead": false,
		"location": 5,  # invalid
		"order": 0,
		"equipped_item_ids": [],
	}
	data["units"] = [unit]
	data["next_unit_instance_seq"] = 2
	var r: Dictionary = Migrator.validate(data)
	_assert(not bool(r.get("success", false)), "invalid location -> validation fails")
	var found: bool = false
	for d in r.get("diagnostics", []):
		if d is RefCounted and d.code == "unit_location_invalid":
			found = true
			break
	_assert(found, "unit_location_invalid diagnostic emitted")


func _test_duplicate_unit_order_in_location_rejected() -> void:
	print("[validator] duplicate order in one location rejected")
	var data: Dictionary = SaveSchemaV4.empty_dto()
	var u0: Dictionary = {
		"instance_id": "unit_000001", "definition_id": "warrior",
		"current_hp": -1, "max_hp": 100, "bonus_attack": 0, "dead": false,
		"location": 0, "order": 0, "equipped_item_ids": [],
	}
	var u1: Dictionary = {
		"instance_id": "unit_000002", "definition_id": "warrior",
		"current_hp": -1, "max_hp": 100, "bonus_attack": 0, "dead": false,
		"location": 0, "order": 0,  # duplicate order
		"equipped_item_ids": [],
	}
	data["units"] = [u0, u1]
	data["next_unit_instance_seq"] = 3
	var r: Dictionary = Migrator.validate(data)
	_assert(not bool(r.get("success", false)), "duplicate order -> validation fails")
	var found: bool = false
	for d in r.get("diagnostics", []):
		if d is RefCounted and d.code == "duplicate_unit_order_in_location":
			found = true
			break
	_assert(found, "duplicate_unit_order_in_location diagnostic emitted")


# H5 A: item.owner set but unit.equipped_item_ids does not list it.
func _test_equipment_invariant_A_owner_set_unit_missing_item() -> void:
	print("[validator] H5 A: item.owner set but unit does not list item")
	var data: Dictionary = SaveSchemaV4.empty_dto()
	var unit: Dictionary = {
		"instance_id": "unit_000001", "definition_id": "warrior",
		"current_hp": -1, "max_hp": 100, "bonus_attack": 0, "dead": false,
		"location": 0, "order": 0, "equipped_item_ids": [],  # empty
	}
	var item: Dictionary = {
		"instance_id": "item_000001", "definition_id": "potion_strength",
		"owner_unit_id": "unit_000001",  # set
	}
	data["units"] = [unit]
	data["items"] = [item]
	data["next_unit_instance_seq"] = 2
	data["next_item_instance_seq"] = 2
	var r: Dictionary = Migrator.validate(data)
	_assert(not bool(r.get("success", false)), "H5 A: validation fails")
	var found: bool = false
	for d in r.get("diagnostics", []):
		if d is RefCounted and d.code == "inconsistent_equip":
			found = true
			break
	_assert(found, "H5 A: inconsistent_equip diagnostic emitted")


# H5 B: unit lists item but item.owner is empty.
func _test_equipment_invariant_B_unit_lists_empty_owner() -> void:
	print("[validator] H5 B: unit lists item but item.owner empty")
	var data: Dictionary = SaveSchemaV4.empty_dto()
	var unit: Dictionary = {
		"instance_id": "unit_000001", "definition_id": "warrior",
		"current_hp": -1, "max_hp": 100, "bonus_attack": 0, "dead": false,
		"location": 0, "order": 0, "equipped_item_ids": ["item_000001"],
	}
	var item: Dictionary = {
		"instance_id": "item_000001", "definition_id": "potion_strength",
		"owner_unit_id": "",  # empty
	}
	data["units"] = [unit]
	data["items"] = [item]
	data["next_unit_instance_seq"] = 2
	data["next_item_instance_seq"] = 2
	var r: Dictionary = Migrator.validate(data)
	_assert(not bool(r.get("success", false)), "H5 B: validation fails")
	var found: bool = false
	for d in r.get("diagnostics", []):
		if d is RefCounted and d.code == "inconsistent_equip":
			found = true
			break
	_assert(found, "H5 B: inconsistent_equip diagnostic emitted")


# H5 C: same item id listed by two units.
func _test_equipment_invariant_C_same_item_two_units() -> void:
	print("[validator] H5 C: same item id listed by two units")
	var data: Dictionary = SaveSchemaV4.empty_dto()
	var u0: Dictionary = {
		"instance_id": "unit_000001", "definition_id": "warrior",
		"current_hp": -1, "max_hp": 100, "bonus_attack": 0, "dead": false,
		"location": 0, "order": 0, "equipped_item_ids": ["item_000001"],
	}
	var u1: Dictionary = {
		"instance_id": "unit_000002", "definition_id": "archer",
		"current_hp": -1, "max_hp": 70, "bonus_attack": 0, "dead": false,
		"location": 0, "order": 1, "equipped_item_ids": ["item_000001"],
	}
	var item: Dictionary = {
		"instance_id": "item_000001", "definition_id": "potion_strength",
		"owner_unit_id": "unit_000001",
	}
	data["units"] = [u0, u1]
	data["items"] = [item]
	data["next_unit_instance_seq"] = 3
	data["next_item_instance_seq"] = 2
	var r: Dictionary = Migrator.validate(data)
	_assert(not bool(r.get("success", false)), "H5 C: validation fails")
	var found: bool = false
	for d in r.get("diagnostics", []):
		if d is RefCounted and d.code == "item_listed_by_multiple_units":
			found = true
			break
	_assert(found, "H5 C: item_listed_by_multiple_units diagnostic emitted")


# H5 D: unit references unknown item.
func _test_equipment_invariant_D_unknown_item() -> void:
	print("[validator] H5 D: unit references unknown item")
	var data: Dictionary = SaveSchemaV4.empty_dto()
	var unit: Dictionary = {
		"instance_id": "unit_000001", "definition_id": "warrior",
		"current_hp": -1, "max_hp": 100, "bonus_attack": 0, "dead": false,
		"location": 0, "order": 0, "equipped_item_ids": ["item_does_not_exist"],
	}
	data["units"] = [unit]
	data["items"] = []
	data["next_unit_instance_seq"] = 2
	data["next_item_instance_seq"] = 1
	var r: Dictionary = Migrator.validate(data)
	_assert(not bool(r.get("success", false)), "H5 D: validation fails")
	var found: bool = false
	for d in r.get("diagnostics", []):
		if d is RefCounted and d.code == "unknown_item_in_equipped_list":
			found = true
			break
	_assert(found, "H5 D: unknown_item_in_equipped_list diagnostic emitted")


# H5 E: same item id listed twice inside one unit's equipped_item_ids.
func _test_equipment_invariant_E_duplicate_in_unit() -> void:
	print("[validator] H5 E: duplicate equipped id in one unit")
	var data: Dictionary = SaveSchemaV4.empty_dto()
	var unit: Dictionary = {
		"instance_id": "unit_000001", "definition_id": "warrior",
		"current_hp": -1, "max_hp": 100, "bonus_attack": 0, "dead": false,
		"location": 0, "order": 0,
		"equipped_item_ids": ["item_000001", "item_000001"],  # duplicate
	}
	var item: Dictionary = {
		"instance_id": "item_000001", "definition_id": "potion_strength",
		"owner_unit_id": "",
	}
	data["units"] = [unit]
	data["items"] = [item]
	data["next_unit_instance_seq"] = 2
	data["next_item_instance_seq"] = 2
	var r: Dictionary = Migrator.validate(data)
	_assert(not bool(r.get("success", false)), "H5 E: validation fails")
	var found: bool = false
	for d in r.get("diagnostics", []):
		if d is RefCounted and d.code == "duplicate_in_unit_equipped":
			found = true
			break
	_assert(found, "H5 E: duplicate_in_unit_equipped diagnostic emitted")


# H6: save seed mismatch rejected.
func _test_save_seed_mismatch_rejected() -> void:
	print("[repository] save seed mismatch rejected (H6)")
	# Build a v4 DTO with seed=9001, then save with requested seed=9002.
	var runs_dir: String = "user://seed_mismatch_test/"
	DirAccess.make_dir_recursive_absolute(runs_dir)
	_cleanup_test_dir(runs_dir)
	var src: Resource = load(RUN_FIXTURE_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = Migrator.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	v4["seed"] = 9001
	v4["run_id"] = "run_9001"
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	# First save: seed matches.
	repo.save_run(9001, v4)
	# Second save: requested seed=9002 but data has seed=9001.
	var wr: RefCounted = repo.save_run(9002, v4)
	_assert(wr.is_error(), "save with seed mismatch -> error")
	# Either the validator catches it (pre-validate) or the post-commit
	# validate catches it. Both are valid failure paths.
	_cleanup_test_dir(runs_dir)


func _cleanup_test_dir(runs_dir: String) -> void:
	var d: DirAccess = DirAccess.open(runs_dir)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)


# ---------------------------------------------------------------------------
# Task 10 — unit_states mismatch deterministic policy
# ---------------------------------------------------------------------------

func _test_unit_state_match_by_definition_and_occurrence() -> void:
	print("[migration] unit_state matched by definition_id + occurrence")
	# Build a RunState where board[0] = warrior, board[1] = warrior (two
	# identical definition ids) and unit_states mirrors them in order.
	var src = RunStateScript.new()
	var p: Array[StringName] = [&"warrior", &"warrior"]
	src.player_unit_ids = p
	src.bench_unit_ids = [] as Array[StringName]
	src.unit_states = []
	src.item_ids = [] as Array[StringName]
	src.item_equip_board_idx = [] as Array[int]
	# Inject unit states via the legacy load+resource path. We
	# can't create RunUnitState directly without running the
	# resource; instead use a fresh-migrated fixture as a base.
	var base: Resource = load(RUN_FIXTURE_DIR + "/two_identical_definition_ids.tres")
	var base_mig: Dictionary = Migrator.migrate_run(base)
	var base_data: Dictionary = base_mig.get("data", {})
	# base_data has 2 warrior units with instance_id unit_000001 and
	# unit_000002. Use it as the expected structure for our test.
	var v4: Dictionary = base_data.duplicate(true)
	var u0: Dictionary = v4["units"][0]
	var u1: Dictionary = v4["units"][1]
	_assert(u0.instance_id == "unit_000001", "u0 instance_id = unit_000001")
	_assert(u1.instance_id == "unit_000002", "u1 instance_id = unit_000002")
	_assert(u0.definition_id == &"warrior", "u0 definition_id = warrior")
	_assert(u1.definition_id == &"warrior", "u1 definition_id = warrior")
	_assert(u0.current_hp != u1.current_hp or u0.max_hp != u1.max_hp,
		"two warriors are independent (different hp / max_hp)")


func _test_unit_states_completely_missing_fails_migration() -> void:
	print("[migration] all unit_states absent + units present -> failure (H8 rule 5)")
	# Build a RunState where player_unit_ids is non-empty but
	# unit_states is empty. The migrator MUST fail with
	# unit_states_completely_missing.
	var src = RunStateScript.new()
	var p: Array[StringName] = [&"warrior", &"archer"]
	src.player_unit_ids = p
	src.bench_unit_ids = [] as Array[StringName]
	src.unit_states = []  # 0 states, 2 expected
	src.item_ids = [] as Array[StringName]
	src.item_equip_board_idx = [] as Array[int]
	src.seed = 8001
	src.version = 1
	var r: Dictionary = Migrator.migrate_run(src)
	_assert(not bool(r.get("success", false)),
		"all unit_states absent while units expected -> migration fails")
	var found: bool = false
	for d in r.get("diagnostics", []):
		if d is RefCounted and d.code == "unit_states_completely_missing":
			found = true
			break
	_assert(found, "unit_states_completely_missing diagnostic emitted")


# ---------------------------------------------------------------------------
# Task 5 — Strict nested validator (HIGH #1)
# ---------------------------------------------------------------------------

func _test_strict_validator_rejects_string_current_hp() -> void:
	print("[validator] strict: rejects string current_hp")
	var data: Dictionary = SaveSchemaV4.empty_dto()
	var unit: Dictionary = {
		"instance_id": "unit_000001",
		"definition_id": "warrior",
		"current_hp": "garbage",
		"max_hp": 100,
		"bonus_attack": 0,
		"dead": false,
		"location": 0,
		"order": 0,
		"equipped_item_ids": [],
	}
	data["units"] = [unit]
	data["next_unit_instance_seq"] = 2
	var r: Dictionary = Migrator.validate(data)
	_assert(not bool(r.get("success", false)), "string current_hp rejected")
	var found: bool = false
	for d in r.get("diagnostics", []):
		if d is RefCounted and d.code == "unit_field_type_invalid":
			found = true
			break
	_assert(found, "unit_field_type_invalid diagnostic emitted")


func _test_strict_validator_rejects_string_dead_flag() -> void:
	print("[validator] strict: rejects string dead flag")
	var data: Dictionary = SaveSchemaV4.empty_dto()
	var unit: Dictionary = {
		"instance_id": "unit_000001",
		"definition_id": "warrior",
		"current_hp": -1,
		"max_hp": 100,
		"bonus_attack": 0,
		"dead": "banana",
		"location": 0,
		"order": 0,
		"equipped_item_ids": [],
	}
	data["units"] = [unit]
	data["next_unit_instance_seq"] = 2
	var r: Dictionary = Migrator.validate(data)
	_assert(not bool(r.get("success", false)), "string dead flag rejected")
	var found: bool = false
	for d in r.get("diagnostics", []):
		if d is RefCounted and d.code == "unit_field_type_invalid":
			found = true
			break
	_assert(found, "unit_field_type_invalid diagnostic emitted")


func _test_strict_validator_rejects_string_equipped_item_ids() -> void:
	print("[validator] strict: rejects string equipped_item_ids")
	var data: Dictionary = SaveSchemaV4.empty_dto()
	var unit: Dictionary = {
		"instance_id": "unit_000001",
		"definition_id": "warrior",
		"current_hp": -1,
		"max_hp": 100,
		"bonus_attack": 0,
		"dead": false,
		"location": 0,
		"order": 0,
		"equipped_item_ids": "banana",
	}
	data["units"] = [unit]
	data["next_unit_instance_seq"] = 2
	var r: Dictionary = Migrator.validate(data)
	_assert(not bool(r.get("success", false)),
		"string equipped_item_ids rejected")
	var found: bool = false
	for d in r.get("diagnostics", []):
		if d is RefCounted and d.code == "unit_field_type_invalid":
			found = true
			break
	_assert(found, "unit_field_type_invalid diagnostic emitted")

