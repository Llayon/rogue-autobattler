extends SceneTree

## Byte-for-byte determinism check: the same legacy v1 fixture
## migrated and canonicalized twice produces identical canonical
## DTOs (same hash). This is the explicit user-facing contract for
## replay-ability of the migrator.

const Migrator = preload("res://core/save/legacy_save_v1_to_v4_migrator.gd")

const FIXTURE_DIR: String = "res://tests/legacy_save_fixtures/fixtures/version_1"
const RUN_FIXTURE_DIR: String = FIXTURE_DIR + "/runs"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	print("\n=== byte-for-byte determinism ===\n")
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
	# Two distinct fixtures with distinct seeds; ensure their v4
	# canonical hashes differ but each one is internally consistent
	# with its source seed.
	var active: Dictionary = _migrate_canonical("active_run_minimal")
	var partial: Dictionary = _migrate_canonical("partial_hp")
	_assert(int(active.get("seed", 0)) == 9001, "active seed=9001")
	_assert(int(partial.get("seed", 0)) == 9005, "partial seed=9005")
	_assert(active.hash() != partial.hash(), "different seeds -> different canonical hashes")
	# Run IDs are seed-derived.
	_assert(String(active.get("run_id", "")) == "run_9001", "active run_id=run_9001")
	_assert(String(partial.get("run_id", "")) == "run_9005", "partial run_id=run_9005")
