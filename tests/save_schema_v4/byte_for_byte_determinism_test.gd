extends SceneTree

## Serialized-byte-for-byte determinism check: the same legacy v1
## fixture migrated and serialized twice produces identical canonical
## wire bytes (PackedByteArray equality), not just identical
## Dictionary.hash(). This is the explicit user-facing contract
## for replay-ability of the migrator.

const Migrator = preload("res://core/save/legacy_save_v1_to_v4_migrator.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")

const FIXTURE_DIR: String = "res://tests/legacy_save_fixtures/fixtures/version_1"
const RUN_FIXTURE_DIR: String = FIXTURE_DIR + "/runs"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	print("\n=== byte-for-byte determinism ===\n")
	_test_serialized_bytes_identical_across_runs()
	_test_serialized_bytes_differ_across_seeds()
	_test_serialized_bytes_have_marker_then_json()
	_test_canonical_key_order_independent_of_insertion_order()
	_test_canonical_arrays_preserve_semantic_order()
	_test_repeated_migration_is_deterministic_for_each_fixture()
	_test_three_independent_runs_match_legacy_data()
	print("\n=== byte-for-byte determinism: %d passed, %d failed ===\n" % [_passed, _failed])
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


func _migrate_canonical(fixture_name: String) -> Dictionary:
	var res: Resource = load(RUN_FIXTURE_DIR + "/%s.tres" % fixture_name)
	if res == null:
		return {}
	var result: Dictionary = Migrator.migrate_run(res)
	return Migrator.canonicalize(result.get("data", {}))


func _migrate_canonical_bytes(fixture_name: String) -> PackedByteArray:
	return RunSaveRepositoryScript.serialize_canonical_bytes(_migrate_canonical(fixture_name))


func _test_serialized_bytes_identical_across_runs() -> void:
	print("[determinism] serialized bytes identical across three runs")
	var names: Array = [
		"active_run_minimal",
		"two_identical_definition_ids",
		"board_plus_bench",
		"items_equipped_and_unequipped",
		"partial_hp",
	]
	for n in names:
		var a: PackedByteArray = _migrate_canonical_bytes(n)
		var b: PackedByteArray = _migrate_canonical_bytes(n)
		var c: PackedByteArray = _migrate_canonical_bytes(n)
		_assert(a == b, "%s: serialized bytes run1==run2" % n)
		_assert(a == c, "%s: serialized bytes run1==run3" % n)


func _test_serialized_bytes_differ_across_seeds() -> void:
	print("[determinism] serialized bytes differ across seeds")
	var a: PackedByteArray = _migrate_canonical_bytes("active_run_minimal")
	var b: PackedByteArray = _migrate_canonical_bytes("partial_hp")
	_assert(a != b, "different seeds -> different serialized bytes")


func _test_serialized_bytes_have_marker_then_json() -> void:
	print("[determinism] wire format = '# v4 save\\n<json>'")
	var bytes: PackedByteArray = _migrate_canonical_bytes("active_run_minimal")
	var s: String = bytes.get_string_from_utf8()
	_assert(s.begins_with("# v4 save\n"), "wire begins with '# v4 save' marker line")
	var nl: int = s.find("\n")
	var body: String = s.substr(nl + 1)
	var parsed: Variant = JSON.parse_string(body)
	_assert(parsed is Dictionary, "wire body parses as JSON Dictionary")
	_assert(int((parsed as Dictionary).get("schema_version", -1)) == 4, "wire schema_version=4")


func _test_canonical_key_order_independent_of_insertion_order() -> void:
	print("[determinism] canonical key order is insertion-order independent")
	# Build two DTOs with the same keys inserted in opposite order.
	var d1: Dictionary = {}
	d1["schema_version"] = 4
	d1["seed"] = 1
	d1["run_id"] = "run_1"
	d1["units"] = []
	d1["items"] = []
	d1["next_unit_instance_seq"] = 1
	d1["next_item_instance_seq"] = 1
	d1["gold"] = 0
	d1["round_index"] = 1
	d1["phase"] = "prep"
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
	d1["game_build"] = ""
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
	d2["phase"] = "prep"
	d2["round_index"] = 1
	d2["gold"] = 0
	d2["next_item_instance_seq"] = 1
	d2["next_unit_instance_seq"] = 1
	d2["items"] = []
	d2["units"] = []
	d2["run_id"] = "run_1"
	d2["seed"] = 1
	d2["schema_version"] = 4
	d2["game_build"] = ""
	_assert(RunSaveRepositoryScript.serialize_canonical_bytes(d1)
		== RunSaveRepositoryScript.serialize_canonical_bytes(d2),
		"insertion-order independent")


func _test_canonical_arrays_preserve_semantic_order() -> void:
	print("[determinism] arrays keep semantic order")
	var d: Dictionary = {}
	d["schema_version"] = 4
	d["seed"] = 1
	d["run_id"] = "run_1"
	d["units"] = []
	d["items"] = []
	d["next_unit_instance_seq"] = 1
	d["next_item_instance_seq"] = 1
	d["gold"] = 0
	d["round_index"] = 1
	d["phase"] = "prep"
	d["shop"] = {}
	d["map"] = {}
	d["rewards"] = {}
	d["wins"] = 0
	d["losses"] = 0
	d["units_killed"] = 0
	d["lives"] = 0
	d["xp"] = 0
	d["level"] = 0
	d["current_encounter_id"] = -1
	d["encounter_visited_ids"] = [3, 1, 7, 11]  # intentional non-sorted
	d["meta_modifiers"] = {}
	d["just_visited_merchant"] = false
	d["game_build"] = ""
	var bytes: PackedByteArray = RunSaveRepositoryScript.serialize_canonical_bytes(d)
	var s: String = bytes.get_string_from_utf8()
	# JSON.stringify with sort_keys=true still uses no spaces between
	# elements. Match the no-space form.
	_assert(s.find("[3,1,7,11]") >= 0,
		"encounter_visited_ids keeps original order (no array sort)")


func _test_repeated_migration_is_deterministic_for_each_fixture() -> void:
	print("[determinism] repeated migration canonical hash stable")
	var names: Array = [
		"active_run_minimal",
		"two_identical_definition_ids",
		"board_plus_bench",
		"items_equipped_and_unequipped",
		"partial_hp",
	]
	for n in names:
		var first: Dictionary = _migrate_canonical(n)
		var second: Dictionary = _migrate_canonical(n)
		var third: Dictionary = _migrate_canonical(n)
		_assert(first.hash() == second.hash(), "%s: canonical hash first==second" % n)
		_assert(first.hash() == third.hash(), "%s: canonical hash first==third" % n)


func _test_three_independent_runs_match_legacy_data() -> void:
	print("[determinism] independent runs differ only by seed")
	var active: Dictionary = _migrate_canonical("active_run_minimal")
	var partial: Dictionary = _migrate_canonical("partial_hp")
	_assert(int(active.get("seed", 0)) == 9001, "active seed=9001")
	_assert(int(partial.get("seed", 0)) == 9005, "partial seed=9005")
	_assert(active.hash() != partial.hash(), "different seeds -> different canonical hashes")
	_assert(String(active.get("run_id", "")) == "run_9001", "active run_id=run_9001")
	_assert(String(partial.get("run_id", "")) == "run_9005", "partial run_id=run_9005")
