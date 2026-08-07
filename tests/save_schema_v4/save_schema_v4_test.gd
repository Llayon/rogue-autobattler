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
	# active_run_minimal: 2 board units, no items -> seq 2 / 0
	var r1: Dictionary = _migrate_run("active_run_minimal")
	var d1: Dictionary = r1.get("data", {})
	_assert(int(d1.get("next_unit_instance_seq", -1)) == 2, "active: next_unit_instance_seq==2")
	_assert(int(d1.get("next_item_instance_seq", -1)) == 0, "active: next_item_instance_seq==0")
	# board_plus_bench: 4 units, no items -> seq 4 / 0
	var r2: Dictionary = _migrate_run("board_plus_bench")
	var d2: Dictionary = r2.get("data", {})
	_assert(int(d2.get("next_unit_instance_seq", -1)) == 4, "board_plus_bench: next_unit_instance_seq==4")
	_assert(int(d2.get("next_item_instance_seq", -1)) == 0, "board_plus_bench: next_item_instance_seq==0")
	# items_equipped_and_unequipped: 1 unit, 2 items -> seq 1 / 2
	var r3: Dictionary = _migrate_run("items_equipped_and_unequipped")
	var d3: Dictionary = r3.get("data", {})
	_assert(int(d3.get("next_unit_instance_seq", -1)) == 1, "items: next_unit_instance_seq==1")
	_assert(int(d3.get("next_item_instance_seq", -1)) == 2, "items: next_item_instance_seq==2")


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
