extends SceneTree

## Production-loader verification for byte-faithful legacy v1 save
## fixtures. For each fixture we:
##   1. Copy it under a temp filename inside the real `user://saves/`.
##   2. Call the production `SaveService.load_<>` / `SaveSvc.load_resource`
##      method.
##   3. Assert the loaded fields.
##   4. Remove the temp file.
## The script does not modify the user's existing `user://meta.tres`.
##
## For each fixture we additionally call the low-level `load(path)`
## parser as a sanity check. The low-level check is named
## "low-level load() parses raw bytes" to distinguish it from the
## SaveService loader.

const SaveServiceScript = preload("res://core/save/save_service.gd")
const SaveSvc = preload("res://core/utils/save_manager.gd")
const RunStateScript = preload("res://core/progression/run_state.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")

const FIXTURES_DIR: String = "res://tests/legacy_save_fixtures/fixtures/version_1"
const RUN_FIXTURE_DIR: String = FIXTURES_DIR + "/runs"

const TEMP_META_NAME: String = "meta_legacy_v1_test.tres"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	print("\n=== legacy save loader test ===\n")
	_test_meta_legacy_v1_temp_file()
	_test_meta_low_level_load_parses_raw_bytes()
	_test_active_run_minimal_loads()
	_test_two_identical_definition_ids_loads()
	_test_board_plus_bench_loads()
	_test_items_equipped_and_unequipped_loads()
	_test_partial_hp_loads()
	print("\n=== legacy save loader: %d passed, %d failed ===\n" % [_passed, _failed])
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


## Copy a fixture .tres into user://saves/<production_name> temporarily,
## call SaveService.load_<>, assert, and remove it. Returns the loaded
## resource or null on failure.
func _via_production_run_path(seed_value: int, label: String) -> Resource:
	var src_path: String = RUN_FIXTURE_DIR + "/run_%d.tres" % seed_value
	var user_path: String = SaveSvc.run_path(seed_value)
	var src_bytes: PackedByteArray = FileAccess.get_file_as_bytes(src_path)
	_assert(src_bytes.size() > 0, "%s: source bytes read (got %d)" % [label, src_bytes.size()])
	var user_file: FileAccess = FileAccess.open(user_path, FileAccess.WRITE)
	if user_file == null:
		_assert(false, "%s: cannot open %s for write" % [label, user_path])
		return null
	user_file.store_buffer(src_bytes)
	user_file.close()
	var on_disk: FileAccess = FileAccess.open(user_path, FileAccess.READ)
	if on_disk != null:
		var actual_size: int = on_disk.get_length()
		on_disk.close()
		_assert(actual_size == src_bytes.size(), "%s: bytes on disk match source (%d vs %d)" % [label, actual_size, src_bytes.size()])
	var loaded: Resource = SaveServiceScript.load_run(seed_value)
	_assert(loaded != null, "%s: SaveService.load_run returned non-null" % label)
	if loaded != null and not (loaded is RunStateScript):
		_assert(false, "%s: loaded type is RunState (got %s)" % [label, loaded.get_class()])
	var removed: bool = SaveServiceScript.delete_run(seed_value)
	_assert(removed, "%s: temp run file removed" % label)
	return loaded


## Copy meta.tres to a temp name inside user://saves/ so we never
## overwrite the user's existing meta.tres. Load via the production
## SaveSvc.load_resource + SaveService.load_meta path.
func _via_production_meta_path(label: String) -> Resource:
	var src_path: String = FIXTURES_DIR + "/meta.tres"
	var runs_dir: String = SaveSvc.RUNS_DIR
	var user_path: String = runs_dir + TEMP_META_NAME
	var src_bytes: PackedByteArray = FileAccess.get_file_as_bytes(src_path)
	_assert(src_bytes.size() > 0, "%s: source bytes read (got %d)" % [label, src_bytes.size()])
	var user_file: FileAccess = FileAccess.open(user_path, FileAccess.WRITE)
	if user_file == null:
		_assert(false, "%s: cannot open %s for write" % [label, user_path])
		return null
	user_file.store_buffer(src_bytes)
	user_file.close()
	# Load via low-level SaveSvc.load_resource first.
	var low: Resource = SaveSvc.load_resource(user_path)
	_assert(low != null, "%s: low-level SaveSvc.load_resource returned non-null" % label)
	if low != null and not (low is MetaProfileScript):
		_assert(false, "%s: low-level loaded type is MetaProfile (got %s)" % [label, low.get_class()])
	# Also exercise the public SaveService.load_meta wrapper by
	# pointing it at our temp file: monkey-patch is not allowed, so
	# this only verifies the underlying load path. SaveService.load_meta
	# always reads SaveSvc.meta_path() and would clobber user meta; we
	# therefore skip it and rely on the low-level call above plus a
	# separate low-level load() check in _test_meta_low_level_load_parses_raw_bytes.
	# Cleanup: remove temp file.
	var dir: DirAccess = DirAccess.open(runs_dir)
	if dir != null:
		var err: int = dir.remove(TEMP_META_NAME)
		_assert(err == OK, "%s: temp meta file removed" % label)
	return low


## Direct low-level parsing check (independent of SaveService.save/load):
## load() the raw fixture bytes from res:// and assert the fields.
func _low_level_parse_run(label: String, fixture_path: String) -> Resource:
	var res: Resource = load(fixture_path)
	_assert(res != null, "%s: low-level load() non-null" % label)
	if res != null and not (res is RunStateScript):
		_assert(false, "%s: low-level loaded type is RunState (got %s)" % [label, res.get_class()])
	return res


func _low_level_parse_meta(label: String, fixture_path: String) -> Resource:
	var res: Resource = load(fixture_path)
	_assert(res != null, "%s: low-level load() non-null" % label)
	if res != null and not (res is MetaProfileScript):
		_assert(false, "%s: low-level loaded type is MetaProfile (got %s)" % [label, res.get_class()])
	return res


func _test_meta_legacy_v1_temp_file() -> void:
	print("[production loader] meta.tres via temp filename (no clobber)")
	var meta: Resource = _via_production_meta_path("meta_legacy_v1")
	if meta == null:
		return
	_assert(int(meta.total_runs) == 7, "meta.total_runs==7")
	_assert(int(meta.total_wins) == 3, "meta.total_wins==3")
	_assert(int(meta.best_round) == 5, "meta.best_round==5")
	_assert(int(meta.soul_currency) == 25, "meta.soul_currency==25")
	_assert(int(meta.current_run_seed) == 9005, "meta.current_run_seed==9005")
	_assert(meta.battle_speed == 2.0, "meta.battle_speed==2.0")
	_assert(meta.show_damage_numbers == true, "meta.show_damage_numbers==true")
	_assert(meta.unlocked_units.size() == 4, "meta.unlocked_units count")
	_assert(meta.unlocked_enemies.size() == 3, "meta.unlocked_enemies count")


func _test_meta_low_level_load_parses_raw_bytes() -> void:
	print("[low-level load()] meta.tres parses raw bytes")
	var meta: Resource = _low_level_parse_meta("meta_low_level", FIXTURES_DIR + "/meta.tres")
	if meta == null:
		return
	_assert(int(meta.total_runs) == 7, "meta.total_runs==7 via low-level load()")


func _test_active_run_minimal_loads() -> void:
	print("[production loader] active_run_minimal (seed=9001)")
	var run: Resource = _via_production_run_path(9001, "active_run_minimal")
	if run == null:
		return
	_assert(int(run.version) == 1, "active_run.version==1 (overwrite quirk)")
	_assert(int(run.seed) == 9001, "active_run.seed==9001")
	_assert(run.player_unit_ids.size() == 2, "active_run.player_unit_ids count")
	_assert(run.unit_states.size() == 2, "active_run.unit_states count")
	_assert(String(run.unit_states[0].unit_id) == "warrior", "warrior unit_id")
	_assert(int(run.unit_states[0].current_hp) == 100, "warrior current_hp==100")
	_assert(String(run.unit_states[1].unit_id) == "archer", "archer unit_id")
	_assert(int(run.unit_states[1].current_hp) == 70, "archer current_hp==70")


func _test_two_identical_definition_ids_loads() -> void:
	print("[production loader] two_identical_definition_ids (seed=9002)")
	var run: Resource = _via_production_run_path(9002, "two_identical_definition_ids")
	if run == null:
		return
	_assert(run.player_unit_ids.size() == 2, "identical-def run player_unit_ids count")
	_assert(String(run.unit_states[0].unit_id) == "warrior", "first identical-def warrior unit_id")
	_assert(String(run.unit_states[1].unit_id) == "warrior", "second identical-def warrior unit_id")
	_assert(int(run.unit_states[0].current_hp) == 80, "first identical-def current_hp==80")
	_assert(int(run.unit_states[1].current_hp) == 60, "second identical-def current_hp==60")
	_assert(int(run.unit_states[0].max_hp) == 100, "first identical-def max_hp==100")
	_assert(int(run.unit_states[1].max_hp) == 100, "second identical-def max_hp==100")


func _test_board_plus_bench_loads() -> void:
	print("[production loader] board_plus_bench (seed=9003)")
	var run: Resource = _via_production_run_path(9003, "board_plus_bench")
	if run == null:
		return
	_assert(run.player_unit_ids.size() == 2, "board size")
	_assert(run.bench_unit_ids.size() == 2, "bench size")
	_assert(run.unit_states.size() == 4, "unit_states covers board + bench")


func _test_items_equipped_and_unequipped_loads() -> void:
	print("[production loader] items_equipped_and_unequipped (seed=9004)")
	var run: Resource = _via_production_run_path(9004, "items_equipped_and_unequipped")
	if run == null:
		return
	_assert(run.item_ids.size() == 2, "items count")
	_assert(run.item_equip_board_idx.size() == 2, "item slots count")
	_assert(int(run.item_equip_board_idx[0]) == 0, "first item equipped at 0")
	_assert(int(run.item_equip_board_idx[1]) == -1, "second item in inventory (-1)")


func _test_partial_hp_loads() -> void:
	print("[production loader] partial_hp (seed=9005)")
	var run: Resource = _via_production_run_path(9005, "partial_hp")
	if run == null:
		return
	_assert(int(run.unit_states[0].current_hp) == 33, "warrior partial current_hp==33")
	_assert(int(run.unit_states[1].current_hp) == 12, "archer partial current_hp==12")
	_assert(int(run.unit_states[0].max_hp) == 100, "warrior max_hp==100")
	_assert(int(run.unit_states[1].max_hp) == 70, "archer max_hp==70")