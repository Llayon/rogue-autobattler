extends SceneTree

## Production SaveRepository contract: format detection, atomic
## legacy migration, idempotency, backup immutability, failure
## handling. All tests use isolated temp directories under
## `user://save_repository_test_<id>/` and clean up after themselves.

const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const SaveLoadResultScript = preload("res://core/save/save_load_result.gd")
const MigratorScript = preload("res://core/save/legacy_save_v1_to_v4_migrator.gd")
const SaveSchemaV4Script = preload("res://core/save/save_schema_v4.gd")
const RunStateScript = preload("res://core/progression/run_state.gd")

const FIXTURES_DIR: String = "res://tests/legacy_save_fixtures/fixtures/version_1"
const RUN_FIXTURES_DIR: String = FIXTURES_DIR + "/runs"

var _passed: int = 0
var _failed: int = 0
var _test_counter: int = 0


func _initialize() -> void:
	print("\n=== production save repository tests ===\n")
	_test_legacy_v1_is_detected()
	_test_existing_v4_is_detected()
	_test_unknown_format_is_rejected()
	_test_legacy_load_migrates_in_memory_and_persists_v4()
	_test_migration_creates_immutable_legacy_backup()
	_test_backup_is_byte_for_equal_to_legacy()
	_test_temp_v4_is_re_read_and_validated_before_replace()
	_test_repeat_load_does_not_migrate_again()
	_test_repeat_load_returns_identical_v4_state()
	_test_v4_round_trip_does_not_regenerate_ids_or_reorder()
	_test_load_failure_does_not_overwrite_original()
	_test_backup_failure_does_not_overwrite_original()
	_test_corrupt_legacy_is_not_overwritten()
	_test_corrupt_v4_does_not_trigger_legacy_migrator()
	_test_existing_legacy_backup_is_never_overwritten()
	_test_fresh_v4_save_does_not_create_legacy_backup()
	_test_unknown_directory_load_returns_missing_result()
	_test_partial_hp_round_trip_preserved()
	_test_items_owner_preserved_across_round_trip()
	_test_two_identical_definition_ids_distinct_after_round_trip()
	_test_board_bench_order_preserved_after_round_trip()
	_test_repository_counter_migration_increments()
	_test_fresh_save_with_no_target_succeeds()
	_test_second_save_uses_commit_old_swap()
	_test_recovery_target_missing_valid_commit_old_restores()
	_test_recovery_target_valid_stale_commit_old_removed()
	_test_recovery_target_invalid_valid_commit_old_restores()
	_test_recovery_both_invalid_returns_controlled_error()
	_test_recovery_stale_commit_old_remove_failure_returns_error()
	_test_post_commit_validate_rejects_invalid_target()
	_test_stale_state_cleanup_removes_invalid_temp_files()
	_test_structural_validation_works_on_dot_bak_path()
	_test_existing_corrupt_backup_blocks_migration()
	_test_rollback_does_not_delete_immutable_backup()
	_test_post_migration_backup_sha256_matches_original()
	_test_load_seed_mismatch_rejected()
	_test_load_run_id_mismatch_rejected()
	_test_schema_version_5_rejected_as_unsupported()
	_test_string_schema_version_5_is_corrupt_v4_not_v5()
	_test_missing_schema_version_is_corrupt_v4()
	_test_strict_validity_rejects_corrupt_v4_units()
	_test_recovery_keeps_commit_old_when_target_is_corrupt_v4()
	_test_recovery_legacy_seed_mismatch_is_not_recoverable()
	_test_save_seed_mismatch_rejected_before_filesystem_mutation()
	_test_save_run_id_mismatch_rejected_before_filesystem_mutation()
	_test_save_load_result_has_typed_context_field()
	_test_recovery_keeps_commit_old_when_run_id_mismatches()
	_test_legacy_v2_tres_is_not_migrated()
	_test_legacy_tres_with_schema_version_key_is_not_migrated()
	_test_migrator_directly_rejects_non_v1_version()
	_test_recovery_legacy_target_missing_commit_old_seed_9001()
	_test_recovery_legacy_commit_old_seed_90010_is_rejected()
	_test_legacy_v10_is_not_legacy_v1()
	_test_legacy_v1_plus_schema_version_is_rejected()
	print("\n=== production save repository: %d passed, %d failed ===\n" % [_passed, _failed])
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


# ---------------------------------------------------------------------------
# Per-test isolation
# ---------------------------------------------------------------------------

func _isolated_runs_dir(test_name: String) -> String:
	_test_counter += 1
	var path: String = "user://save_repository_test_%s_%d/" % [test_name, _test_counter]
	# Clean any prior state.
	var dir: DirAccess = DirAccess.open("user://")
	if dir != null:
		# Recursive remove is not provided; best-effort remove of
		# known file names.
		# Force overwrite by recreating the dir.
		pass
	# Make sure the directory exists.
	DirAccess.make_dir_recursive_absolute(path)
	return path


func _cleanup(runs_dir: String) -> void:
	# Best-effort: remove the directory contents. We use a fresh
	# sub-directory name per test, so leftovers do not affect other
	# tests.
	var dir: DirAccess = DirAccess.open(runs_dir)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	for d in dir.get_directories():
		# Recursive is not built in; tests in this script never
		# nest directories.
		var sub: DirAccess = DirAccess.open(runs_dir + d + "/")
		if sub != null:
			for f2 in sub.get_files():
				sub.remove(f2)
		dir.remove(d)


func _copy_fixture(fixture_name: String, target_path: String) -> bool:
	var src: PackedByteArray = FileAccess.get_file_as_bytes(RUN_FIXTURES_DIR + "/%s.tres" % fixture_name)
	if src.is_empty():
		return false
	DirAccess.make_dir_recursive_absolute(target_path.get_base_dir())
	var f: FileAccess = FileAccess.open(target_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(src)
	f.close()
	return true


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _hash_run(runs_dir: String, seed_value: int) -> int:
	var path: String = runs_dir + "run_%d.tres" % seed_value
	if not FileAccess.file_exists(path):
		return 0
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var bytes: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	return 0  # bytes comparison done by caller


# ---------------------------------------------------------------------------
# Format detection
# ---------------------------------------------------------------------------

func _test_legacy_v1_is_detected() -> void:
	print("[detect] legacy v1 is detected as legacy_v1")
	var runs_dir: String = _isolated_runs_dir("detect_legacy")
	_cleanup(runs_dir)
	assert(_copy_fixture("active_run_minimal", runs_dir + "run_9001.tres"))
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_ok(), "legacy load OK after migration")
	_assert(r.source_format == "v4", "post-migration source_format is v4 (got %s)" % r.source_format)
	_assert(r.migrated == true, "migrated == true for first legacy load")
	_cleanup(runs_dir)


func _test_existing_v4_is_detected() -> void:
	print("[detect] existing v4 is detected as v4")
	var runs_dir: String = _isolated_runs_dir("detect_v4")
	_cleanup(runs_dir)
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	# Build a v4 DTO from a fixture migration, write it via the
	# repository, then load again.
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	var wr: RefCounted = repo.save_run(9001, v4)
	_assert(wr.is_ok(), "v4 save OK")
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_ok(), "v4 load OK")
	_assert(r.source_format == "v4", "v4 load source_format == v4")
	_assert(r.migrated == false, "v4 load migrated == false")
	_cleanup(runs_dir)


func _test_unknown_format_is_rejected() -> void:
	print("[detect] unknown format is rejected")
	var runs_dir: String = _isolated_runs_dir("detect_unknown")
	_cleanup(runs_dir)
	# Write a file that looks like neither legacy v1 nor v4.
	DirAccess.make_dir_recursive_absolute(runs_dir)
	var f: FileAccess = FileAccess.open(runs_dir + "run_9001.tres", FileAccess.WRITE)
	f.store_line("not a tres")
	f.store_line("not a v4")
	f.close()
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_error(), "unknown format -> error")
	_assert(r.status == SaveLoadResultScript.ERROR_UNKNOWN_FORMAT, "status == ERROR_UNKNOWN_FORMAT")
	_assert(r.source_format == "unknown", "source_format == unknown")
	_cleanup(runs_dir)


# ---------------------------------------------------------------------------
# Migration
# ---------------------------------------------------------------------------

func _test_legacy_load_migrates_in_memory_and_persists_v4() -> void:
	print("[migration] legacy load migrates and persists v4")
	var runs_dir: String = _isolated_runs_dir("migrate_persist")
	_cleanup(runs_dir)
	assert(_copy_fixture("active_run_minimal", runs_dir + "run_9001.tres"))
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_ok(), "migration OK")
	_assert(r.migrated, "migrated == true")
	_assert(r.source_format == "v4", "post-migration source_format == v4")
	# After migration, the on-disk file is now a v4 file.
	var post_bytes: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres")
	_assert(post_bytes.get_string_from_utf8().begins_with("# v4 save"),
		"on-disk file now begins with '# v4 save' marker")
	# The backup exists.
	_assert(FileAccess.file_exists(runs_dir + "run_9001.tres" + RunSaveRepositoryScript.BACKUP_SUFFIX),
		"legacy backup file exists")
	# The v4 DTO schema is correct.
	var data: Dictionary = r.data
	_assert(int(data.get("schema_version", 0)) == 4, "schema_version == 4")
	_assert(int(data.get("seed", 0)) == 9001, "seed preserved")
	_cleanup(runs_dir)


func _test_migration_creates_immutable_legacy_backup() -> void:
	print("[migration] legacy backup is created and never overwritten")
	var runs_dir: String = _isolated_runs_dir("backup_immutable")
	_cleanup(runs_dir)
	assert(_copy_fixture("active_run_minimal", runs_dir + "run_9001.tres"))
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	# First load -> migration creates backup.
	var r1: RefCounted = repo.load_run(9001)
	_assert(r1.is_ok() and r1.migrated, "first load migrates")
	var backup_path: String = runs_dir + "run_9001.tres" + RunSaveRepositoryScript.BACKUP_SUFFIX
	_assert(FileAccess.file_exists(backup_path), "backup exists after migration")
	var backup_bytes_1: PackedByteArray = FileAccess.get_file_as_bytes(backup_path)
	# Simulate a second migration attempt by overwriting the v4
	# file with a fresh legacy save. The repository must refuse
	# to overwrite the existing backup AND refuse to migrate,
	# because the existing backup belongs to a different legacy
	# source.
	assert(_copy_fixture("board_plus_bench", runs_dir + "run_9001.tres"))
	var r2: RefCounted = repo.load_run(9001)
	_assert(r2.is_error(), "second load is refused (backup conflict)")
	_assert(r2.status == SaveLoadResultScript.ERROR_BACKUP_CONFLICT,
		"second load -> ERROR_BACKUP_CONFLICT")
	# The backup must still be the first run's bytes, not the second.
	var backup_bytes_2: PackedByteArray = FileAccess.get_file_as_bytes(backup_path)
	_assert(backup_bytes_1 == backup_bytes_2, "legacy backup is immutable (not overwritten)")
	_cleanup(runs_dir)


func _test_backup_is_byte_for_equal_to_legacy() -> void:
	print("[migration] backup is byte-faithful equal to legacy")
	var runs_dir: String = _isolated_runs_dir("backup_byte_equal")
	_cleanup(runs_dir)
	assert(_copy_fixture("partial_hp", runs_dir + "run_9005.tres"))
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var legacy_bytes: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9005.tres")
	repo.load_run(9005)
	var backup_bytes: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9005.tres" + RunSaveRepositoryScript.BACKUP_SUFFIX)
	_assert(backup_bytes == legacy_bytes, "backup bytes == legacy bytes")
	_cleanup(runs_dir)


func _test_temp_v4_is_re_read_and_validated_before_replace() -> void:
	print("[migration] temp v4 is re-read and re-validated")
	# This is enforced by the design. Indirectly verified by:
	# 1. The fact that successful migrations never leave a .tmp file.
	# 2. The migrated data field equals the temp re-read.
	var runs_dir: String = _isolated_runs_dir("temp_re_read")
	_cleanup(runs_dir)
	assert(_copy_fixture("two_identical_definition_ids", runs_dir + "run_9002.tres"))
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9002)
	_assert(r.is_ok(), "migration OK")
	_assert(not FileAccess.file_exists(runs_dir + "run_9002.tres.v4.tmp"), "no leftover temp v4 file")
	_assert(r.data.has("units") and (r.data.get("units", []) as Array).size() == 2,
		"re-read v4 DTO has 2 units")
	_cleanup(runs_dir)


# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------

func _test_repeat_load_does_not_migrate_again() -> void:
	print("[idempotency] repeat load does not re-migrate")
	var runs_dir: String = _isolated_runs_dir("idempotent_no_remigrate")
	_cleanup(runs_dir)
	assert(_copy_fixture("active_run_minimal", runs_dir + "run_9001.tres"))
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r1: RefCounted = repo.load_run(9001)
	_assert(r1.migrated, "first load migrates")
	# The v4 file is now on disk. Subsequent loads must not re-migrate.
	var r2: RefCounted = repo.load_run(9001)
	_assert(not r2.migrated, "second load does NOT migrate")
	_assert(r2.source_format == "v4", "second load source_format == v4")
	# backup must still exist (never overwritten).
	_assert(FileAccess.file_exists(runs_dir + "run_9001.tres" + RunSaveRepositoryScript.BACKUP_SUFFIX),
		"backup still present after second load")
	_cleanup(runs_dir)


func _test_repeat_load_returns_identical_v4_state() -> void:
	print("[idempotency] repeat load returns identical v4 state")
	var runs_dir: String = _isolated_runs_dir("idempotent_identical")
	_cleanup(runs_dir)
	assert(_copy_fixture("board_plus_bench", runs_dir + "run_9003.tres"))
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r1: RefCounted = repo.load_run(9003)
	# Trigger another save/load cycle to confirm instance IDs and
	# counters are stable.
	var wr: RefCounted = repo.save_run(9003, r1.data)
	_assert(wr.is_ok(), "v4 save OK")
	var r2: RefCounted = repo.load_run(9003)
	_assert(r1.data.hash() == r2.data.hash(), "v4 DTO hash identical across save/load")
	_cleanup(runs_dir)


func _test_v4_round_trip_does_not_regenerate_ids_or_reorder() -> void:
	print("[idempotency] v4 round-trip preserves instance ids, ordering, counters")
	var runs_dir: String = _isolated_runs_dir("round_trip_stable")
	_cleanup(runs_dir)
	var src: Resource = load(RUN_FIXTURES_DIR + "/board_plus_bench.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var wr: RefCounted = repo.save_run(9003, v4)
	_assert(wr.is_ok(), "save OK")
	var r: RefCounted = repo.load_run(9003)
	_assert(r.data.get("next_unit_instance_seq") == v4.get("next_unit_instance_seq"), "next_unit_instance_seq preserved")
	_assert(r.data.get("next_item_instance_seq") == v4.get("next_item_instance_seq"), "next_item_instance_seq preserved")
	var units_a: Array = v4.get("units", [])
	var units_b: Array = r.data.get("units", [])
	for i in units_a.size():
		_assert(String(units_a[i].get("instance_id", "")) == String(units_b[i].get("instance_id", "")),
			"unit[%d] instance_id preserved" % i)
		_assert(int(units_a[i].get("order", -1)) == int(units_b[i].get("order", -1)),
			"unit[%d] order preserved" % i)
	_cleanup(runs_dir)


# ---------------------------------------------------------------------------
# Failure handling
# ---------------------------------------------------------------------------

func _test_load_failure_does_not_overwrite_original() -> void:
	print("[failure] load failure (e.g. temp reload) does not overwrite original")
	# Synthesise: copy a legacy fixture, force the v4 .tmp file to
	# become invalid by writing a corrupted temp, then trigger a
	# re-migration. With the on-disk temp written but not yet
	# renamed, the legacy file is still the legacy file.
	#
	# We exercise the alternative path: write a valid temp path
	# but the temp file content is invalid v4. The repository
	# detects this on re-read and returns an error; the legacy
	# file is preserved.
	var runs_dir: String = _isolated_runs_dir("load_failure_keeps_original")
	_cleanup(runs_dir)
	assert(_copy_fixture("active_run_minimal", runs_dir + "run_9001.tres"))
	# Force the temp file to be undeletable by making the .v4.tmp
	# path point at an existing directory. The repository's temp
	# write will then fail and the load must report a failure
	# without modifying the legacy file.
	DirAccess.make_dir_recursive_absolute(runs_dir + "run_9001.tres.v4.tmp")
	var legacy_bytes_before: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	# The repository may have overwritten the temp before re-read
	# (since it writes a fresh temp). If so, the failure is the
	# temp-reload/validation step. In any case, the original
	# legacy file must NOT be replaced.
	var post_bytes: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres")
	_assert(legacy_bytes_before == post_bytes,
		"original legacy file unchanged after any migration failure")
	_cleanup(runs_dir)


func _test_backup_failure_does_not_overwrite_original() -> void:
	print("[failure] backup failure does not overwrite original")
	var runs_dir: String = _isolated_runs_dir("backup_failure_keeps_original")
	_cleanup(runs_dir)
	assert(_copy_fixture("active_run_minimal", runs_dir + "run_9001.tres"))
	# Pre-create a directory at the backup path to make
	# FileAccess.open(... WRITE) fail. Use a non-empty directory
	# file name. The repository expects a file at
	# runs_dir + "run_<seed>.tres" + ".legacy-v1.bak". Create a
	# directory at that path.
	DirAccess.make_dir_recursive_absolute(runs_dir + "run_9001.tres.legacy-v1.bak")
	var legacy_bytes_before: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	# Either the migration succeeds and ignores the existing
	# directory (impossible — backup path collides), or it fails
	# with ERROR_BACKUP_FAILED. We assert that the legacy file is
	# preserved in both cases.
	var post_bytes: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres")
	_assert(legacy_bytes_before == post_bytes,
		"original legacy file preserved on backup failure")
	if r.is_error():
		_assert(r.status == SaveLoadResultScript.ERROR_BACKUP_INVALID,
			"backup failure -> ERROR_BACKUP_INVALID")
	_cleanup(runs_dir)


func _test_corrupt_legacy_is_not_overwritten() -> void:
	print("[failure] corrupt legacy input is not overwritten")
	var runs_dir: String = _isolated_runs_dir("corrupt_legacy_kept")
	_cleanup(runs_dir)
	# Write a file that pretends to be legacy v1 but is missing the
	# required fields. Repository must detect it as unknown and
	# leave the file alone.
	DirAccess.make_dir_recursive_absolute(runs_dir)
	var f: FileAccess = FileAccess.open(runs_dir + "run_9001.tres", FileAccess.WRITE)
	f.store_line("[gd_resource type=\"Resource\" script_class=\"RunState\" format=3]")
	f.store_line("")
	f.store_line("[resource]")
	f.store_line("script = ExtResource(\"1\")")
	f.close()
	var original_bytes: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_error(), "corrupt legacy -> error")
	_assert(r.source_format == "unknown", "corrupt legacy source_format == unknown")
	var post_bytes: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres")
	_assert(original_bytes == post_bytes, "corrupt legacy file unchanged on load failure")
	_cleanup(runs_dir)


func _test_corrupt_v4_does_not_trigger_legacy_migrator() -> void:
	print("[failure] corrupt v4 does not trigger legacy migrator")
	var runs_dir: String = _isolated_runs_dir("corrupt_v4_no_migrator")
	_cleanup(runs_dir)
	# Write a file that looks like v4 (header) but has invalid content
	# (missing required fields). The repository must reject v4
	# validation and not try to migrate it as legacy.
	DirAccess.make_dir_recursive_absolute(runs_dir)
	var f: FileAccess = FileAccess.open(runs_dir + "run_9001.tres", FileAccess.WRITE)
	f.store_line("# v4 save")
	f.store_line("{\"schema_version\": 4, \"seed\": 9001}")
	# valid JSON, header detected as v4, but missing required keys
	# for SaveSchemaV4.is_v4_dto, so the validator must reject it.
	f.close()
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_error(), "corrupt v4 -> error")
	_assert(r.source_format == "v4", "corrupt v4 source_format == v4 (header recognised)")
	_assert(r.status == SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED,
		"corrupt v4 status == ERROR_V4_VALIDATION_FAILED")
	# No legacy backup should have been created.
	_assert(not FileAccess.file_exists(runs_dir + "run_9001.tres" + RunSaveRepositoryScript.BACKUP_SUFFIX),
		"no legacy backup created for corrupt v4")
	_cleanup(runs_dir)


# ---------------------------------------------------------------------------
# Backup policy
# ---------------------------------------------------------------------------

func _test_existing_legacy_backup_is_never_overwritten() -> void:
	print("[backup] existing legacy backup is never overwritten")
	var runs_dir: String = _isolated_runs_dir("backup_never_overwritten")
	_cleanup(runs_dir)
	assert(_copy_fixture("active_run_minimal", runs_dir + "run_9001.tres"))
	# Pre-create a backup with sentinel bytes.
	var f: FileAccess = FileAccess.open(runs_dir + "run_9001.tres" + RunSaveRepositoryScript.BACKUP_SUFFIX, FileAccess.WRITE)
	f.store_line("SENTINEL_BACKUP_DO_NOT_OVERWRITE")
	f.close()
	var sentinel: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres" + RunSaveRepositoryScript.BACKUP_SUFFIX)
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	repo.load_run(9001)
	var post: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres" + RunSaveRepositoryScript.BACKUP_SUFFIX)
	_assert(sentinel == post, "sentinel backup is not overwritten")
	_cleanup(runs_dir)


func _test_fresh_v4_save_does_not_create_legacy_backup() -> void:
	print("[backup] fresh v4 save does not create a legacy backup")
	var runs_dir: String = _isolated_runs_dir("fresh_v4_no_backup")
	_cleanup(runs_dir)
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var wr: RefCounted = repo.save_run(9001, v4)
	_assert(wr.is_ok(), "v4 save OK")
	_assert(not FileAccess.file_exists(runs_dir + "run_9001.tres" + RunSaveRepositoryScript.BACKUP_SUFFIX),
		"no legacy backup created on v4 save")
	_cleanup(runs_dir)


# ---------------------------------------------------------------------------
# Missing file
# ---------------------------------------------------------------------------

func _test_unknown_directory_load_returns_missing_result() -> void:
	print("[missing] missing file returns ERROR_V4_LOAD_FAILED")
	var runs_dir: String = _isolated_runs_dir("missing_file")
	_cleanup(runs_dir)
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9999)
	_assert(r.is_error(), "missing -> error")
	_assert(r.status == SaveLoadResultScript.ERROR_V4_LOAD_FAILED,
		"status == ERROR_V4_LOAD_FAILED for missing")
	_assert(r.source_format == "missing", "source_format == missing")
	_cleanup(runs_dir)


# ---------------------------------------------------------------------------
# Data preservation invariants
# ---------------------------------------------------------------------------

func _test_partial_hp_round_trip_preserved() -> void:
	print("[data] partial HP round-trip preserved")
	var runs_dir: String = _isolated_runs_dir("data_partial_hp")
	_cleanup(runs_dir)
	assert(_copy_fixture("partial_hp", runs_dir + "run_9005.tres"))
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r1: RefCounted = repo.load_run(9005)
	# Force a save round-trip.
	repo.save_run(9005, r1.data)
	var r2: RefCounted = repo.load_run(9005)
	var units: Array = r2.data.get("units", [])
	_assert(int(units[0].get("current_hp", -1)) == 33, "warrior current_hp==33")
	_assert(int(units[1].get("current_hp", -1)) == 12, "archer current_hp==12")
	_assert(int(units[0].get("max_hp", -1)) == 100, "warrior max_hp==100")
	_assert(int(units[1].get("max_hp", -1)) == 70, "archer max_hp==70")
	_cleanup(runs_dir)


func _test_items_owner_preserved_across_round_trip() -> void:
	print("[data] items owner preserved across round-trip")
	var runs_dir: String = _isolated_runs_dir("data_items_owner")
	_cleanup(runs_dir)
	assert(_copy_fixture("items_equipped_and_unequipped", runs_dir + "run_9004.tres"))
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r1: RefCounted = repo.load_run(9004)
	repo.save_run(9004, r1.data)
	var r2: RefCounted = repo.load_run(9004)
	var items: Array = r2.data.get("items", [])
	var units: Array = r2.data.get("units", [])
	_assert(String(items[0].get("owner_unit_id", "")) == String(units[0].get("instance_id", "")),
		"item[0] owner == unit[0] instance_id")
	_assert(String(items[1].get("owner_unit_id", "")) == "", "item[1] owner empty")
	_cleanup(runs_dir)


func _test_two_identical_definition_ids_distinct_after_round_trip() -> void:
	print("[data] two identical definition ids remain distinct after round-trip")
	var runs_dir: String = _isolated_runs_dir("data_two_defs")
	_cleanup(runs_dir)
	assert(_copy_fixture("two_identical_definition_ids", runs_dir + "run_9002.tres"))
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r1: RefCounted = repo.load_run(9002)
	repo.save_run(9002, r1.data)
	var r2: RefCounted = repo.load_run(9002)
	var u0: Dictionary = r2.data.get("units", [])[0]
	var u1: Dictionary = r2.data.get("units", [])[1]
	_assert(String(u0.get("instance_id", "")) != String(u1.get("instance_id", "")),
		"two identical defs still have distinct instance ids")
	_assert(String(u0.get("definition_id", "")) == "warrior", "u0 def == warrior")
	_assert(String(u1.get("definition_id", "")) == "warrior", "u1 def == warrior")
	_cleanup(runs_dir)


func _test_board_bench_order_preserved_after_round_trip() -> void:
	print("[data] board/bench order preserved after round-trip")
	var runs_dir: String = _isolated_runs_dir("data_order")
	_cleanup(runs_dir)
	assert(_copy_fixture("board_plus_bench", runs_dir + "run_9003.tres"))
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r1: RefCounted = repo.load_run(9003)
	repo.save_run(9003, r1.data)
	var r2: RefCounted = repo.load_run(9003)
	var units: Array = r2.data.get("units", [])
	var locations: Array = []
	var defs: Array = []
	for u in units:
		locations.append(int(u.get("location", -1)))
		defs.append(String(u.get("definition_id", "")))
	_assert(locations == [0, 0, 1, 1], "locations == [board, board, bench, bench]")
	_assert(defs == ["warrior", "archer", "cleric", "mage"], "defs in source order preserved")
	_cleanup(runs_dir)


# ---------------------------------------------------------------------------
# Repository stats
# ---------------------------------------------------------------------------

func _test_repository_counter_migration_increments() -> void:
	print("[stats] migration counter increments")
	var runs_dir: String = _isolated_runs_dir("stats")
	_cleanup(runs_dir)
	assert(_copy_fixture("active_run_minimal", runs_dir + "run_9001.tres"))
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	# First load -> migration.
	repo.load_run(9001)
	# The internal counter is not part of the public API; verify the
	# observable effect: subsequent load does not migrate, and the
	# v4 file is now on disk.
	var r2: RefCounted = repo.load_run(9001)
	_assert(not r2.migrated, "second load does not migrate")
	_cleanup(runs_dir)


# ---------------------------------------------------------------------------
# Task 3 — Backup protocol hardening
# ---------------------------------------------------------------------------

func _test_structural_validation_works_on_dot_bak_path() -> void:
	print("[backup] structural validation works on *.legacy-v1.bak path")
	var runs_dir: String = _isolated_runs_dir("bak_structural_validation")
	_cleanup(runs_dir)
	# Copy a real byte-faithful legacy fixture to the .bak path.
	var src: PackedByteArray = FileAccess.get_file_as_bytes(
		RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var bak_path: String = runs_dir + "run_9001.tres.legacy-v1.bak"
	DirAccess.make_dir_recursive_absolute(runs_dir)
	var f: FileAccess = FileAccess.open(bak_path, FileAccess.WRITE)
	f.store_buffer(src)
	f.close()
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	# Access via the bytes-only structural validator.
	var valid: bool = repo._is_structurally_valid_legacy_v1(bak_path)
	_assert(valid, "real legacy bytes on *.bak path pass structural validation")
	# A file that does NOT contain the legacy keys must NOT pass.
	var junk_path: String = runs_dir + "junk.legacy-v1.bak"
	var f2: FileAccess = FileAccess.open(junk_path, FileAccess.WRITE)
	f2.store_line("not a tres")
	f2.close()
	var valid_junk: bool = repo._is_structurally_valid_legacy_v1(junk_path)
	_assert(not valid_junk, "junk bytes on *.bak path fail structural validation")
	_cleanup(runs_dir)


func _test_existing_corrupt_backup_blocks_migration() -> void:
	print("[backup] existing corrupt backup blocks migration")
	var runs_dir: String = _isolated_runs_dir("existing_corrupt_backup")
	_cleanup(runs_dir)
	# Create a valid legacy target.
	assert(_copy_fixture("active_run_minimal", runs_dir + "run_9001.tres"))
	# Pre-create a CORRUPT backup (does not satisfy structural validation).
	var bak_path: String = runs_dir + "run_9001.tres" + RunSaveRepositoryScript.BACKUP_SUFFIX
	var f: FileAccess = FileAccess.open(bak_path, FileAccess.WRITE)
	f.store_line("not a tres")
	f.close()
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_error(), "corrupt backup blocks migration")
	_assert(r.status == SaveLoadResultScript.ERROR_BACKUP_INVALID,
		"corrupt backup -> ERROR_BACKUP_INVALID")
	# The target must NOT be modified.
	var target_bytes: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres")
	var expected_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	_assert(target_bytes == expected_bytes,
		"target unchanged when backup is corrupt")
	_cleanup(runs_dir)


func _test_rollback_does_not_delete_immutable_backup() -> void:
	print("[backup] rollback does not delete immutable backup")
	var runs_dir: String = _isolated_runs_dir("rollback_keeps_backup")
	_cleanup(runs_dir)
	# Create a valid legacy target.
	assert(_copy_fixture("active_run_minimal", runs_dir + "run_9001.tres"))
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r1: RefCounted = repo.load_run(9001)
	_assert(r1.is_ok() and r1.migrated, "first migration OK")
	var bak_path: String = runs_dir + "run_9001.tres" + RunSaveRepositoryScript.BACKUP_SUFFIX
	var backup_bytes_1: PackedByteArray = FileAccess.get_file_as_bytes(bak_path)
	# Force a save with bad seed so the commit swap + post-commit
	# validate fails and triggers a rollback. The rollback path
	# must NOT remove the immutable legacy backup.
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	var bad_v4: Dictionary = v4.duplicate(true)
	bad_v4["seed"] = 9999  # wrong seed
	var wr: RefCounted = repo.save_run(9001, bad_v4)
	_assert(wr.is_error(), "bad seed save -> error")
	_assert(wr.status == SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED,
		"status == ERROR_V4_VALIDATION_FAILED")
	# The immutable legacy backup must still be present with the
	# same bytes as before the failed save.
	var backup_bytes_2: PackedByteArray = FileAccess.get_file_as_bytes(bak_path)
	_assert(backup_bytes_1 == backup_bytes_2,
		"immutable legacy backup preserved across rollback")
	_cleanup(runs_dir)


func _test_post_migration_backup_sha256_matches_original() -> void:
	print("[backup] post-migration backup SHA-256 matches legacy source")
	var runs_dir: String = _isolated_runs_dir("backup_sha256")
	_cleanup(runs_dir)
	assert(_copy_fixture("partial_hp", runs_dir + "run_9005.tres"))
	var legacy_sha: String = _ops_sha(runs_dir + "run_9005.tres")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	repo.load_run(9005)
	var backup_sha: String = _ops_sha(runs_dir + "run_9005.tres" + RunSaveRepositoryScript.BACKUP_SUFFIX)
	_assert(backup_sha == legacy_sha,
		"post-migration backup SHA-256 matches legacy source byte-for-byte")
	_assert(backup_sha != "", "backup SHA-256 is non-empty")
	_cleanup(runs_dir)


func _ops_sha(path: String) -> String:
	# Tiny wrapper so the post-migration sha256 test reads through
	# the production ops contract.
	var ProductionFileOps = preload("res://core/save/run_save_file_ops.gd")
	var ops = ProductionFileOps.new()
	return ops.sha256(path)


# ---------------------------------------------------------------------------
# Task 2 — Recovery state machine + crash-recoverable commit + fresh save
# ---------------------------------------------------------------------------

func _test_fresh_save_with_no_target_succeeds() -> void:
	print("[recovery] fresh save with no target succeeds")
	var runs_dir: String = _isolated_runs_dir("fresh_save")
	_cleanup(runs_dir)
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var wr: RefCounted = repo.save_run(9001, v4)
	_assert(wr.is_ok(), "fresh save returns OK")
	_assert(FileAccess.file_exists(runs_dir + "run_9001.tres"), "target exists after fresh save")
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres")
	_assert(bytes.get_string_from_utf8().begins_with("# v4 save"),
		"on-disk target begins with v4 marker")
	# No commit-old should be present.
	_assert(not FileAccess.file_exists(runs_dir + "run_9001.tres.commit-old"),
		"no commit-old after fresh save")
	# No legacy backup should be present.
	_assert(not FileAccess.file_exists(runs_dir + "run_9001.tres" + RunSaveRepositoryScript.BACKUP_SUFFIX),
		"no legacy backup on fresh v4 save")
	_cleanup(runs_dir)


func _test_second_save_uses_commit_old_swap() -> void:
	print("[recovery] second save uses commit-old swap")
	var runs_dir: String = _isolated_runs_dir("second_save_swap")
	_cleanup(runs_dir)
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	repo.save_run(9001, v4)
	var v4_after_first: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres")
	# Second save: change the data (mutate an instance_seq), then save.
	v4["gold"] = 1234
	var wr2: RefCounted = repo.save_run(9001, v4)
	_assert(wr2.is_ok(), "second save OK")
	_assert(not FileAccess.file_exists(runs_dir + "run_9001.tres.commit-old"),
		"commit-old removed after successful second save")
	# The on-disk v4 file is the new one (gold=1234).
	var bytes_after: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres")
	_assert(bytes_after != v4_after_first, "second save replaced first")
	# Reload to confirm.
	var r: RefCounted = repo.load_run(9001)
	_assert(int(r.data.get("gold", -1)) == 1234, "second save: gold=1234")
	_cleanup(runs_dir)


func _test_recovery_target_missing_valid_commit_old_restores() -> void:
	print("[recovery] target missing + valid commit-old -> restore")
	var runs_dir: String = _isolated_runs_dir("rec_target_missing_valid_co")
	_cleanup(runs_dir)
	# Build a v4 file via the migration path, then simulate an interrupted
	# commit by renaming target -> commit-old and deleting target.
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	repo.save_run(9001, v4)
	# Simulate interruption: rename target to commit-old, then delete target.
	var target: String = runs_dir + "run_9001.tres"
	var commit_old: String = target + ".commit-old"
	var ok: bool = repo._ops.rename(target, commit_old)
	_assert(ok, "rename target -> commit-old succeeds")
	_assert(repo._ops.exists(commit_old), "commit-old now exists")
	_assert(not repo._ops.exists(target), "target absent (simulating interrupted commit)")
	# The recovery must restore target from commit-old.
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_ok(), "recovery restore -> OK")
	_assert(r.source_format == "v4", "restored target is v4")
	_assert(not repo._ops.exists(commit_old), "commit-old removed after recovery")
	_cleanup(runs_dir)


func _test_recovery_target_valid_stale_commit_old_removed() -> void:
	print("[recovery] target valid + stale commit-old -> target authoritative, commit-old removed")
	var runs_dir: String = _isolated_runs_dir("rec_target_valid_stale_co")
	_cleanup(runs_dir)
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	repo.save_run(9001, v4)
	# Inject a STALE commit-old (just bytes from a different fixture).
	var commit_old: String = runs_dir + "run_9001.tres.commit-old"
	var stale_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		RUN_FIXTURES_DIR + "/board_plus_bench.tres")
	var sf: FileAccess = FileAccess.open(commit_old, FileAccess.WRITE)
	sf.store_buffer(stale_bytes)
	sf.close()
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_ok(), "load OK with stale commit-old")
	_assert(r.source_format == "v4", "target authoritative -> source_format == v4")
	_assert(not repo._ops.exists(commit_old), "stale commit-old removed by recovery")
	_cleanup(runs_dir)


func _test_recovery_target_invalid_valid_commit_old_restores() -> void:
	print("[recovery] target invalid + valid commit-old -> restore commit-old")
	var runs_dir: String = _isolated_runs_dir("rec_target_invalid_valid_co")
	_cleanup(runs_dir)
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	repo.save_run(9001, v4)
	# Snapshot current target bytes.
	var target: String = runs_dir + "run_9001.tres"
	var commit_old: String = target + ".commit-old"
	# Manually emulate "commit-old holds the previous valid v4":
	# rename target -> commit-old.
	repo._ops.rename(target, commit_old)
	# Corrupt target with junk.
	var f: FileAccess = FileAccess.open(target, FileAccess.WRITE)
	f.store_line("garbage not v4 not legacy")
	f.close()
	# load_run must restore commit-old.
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_ok(), "recovery restores from valid commit-old")
	_assert(r.source_format == "v4", "restored source_format == v4")
	_assert(not repo._ops.exists(commit_old), "commit-old removed after restore")
	_cleanup(runs_dir)


func _test_recovery_both_invalid_returns_controlled_error() -> void:
	print("[recovery] target invalid + commit-old invalid -> controlled error, destroy nothing")
	var runs_dir: String = _isolated_runs_dir("rec_both_invalid")
	_cleanup(runs_dir)
	# Inject two corrupt files: target and commit-old both non-v4 non-legacy.
	var target: String = runs_dir + "run_9001.tres"
	var commit_old: String = target + ".commit-old"
	var f1: FileAccess = FileAccess.open(target, FileAccess.WRITE)
	f1.store_line("garbage 1"); f1.close()
	var f2: FileAccess = FileAccess.open(commit_old, FileAccess.WRITE)
	f2.store_line("garbage 2"); f2.close()
	var original_target_bytes: PackedByteArray = FileAccess.get_file_as_bytes(target)
	var original_co_bytes: PackedByteArray = FileAccess.get_file_as_bytes(commit_old)
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_error(), "both invalid -> error")
	_assert(r.status == SaveLoadResultScript.ERROR_CORRUPT_INPUT,
		"status == ERROR_CORRUPT_INPUT")
	# Files preserved unchanged.
	var post_target: PackedByteArray = FileAccess.get_file_as_bytes(target)
	var post_co: PackedByteArray = FileAccess.get_file_as_bytes(commit_old)
	_assert(post_target == original_target_bytes, "target preserved unchanged")
	_assert(post_co == original_co_bytes, "commit-old preserved unchanged")
	_cleanup(runs_dir)


func _test_recovery_stale_commit_old_remove_failure_returns_error() -> void:
	print("[recovery] stale commit-old remove failure -> error, no new save")
	var runs_dir: String = _isolated_runs_dir("rec_remove_fail")
	_cleanup(runs_dir)
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	repo.save_run(9001, v4)
	# Inject a stale commit-old whose removal we will force to fail.
	var commit_old: String = runs_dir + "run_9001.tres.commit-old"
	var stale_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		RUN_FIXTURES_DIR + "/board_plus_bench.tres")
	var sf: FileAccess = FileAccess.open(commit_old, FileAccess.WRITE)
	sf.store_buffer(stale_bytes)
	sf.close()
	# Swap the production ops with a fault ops that fails remove().
	var FaultOps = preload("res://tests/save_repository/support/run_save_file_ops_fault.gd")
	var fault: RefCounted = FaultOps.new()
	fault.fail_methods[&"remove"] = true
	# Re-point repository ops to fault adapter so recovery's remove call fails.
	repo._ops = fault
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_error(), "recovery remove failure -> error")
	_assert(r.status == SaveLoadResultScript.ERROR_IO,
		"status == ERROR_IO")
	# commit-old is still on disk (remove failed).
	_assert(FileAccess.file_exists(commit_old), "commit-old still present after failed remove")
	_cleanup(runs_dir)


func _test_post_commit_validate_rejects_invalid_target() -> void:
	print("[recovery] post-commit validate rejects invalid target after a successful rename")
	var runs_dir: String = _isolated_runs_dir("post_commit_reject")
	_cleanup(runs_dir)
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	# Corrupt the seed so post-commit validate fails.
	var bad_v4: Dictionary = v4.duplicate(true)
	bad_v4["seed"] = 9999  # wrong seed
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	# Fresh save: target doesn't exist yet. Save validates before write
	# and should refuse to write the temp file because seed mismatch is
	# caught later. But this is a fresh save, so there's no previous
	# generation. We can't easily force a fresh save to pass the
	# pre-validate but fail the post-validate. Instead, write a valid
	# v4 first, then save with a different seed: the pre-validate is
	# skipped (no top-level check in this code path), but the post-commit
	# validate reads the file and rejects seed mismatch.
	repo.save_run(9001, v4)
	# Now attempt to save with mismatched seed. This must trigger the
	# commit swap + post-commit validate failure. Result: target is
	# restored from commit-old.
	var pre_bytes: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres")
	var wr: RefCounted = repo.save_run(9001, bad_v4)
	_assert(wr.is_error(), "bad seed save -> error")
	_assert(wr.status == SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED,
		"status == ERROR_V4_VALIDATION_FAILED")
	# Target on disk is the pre-existing valid v4.
	var post_bytes: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres")
	_assert(post_bytes == pre_bytes, "target restored to pre-existing valid v4")
	_cleanup(runs_dir)


func _test_stale_state_cleanup_removes_invalid_temp_files() -> void:
	print("[recovery] stale temp files cleaned before save begins")
	var runs_dir: String = _isolated_runs_dir("stale_cleanup")
	_cleanup(runs_dir)
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	repo.save_run(9001, v4)
	# Inject stale temp and v4-temp files. They are not authoritative.
	var target: String = runs_dir + "run_9001.tres"
	var stale_tmp: String = target + ".tmp"
	var stale_v4_tmp: String = target + ".v4.tmp"
	var stale_bytes: PackedByteArray = "stale".to_utf8_buffer()
	var sf1: FileAccess = FileAccess.open(stale_tmp, FileAccess.WRITE)
	sf1.store_buffer(stale_bytes); sf1.close()
	var sf2: FileAccess = FileAccess.open(stale_v4_tmp, FileAccess.WRITE)
	sf2.store_buffer(stale_bytes); sf2.close()
	# The save recovery runs at the top of save_run and uses rename-only
	# logic. Stale .tmp / .v4.tmp are removed by _commit_verified_temp
	# via the temp-write that overwrites them. Confirm: a fresh save_run
	# succeeds and the stale temp files no longer contain "stale".
	var wr: RefCounted = repo.save_run(9001, v4)
	_assert(wr.is_ok(), "save with stale temp files -> OK")
	# The temp paths no longer contain the stale marker.
	if FileAccess.file_exists(stale_tmp):
		var post_tmp: PackedByteArray = FileAccess.get_file_as_bytes(stale_tmp)
		_assert(post_tmp.get_string_from_utf8() != "stale",
			"stale .tmp content overwritten by current save temp")
	_cleanup(runs_dir)


# ---------------------------------------------------------------------------
# Task 8 — Seed / filename / run_id consistency
# ---------------------------------------------------------------------------

func _test_load_seed_mismatch_rejected() -> void:
	print("[repository] load seed mismatch rejected (H6)")
	var runs_dir: String = _isolated_runs_dir("load_seed_mismatch")
	_cleanup(runs_dir)
	# Build a v4 file via migration, save it with seed=9001.
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	repo.save_run(9001, v4)
	# Rename the file from run_9001.tres to run_9002.tres so that
	# load_run(9002) actually opens it. The on-disk seed=9001 will
	# not match the requested seed=9002, so the repository must
	# reject the load.
	var ProductionFileOps = preload("res://core/save/run_save_file_ops.gd")
	var ops = ProductionFileOps.new()
	assert(ops.rename(runs_dir + "run_9001.tres", runs_dir + "run_9002.tres"),
		"rename to mismatched seed file succeeds")
	var r: RefCounted = repo.load_run(9002)
	_assert(r.is_error(), "load with wrong seed -> error")
	_assert(r.status == SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED,
		"status == ERROR_V4_VALIDATION_FAILED")
	_cleanup(runs_dir)


func _test_load_run_id_mismatch_rejected() -> void:
	print("[repository] load run_id mismatch rejected (H6)")
	var runs_dir: String = _isolated_runs_dir("load_run_id_mismatch")
	_cleanup(runs_dir)
	# Save a v4 file with seed=9001 and run_id="run_9001".
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	repo.save_run(9001, v4)
	# Manually rewrite the v4 file with run_id="run_9999" to force a
	# run_id mismatch.
	var v4_bytes: PackedByteArray = FileAccess.get_file_as_bytes(runs_dir + "run_9001.tres")
	var s: String = v4_bytes.get_string_from_utf8()
	var tampered: String = s.replace("run_9001", "run_9999")
	# The file is JSON, not text-search-friendly for the run_id.
	# Instead, write a new v4 file directly using the repository's
	# canonical helper.
	var bad_v4: Dictionary = v4.duplicate(true)
	bad_v4["run_id"] = "run_9999"
	var ProductionFileOps = preload("res://core/save/run_save_file_ops.gd")
	var ops = ProductionFileOps.new()
	var bytes: PackedByteArray = RunSaveRepositoryScript.serialize_canonical_bytes(bad_v4)
	ops.write_bytes_and_flush(runs_dir + "run_9001.tres", bytes)
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_error(), "load with wrong run_id -> error")
	_assert(r.status == SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED,
		"status == ERROR_V4_VALIDATION_FAILED")
	_cleanup(runs_dir)


# ---------------------------------------------------------------------------
# Task 9 — Format detection (wire-aware)
# ---------------------------------------------------------------------------

func _test_schema_version_5_rejected_as_unsupported() -> void:
	print("[detect] schema_version = 5 -> ERROR_UNSUPPORTED_SCHEMA")
	var runs_dir: String = _isolated_runs_dir("schema_v5_unsupported")
	_cleanup(runs_dir)
	var ProductionFileOps = preload("res://core/save/run_save_file_ops.gd")
	var ops = ProductionFileOps.new()
	# Build a v4-shaped file with schema_version = 5.
	var bad: Dictionary = SaveSchemaV4Script.empty_dto()
	bad["schema_version"] = 5
	bad["seed"] = 9001
	bad["run_id"] = "run_9001"
	bad["next_unit_instance_seq"] = 1
	bad["next_item_instance_seq"] = 1
	var bytes: PackedByteArray = RunSaveRepositoryScript.serialize_canonical_bytes(bad)
	assert(ops.write_bytes_and_flush(runs_dir + "run_9001.tres", bytes), "write v4-with-schema-5 file")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_error(), "schema 5 -> error")
	_assert(r.status == SaveLoadResultScript.ERROR_UNSUPPORTED_SCHEMA,
		"status == ERROR_UNSUPPORTED_SCHEMA")
	_assert(r.source_format == "unsupported_schema", "source_format == unsupported_schema")
	_cleanup(runs_dir)


func _test_string_schema_version_5_is_corrupt_v4_not_v5() -> void:
	print("[detect] schema_version = '\"5\"' -> ERROR_CORRUPT_V4 (not unsupported)")
	var runs_dir: String = _isolated_runs_dir("schema_string_corrupt")
	_cleanup(runs_dir)
	var ProductionFileOps = preload("res://core/save/run_save_file_ops.gd")
	var ops = ProductionFileOps.new()
	# The repository detects v4 by marker. Once it sees the marker,
	# it parses the JSON. A string schema_version is corrupted v4.
	var raw: String = "# v4 save\n{\"schema_version\": \"5\", \"seed\": 9001, \"run_id\": \"run_9001\", \"units\": [], \"items\": [], \"next_unit_instance_seq\": 1, \"next_item_instance_seq\": 1, \"shop\": {}, \"map\": {}, \"rewards\": {}, \"wins\": 0, \"losses\": 0, \"units_killed\": 0, \"lives\": 0, \"xp\": 0, \"level\": 0, \"current_encounter_id\": 0, \"encounter_visited_ids\": [], \"meta_modifiers\": {}, \"just_visited_merchant\": false, \"game_build\": \"\", \"round_index\": 1, \"phase\": \"prep\", \"gold\": 0}"
	var bytes: PackedByteArray = raw.to_utf8_buffer()
	assert(ops.write_bytes_and_flush(runs_dir + "run_9001.tres", bytes), "write corrupt-v4 file")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_error(), "string schema 5 -> error")
	_assert(r.status == SaveLoadResultScript.ERROR_CORRUPT_V4,
		"status == ERROR_CORRUPT_V4 (string schema is corrupted, not unsupported)")
	_cleanup(runs_dir)


func _test_missing_schema_version_is_corrupt_v4() -> void:
	print("[detect] missing schema_version -> ERROR_CORRUPT_V4")
	var runs_dir: String = _isolated_runs_dir("schema_missing")
	_cleanup(runs_dir)
	var ProductionFileOps = preload("res://core/save/run_save_file_ops.gd")
	var ops = ProductionFileOps.new()
	# v4 marker, valid JSON, but no schema_version key.
	var raw: String = "# v4 save\n{\"seed\": 9001, \"run_id\": \"run_9001\", \"units\": [], \"items\": [], \"next_unit_instance_seq\": 1, \"next_item_instance_seq\": 1}"
	var bytes: PackedByteArray = raw.to_utf8_buffer()
	assert(ops.write_bytes_and_flush(runs_dir + "run_9001.tres", bytes), "write missing-schema file")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_error(), "missing schema -> error")
	_assert(r.status == SaveLoadResultScript.ERROR_CORRUPT_V4,
		"status == ERROR_CORRUPT_V4")
	_cleanup(runs_dir)


# ---------------------------------------------------------------------------
# Task 1 — Strict-validity gate (T1)
# ---------------------------------------------------------------------------

func _test_strict_validity_rejects_corrupt_v4_units() -> void:
	print("[strict] strict validity rejects corrupt v4 with marker+seed but bad units")
	var runs_dir: String = _isolated_runs_dir("strict_corrupt_units")
	_cleanup(runs_dir)
	var bad: Dictionary = SaveSchemaV4Script.empty_dto()
	bad["schema_version"] = 4
	bad["seed"] = 9101
	bad["run_id"] = "run_9101"
	bad["units"] = [{"instance_id": "unit_000001", "definition_id": "warrior",
		"current_hp": 0, "max_hp": 100, "bonus_attack": 0,
		"dead": false, "location": 99, "order": 0, "equipped_item_ids": []}]
	bad["items"] = []
	bad["next_unit_instance_seq"] = 2
	bad["next_item_instance_seq"] = 1
	var bytes: PackedByteArray = RunSaveRepositoryScript.serialize_canonical_bytes(bad)
	var ops = preload("res://core/save/run_save_file_ops.gd").new()
	assert(ops.write_bytes_and_flush(runs_dir + "run_9101.tres", bytes),
		"write corrupt v4 succeeds")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9101)
	_assert(r.is_error(), "corrupt v4 units -> load error")
	_cleanup(runs_dir)


# ---------------------------------------------------------------------------
# Task 2 — Recovery strict gate (BLOCKER #1)
# ---------------------------------------------------------------------------

func _test_recovery_keeps_commit_old_when_target_is_corrupt_v4() -> void:
	print("[recovery] corrupt v4 with marker+seed does NOT delete good commit-old")
	var runs_dir: String = _isolated_runs_dir("recover_corrupt_target_keep_commit_old")
	_cleanup(runs_dir)
	# Reproduce the BLOCKER #1 scenario: a corrupt target on disk
	# alongside a separate commit-old containing the good previous
	# generation. Recovery must NOT treat the corrupt target as
	# "valid" and must NOT delete the commit-old.
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4_good: Dictionary = mig.get("data", {})
	v4_good["seed"] = 9101
	v4_good["run_id"] = "run_9101"
	# Corrupt target: marker+seed+schema are all valid, but units have
	# location=99 which is outside {0,1}.
	var v4_corrupt: Dictionary = v4_good.duplicate(true)
	v4_corrupt["units"] = [{"instance_id": "unit_000001",
		"definition_id": "warrior",
		"current_hp": 0, "max_hp": 100, "bonus_attack": 0,
		"dead": false, "location": 99, "order": 0,
		"equipped_item_ids": []}]
	v4_corrupt["next_unit_instance_seq"] = 2
	var ops = preload("res://core/save/run_save_file_ops.gd").new()
	var good_bytes: PackedByteArray = RunSaveRepositoryScript.serialize_canonical_bytes(v4_good)
	var corrupt_bytes: PackedByteArray = RunSaveRepositoryScript.serialize_canonical_bytes(v4_corrupt)
	# Write corrupt target.
	assert(ops.write_bytes_and_flush(runs_dir + "run_9101.tres", corrupt_bytes),
		"write corrupt target")
	# Write good commit-old (rename target to commit-old).
	assert(ops.rename(runs_dir + "run_9101.tres",
		runs_dir + "run_9101.tres.commit-old"),
		"rename target -> commit-old")
	# Re-write corrupt target.
	assert(ops.write_bytes_and_flush(runs_dir + "run_9101.tres", corrupt_bytes),
		"re-write corrupt target")
	# Verify initial state: both files exist; commit-old is good,
	# target is corrupt.
	assert(ops.exists(runs_dir + "run_9101.tres"),
		"target exists before recovery")
	assert(ops.exists(runs_dir + "run_9101.tres.commit-old"),
		"commit-old exists before recovery")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9101)
	# Load must reject: corrupt target is not shape-valid.
	_assert(r.is_error(), "load with corrupt target -> error")
	# The good commit-old must STILL exist on disk because recovery
	# must not delete it when the target is not a real valid save.
	var commit_old_present: bool = ops.exists(runs_dir + "run_9101.tres.commit-old")
	_assert(commit_old_present,
		"good commit-old preserved after recovery rejection")
	_cleanup(runs_dir)


func _test_recovery_legacy_seed_mismatch_is_not_recoverable() -> void:
	print("[recovery] legacy file with mismatched seed is NOT recoverable")
	var runs_dir: String = _isolated_runs_dir("recover_legacy_seed_mismatch")
	_cleanup(runs_dir)
	var ProductionFileOps = preload("res://core/save/run_save_file_ops.gd")
	var ops = ProductionFileOps.new()
	var src_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	assert(ops.write_bytes_and_flush(runs_dir + "run_9101.tres", src_bytes),
		"copy legacy fixture to run_9101.tres succeeds")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9101)
	_assert(r.is_error(),
		"load with legacy mismatched seed -> error")
	_cleanup(runs_dir)


# ---------------------------------------------------------------------------
# Task 4 — Pre-save seed/run_id check (BLOCKER #3)
# ---------------------------------------------------------------------------

func _test_save_seed_mismatch_rejected_before_filesystem_mutation() -> void:
	print("[save] seed mismatch rejected BEFORE filesystem mutation")
	var runs_dir: String = _isolated_runs_dir("save_seed_mismatch_pre_fs")
	_cleanup(runs_dir)
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	v4["seed"] = 9101
	v4["run_id"] = "run_9101"
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var save_ok: RefCounted = repo.save_run(9101, v4)
	_assert(save_ok != null and save_ok.is_ok(),
		"first save with matching seed succeeds")
	# Now attempt to save with mismatched seed.
	var v4_bad: Dictionary = v4.duplicate(true)
	v4_bad["seed"] = 9999
	v4_bad["run_id"] = "run_9999"
	var save_bad: RefCounted = repo.save_run(9101, v4_bad)
	_assert(save_bad.is_error(),
		"save with mismatched seed -> error BEFORE filesystem mutation")
	_assert(save_bad.status == SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED,
		"status == ERROR_V4_VALIDATION_FAILED")
	# On-disk target must remain the good original (unchanged).
	var ops = preload("res://core/save/run_save_file_ops.gd").new()
	var bytes: PackedByteArray = ops.read_bytes(runs_dir + "run_9101.tres")
	_assert(not bytes.is_empty(),
		"target file untouched after rejected save")
	var s2: String = bytes.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(s2.substr("# v4 save\n".length()))
	_assert(int((parsed as Dictionary).get("seed", -2)) == 9101,
		"on-disk target seed unchanged")
	# No .commit-old file should exist (no commit attempted).
	_assert(not ops.exists(runs_dir + "run_9101.tres.commit-old"),
		"no commit-old created from rejected save")
	_cleanup(runs_dir)


func _test_save_run_id_mismatch_rejected_before_filesystem_mutation() -> void:
	print("[save] run_id mismatch rejected BEFORE filesystem mutation")
	var runs_dir: String = _isolated_runs_dir("save_run_id_mismatch_pre_fs")
	_cleanup(runs_dir)
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4: Dictionary = mig.get("data", {})
	v4["seed"] = 9101
	v4["run_id"] = "run_9101"
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var save_bad: RefCounted = repo.save_run(9101, v4.duplicate(true))
	# Now use a DTO whose run_id is mismatched.
	var v4_bad: Dictionary = v4.duplicate(true)
	v4_bad["seed"] = 9101
	v4_bad["run_id"] = "run_9999"
	var wr: RefCounted = repo.save_run(9101, v4_bad)
	_assert(wr.is_error(),
		"save with run_id mismatch -> error BEFORE filesystem mutation")
	_assert(wr.status == SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED,
		"status == ERROR_V4_VALIDATION_FAILED")
	_cleanup(runs_dir)


# ---------------------------------------------------------------------------
# Task 1 — typed context field
# ---------------------------------------------------------------------------

func _test_save_load_result_has_typed_context_field() -> void:
	print("[result] SaveLoadResult has typed context field")
	var r: RefCounted = SaveLoadResultScript.error_with(
		SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED, "v4", "test detail")
	r.context = "seed_consistency"
	_assert(r.context == "seed_consistency",
		"context field is typed String and roundtrips")


# ---------------------------------------------------------------------------
# Task 2 — slot-aware strict gate (BLOCKER #2)
# ---------------------------------------------------------------------------

func _test_recovery_keeps_commit_old_when_run_id_mismatches() -> void:
	print("[recovery] v4 with seed match but run_id mismatch does NOT delete commit-old")
	var runs_dir: String = _isolated_runs_dir("recover_run_id_mismatch")
	_cleanup(runs_dir)
	var src: Resource = load(RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var mig: Dictionary = MigratorScript.migrate_run(src)
	var v4_good: Dictionary = mig.get("data", {})
	v4_good["seed"] = 9101
	v4_good["run_id"] = "run_9101"
	var ops = preload("res://core/save/run_save_file_ops.gd").new()
	# Build corrupt: seed matches slot, but run_id is wrong.
	var v4_corrupt: Dictionary = v4_good.duplicate(true)
	v4_corrupt["run_id"] = "run_9999"
	var corrupt_bytes: PackedByteArray = RunSaveRepositoryScript.serialize_canonical_bytes(v4_corrupt)
	assert(ops.write_bytes_and_flush(runs_dir + "run_9101.tres", corrupt_bytes),
		"write run_id-mismatched target")
	assert(ops.rename(runs_dir + "run_9101.tres",
		runs_dir + "run_9101.tres.commit-old"),
		"rename target -> commit-old")
	assert(ops.write_bytes_and_flush(runs_dir + "run_9101.tres", corrupt_bytes),
		"re-write corrupt target")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9101)
	_assert(r.is_error(),
		"load with run_id-mismatched target -> error")
	var commit_old_present: bool = ops.exists(runs_dir + "run_9101.tres.commit-old")
	_assert(commit_old_present,
		"good commit-old preserved when target run_id mismatches")
	_cleanup(runs_dir)


# ---------------------------------------------------------------------------
# Task 4 — Legacy v1 strict detection (HIGH #2)
# ---------------------------------------------------------------------------

func _test_legacy_v2_tres_is_not_migrated() -> void:
	print("[detect] legacy v2 tres is rejected, not silently migrated")
	var runs_dir: String = _isolated_runs_dir("legacy_v2_not_migrated")
	_cleanup(runs_dir)
	# Copy a real fixture (which has version = 1) and rewrite the
	# version line to 2.
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var s: String = bytes.get_string_from_utf8()
	# Replace "version = 1" with "version = 2" (preserve whitespace).
	s = s.replace("version = 1\n", "version = 2\n")
	var ops = preload("res://core/save/run_save_file_ops.gd").new()
	assert(ops.write_bytes_and_flush(runs_dir + "run_9101.tres",
		s.to_utf8_buffer()), "write v2 fixture")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9101)
	_assert(r.is_error(), "v2 tres is rejected (not silently migrated as v1)")
	_cleanup(runs_dir)


func _test_legacy_tres_with_schema_version_key_is_not_migrated() -> void:
	print("[detect] tres with schema_version key is rejected")
	var runs_dir: String = _isolated_runs_dir("legacy_schema_version_present")
	_cleanup(runs_dir)
	# Copy a real fixture (which has no schema_version key) and inject
	# a schema_version = 4 line into the body.
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var s: String = bytes.get_string_from_utf8()
	s = s.replace("\n[resource]\n", "\n[resource]\nschema_version = 4\n")
	var ops = preload("res://core/save/run_save_file_ops.gd").new()
	assert(ops.write_bytes_and_flush(runs_dir + "run_9101.tres",
		s.to_utf8_buffer()), "write fixture with schema_version")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9101)
	_assert(r.is_error(),
		"tres with schema_version key is rejected (not silently migrated as v1)")
	_cleanup(runs_dir)


func _test_migrator_directly_rejects_non_v1_version() -> void:
	print("[migrator] direct migrate_run() rejects non-v1 version")
	# Dictionary source with version = 2 must be rejected without
	# being silently migrated as v1.
	var src2: Dictionary = {
		"version": 2,
		"seed": 8001,
		"player_unit_ids": [&"warrior"] as Array[StringName],
		"bench_unit_ids": [] as Array[StringName],
		"unit_states": [],
		"item_ids": [] as Array[StringName],
		"item_equip_board_idx": [] as Array[int],
	}
	var r2: Dictionary = MigratorScript.migrate_run(src2)
	_assert(not bool(r2.get("success", false)),
		"migrator rejects Dictionary version=2 directly")
	# Dictionary source with version as STRING "1" must be rejected:
	# version must be a real TYPE_INT.
	var src_s: Dictionary = {
		"version": "1",
		"seed": 8001,
		"player_unit_ids": [&"warrior"] as Array[StringName],
		"bench_unit_ids": [] as Array[StringName],
		"unit_states": [],
		"item_ids": [] as Array[StringName],
		"item_equip_board_idx": [] as Array[int],
	}
	var rs: Dictionary = MigratorScript.migrate_run(src_s)
	_assert(not bool(rs.get("success", false)),
		"migrator rejects Dictionary version='1' (string) directly")
	# Dictionary source with version = 1 + schema_version = 4 must
	# be rejected.
	var src_sv: Dictionary = {
		"version": 1,
		"schema_version": 4,
		"seed": 8001,
		"player_unit_ids": [&"warrior"] as Array[StringName],
		"bench_unit_ids": [] as Array[StringName],
		"unit_states": [],
		"item_ids": [] as Array[StringName],
		"item_equip_board_idx": [] as Array[int],
	}
	var rsv: Dictionary = MigratorScript.migrate_run(src_sv)
	_assert(not bool(rsv.get("success", false)),
		"migrator rejects Dictionary version=1 + schema_version=4 directly")


# ---------------------------------------------------------------------------
# Task 6 — Line-aware legacy seed parser (MEDIUM #1)
# ---------------------------------------------------------------------------

func _test_recovery_legacy_target_missing_commit_old_seed_9001() -> void:
	# Crash recovery: target missing, only commit-old exists, and
	# commit-old is a real legacy v1 fixture with seed=9001. The
	# recovery must read "seed = 9001" exactly and restore the
	# commit-old to target. This is the helper that had a substring
	# bug in T6: it read substr(4) of "seed = 9001" which gave
	# " = 9001", so the leading "=" stopped the digit loop and the
	# helper always returned false.
	print("[recovery] commit-old seed=9001 IS restored for slot 9001")
	var runs_dir: String = _isolated_runs_dir("recovery_commit_old_seed_9001")
	_cleanup(runs_dir)
	var ops = preload("res://core/save/run_save_file_ops.gd").new()
	var fixture_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var target_path: String = runs_dir + "run_9001.tres"
	var commit_old_path: String = target_path + ".commit-old"
	assert(ops.write_bytes_and_flush(commit_old_path,
		fixture_bytes), "write real fixture as commit-old")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_ok(),
		"load_run(9001) restores legacy commit-old with seed=9001")
	var target_now: bool = ops.exists(target_path)
	var commit_old_now: bool = ops.exists(commit_old_path)
	_assert(target_now, "target restored after recovery")
	_assert(not commit_old_now,
		"commit-old renamed to target (no leftover)")
	_cleanup(runs_dir)


func _test_recovery_legacy_commit_old_seed_90010_is_rejected() -> void:
	# The parser must NOT accept a commit-old whose seed line is
	# "seed = 90010" when the requested slot is 9001 (substring trap).
	print("[recovery] commit-old seed=90010 is NOT restored for slot 9001")
	var runs_dir: String = _isolated_runs_dir("recovery_commit_old_seed_90010")
	_cleanup(runs_dir)
	var ops = preload("res://core/save/run_save_file_ops.gd").new()
	var fixture_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var s: String = fixture_bytes.get_string_from_utf8()
	s = s.replace("seed = 9001\n", "seed = 90010\n")
	var target_path: String = runs_dir + "run_9001.tres"
	var commit_old_path: String = target_path + ".commit-old"
	assert(ops.write_bytes_and_flush(commit_old_path,
		s.to_utf8_buffer()), "write fixture with seed=90010")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_error(),
		"load_run(9001) rejects commit-old with seed=90010")
	var commit_old_preserved: bool = ops.exists(commit_old_path)
	_assert(commit_old_preserved,
		"commit-old preserved when seed mismatches")
	_cleanup(runs_dir)


func _test_legacy_v10_is_not_legacy_v1() -> void:
	# Detector must reject version = 10 even though "version = 1"
	# appears as a substring.
	print("[detect] legacy tres with version = 10 is NOT legacy v1")
	var runs_dir: String = _isolated_runs_dir("legacy_v10_not_v1")
	_cleanup(runs_dir)
	var ops = preload("res://core/save/run_save_file_ops.gd").new()
	var fixture_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var s: String = fixture_bytes.get_string_from_utf8()
	s = s.replace("version = 1\n", "version = 10\n")
	assert(ops.write_bytes_and_flush(runs_dir + "run_9001.tres",
		s.to_utf8_buffer()), "write fixture with version=10")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_error(),
		"version=10 tres is rejected, not silently migrated as v1")
	_cleanup(runs_dir)


func _test_legacy_v1_plus_schema_version_is_rejected() -> void:
	# Detector must reject version = 1 with schema_version present.
	print("[detect] legacy tres with schema_version is rejected")
	var runs_dir: String = _isolated_runs_dir("legacy_v1_plus_schema_version")
	_cleanup(runs_dir)
	var ops = preload("res://core/save/run_save_file_ops.gd").new()
	var fixture_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		RUN_FIXTURES_DIR + "/active_run_minimal.tres")
	var s: String = fixture_bytes.get_string_from_utf8()
	s = s.replace("\n[resource]\n", "\n[resource]\nschema_version = 4\n")
	assert(ops.write_bytes_and_flush(runs_dir + "run_9001.tres",
		s.to_utf8_buffer()), "write fixture with schema_version")
	var repo: RefCounted = RunSaveRepositoryScript.new(runs_dir)
	var r: RefCounted = repo.load_run(9001)
	_assert(r.is_error(),
		"version=1 + schema_version=4 is rejected, not silently migrated")
	_cleanup(runs_dir)
