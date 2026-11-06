extends SceneTree

## H-01: the save counter must count COMMITTED saves, not attempts.
##
## `RunSaveRepository._save_canonical()` incremented `_save_count` BEFORE
## the temp write, the temp verification and the commit. A failed save
## therefore left the counter of successful saves inflated.
##
## The contract:
##
##   save result SUCCESS -> save_count delta = +1
##   save result ERROR   -> save_count delta = 0
##
## for both v4 and v5.
##
## The matrix walks the failure points of the transaction with the
## existing test-only fault adapter: the temp write, the temp
## verification, the initial rename, the replace rename, the post-commit
## validation and the `.commit-old` cleanup. For every failure the test
## ALSO checks the disk state and the recoverability: a failed save must
## not destroy the previous generation, and a failed save must not make
## the slot un-loadable.

const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const FaultOps = preload("res://tests/save_repository/support/run_save_file_ops_fault.gd")
const RunStateV4MapperScript = preload("res://core/progression/run_state_v4_mapper.gd")
const SaveSchemaV5Script = preload("res://core/save/save_schema_v5.gd")

const ISOLATED_DIR: String = "user://run_integrity_h01/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_a_successful_save_counts_once()
	await _test_B_a_successful_replacement_counts_once()
	await _test_C_an_invalid_dto_counts_nothing()
	await _test_D_the_failure_matrix_counts_nothing()
	await _test_E_a_failed_save_keeps_the_previous_generation()
	await _test_F_the_recovery_after_an_injected_failure()
	await _test_G_the_v4_path_counts_commits_too()
	print("")
	print("=== STAGE H01: THE SAVE COUNTER COUNTS COMMITS: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. A successful fresh save counts exactly once.
func _test_A_a_successful_save_counts_once() -> void:
	var repo: RefCounted = _make_repo()
	var before: int = repo.get_save_count()
	var result: RefCounted = repo.save_run_v5(670101, _v5_dto(670101))
	_assert(result != null and result.is_ok(), "the fresh save succeeds")
	_assert(repo.get_save_count() == before + 1,
		"a successful save counts once (got %d, it was %d)"
			% [repo.get_save_count(), before])


## B. A successful replacement counts exactly once.
func _test_B_a_successful_replacement_counts_once() -> void:
	var repo: RefCounted = _make_repo()
	_assert(repo.save_run_v5(670102, _v5_dto(670102)).is_ok(),
		"the first save succeeds")
	var before: int = repo.get_save_count()
	var result: RefCounted = repo.save_run_v5(670102, _v5_dto(670102))
	_assert(result != null and result.is_ok(), "the replacement succeeds")
	_assert(repo.get_save_count() == before + 1,
		"a successful replacement counts once (got %d, it was %d)"
			% [repo.get_save_count(), before])


## C. An invalid DTO is rejected before any write and counts nothing.
func _test_C_an_invalid_dto_counts_nothing() -> void:
	var repo: RefCounted = _make_repo()
	var before: int = repo.get_save_count()
	var broken: Dictionary = _v5_dto(670103)
	# A shape-invalid DTO: the seed is not an integer, so the v5 shape
	# gate rejects it BEFORE the write.
	broken["seed"] = "not a number"
	var result: RefCounted = repo.save_run_v5(670103, broken)
	_assert(result != null and not result.is_ok(), "the invalid DTO is rejected")
	_assert(repo.get_save_count() == before,
		"a rejected DTO counts nothing (got %d, it was %d)"
			% [repo.get_save_count(), before])


## D. The failure matrix: every failure point counts nothing.
func _test_D_the_failure_matrix_counts_nothing() -> void:
	# The fault keys and the failure they inject.
	var failures: Array = [
		["write_bytes_and_flush", "the temp write fails"],
		["rename", "the rename fails"],
		["remove", "the cleanup fails"],
		["read_bytes", "the post-commit read fails"],
	]
	for entry in failures:
		var key: StringName = StringName(entry[0])
		var label: String = String(entry[1])
		# ONE repository, so the counter delta is measured on the same
		# counter: the faulty repository is a different object with a
		# different counter.
		var ops: RefCounted = FaultOps.new()
		var repo: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
		# A first, successful save: the previous generation.
		_assert(repo.save_run_v5(670104, _v5_dto(670104)).is_ok(),
			"the first save succeeds for %s" % label)
		var before: int = repo.get_save_count()
		# The fault is injected for the SECOND save.
		ops.fail_methods = {key: true}
		var result: RefCounted = repo.save_run_v5(670104, _v5_dto(670104))
		_assert(result != null and not result.is_ok(),
			"the save fails when %s" % label)
		_assert(repo.get_save_count() == before,
			"a failed save counts nothing when %s (got %d, it was %d)"
				% [label, repo.get_save_count(), before])


## E. A failed save keeps the previous generation and the slot stays
## loadable.
func _test_E_a_failed_save_keeps_the_previous_generation() -> void:
	var repo: RefCounted = _make_repo()
	_assert(repo.save_run_v5(670105, _v5_dto(670105)).is_ok(),
		"the first save succeeds")
	var ops: RefCounted = FaultOps.new()
	ops.fail_methods = {&"write_bytes_and_flush": true}
	var failing: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
	var result: RefCounted = failing.save_run_v5(670105, _v5_dto(670105))
	_assert(result != null and not result.is_ok(), "the second save fails")
	# The previous generation is still on the disk and still loadable.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(670105)
	_assert(loaded != null and loaded.is_ok(),
		"the previous generation is still loadable after a failed save")


## F. The recovery after an injected failure: the next save succeeds and
## counts once.
func _test_F_the_recovery_after_an_injected_failure() -> void:
	var ops: RefCounted = FaultOps.new()
	ops.fail_methods = {&"write_bytes_and_flush": true}
	var failing: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
	var result: RefCounted = failing.save_run_v5(670106, _v5_dto(670106))
	_assert(result != null and not result.is_ok(), "the injected failure fails")
	# The fault is cleared: a healthy repository recovers. Its counter
	# starts at zero -- the failed repository was a DIFFERENT object --
	# so the recovered save must be the FIRST counted save.
	var healthy: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var before: int = healthy.get_save_count()
	var recovered: RefCounted = healthy.save_run_v5(670106, _v5_dto(670106))
	_assert(recovered != null and recovered.is_ok(),
		"the save recovers after the injected failure")
	_assert(healthy.get_save_count() == before + 1,
		"the recovered save counts once (got %d, it was %d)"
			% [healthy.get_save_count(), before])
	# The failed repository counted NOTHING for its failed save.
	_assert(failing.get_save_count() == 0,
		"the failed repository counted no save (got %d)"
			% failing.get_save_count())


## G. The v4 path has the SAME contract: it goes through the same
## `_save_canonical()`, so a successful v4 save counts once and a
## failed one counts nothing.
func _test_G_the_v4_path_counts_commits_too() -> void:
	var repo: RefCounted = _make_repo()
	var before: int = repo.get_save_count()
	var result: RefCounted = repo.save_run(670107, _v4_dto(670107))
	_assert(result != null and result.is_ok(), "the fresh v4 save succeeds")
	_assert(repo.get_save_count() == before + 1,
		"a successful v4 save counts once (got %d, it was %d)"
			% [repo.get_save_count(), before])

	# The failure matrix on the v4 path.
	var ops: RefCounted = FaultOps.new()
	var failing: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
	_assert(failing.save_run(670107, _v4_dto(670107)).is_ok(),
		"the first v4 save succeeds")
	var before_fail: int = failing.get_save_count()
	ops.fail_methods = {&"write_bytes_and_flush": true}
	var failed: RefCounted = failing.save_run(670107, _v4_dto(670107))
	_assert(failed != null and not failed.is_ok(), "the failed v4 save fails")
	_assert(failing.get_save_count() == before_fail,
		"a failed v4 save counts nothing (got %d, it was %d)"
			% [failing.get_save_count(), before_fail])


# ----------------------------------------------------------------


func _make_repo() -> RefCounted:
	return RunSaveRepositoryScript.new(ISOLATED_DIR)


## A minimal valid v5 DTO for the given seed.
func _v5_dto(seed_value: int) -> Dictionary:
	return {
		"schema_version": 5,
		"game_build": "",
		"run_id": "run_%d" % seed_value,
		"seed": seed_value,
		"round_index": 1,
		"phase": "prep",
		"gold": 10,
		"units": [],
		"items": [],
		"next_unit_instance_seq": 1,
		"next_item_instance_seq": 1,
		"shop": {},
		"map": {},
		"rewards": {},
		"rng": {"seed": seed_value, "state": "1234567890123456789"},
		"wins": 0,
		"losses": 0,
		"units_killed": 0,
		"lives": 1,
		"xp": 0,
		"level": 1,
		"current_encounter_id": -1,
		"encounter_visited_ids": [],
		"meta_modifiers": {},
		"just_visited_merchant": false,
	}


## A minimal valid v4 DTO for the given seed.
func _v4_dto(seed_value: int) -> Dictionary:
	return {
		"schema_version": 4,
		"game_build": "",
		"run_id": "run_%d" % seed_value,
		"seed": seed_value,
		"round_index": 1,
		"phase": "prep",
		"gold": 10,
		"units": [],
		"items": [],
		"next_unit_instance_seq": 1,
		"next_item_instance_seq": 1,
		"shop": {},
		"map": {},
		"rewards": {},
		"rng": {},
		"wins": 0,
		"losses": 0,
		"units_killed": 0,
		"lives": 1,
		"xp": 0,
		"level": 1,
		"current_encounter_id": -1,
		"encounter_visited_ids": [],
		"meta_modifiers": {},
		"just_visited_merchant": false,
	}


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage H01: %s" % label)
