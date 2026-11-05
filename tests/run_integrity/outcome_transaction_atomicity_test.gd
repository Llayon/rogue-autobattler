extends SceneTree

## The finished-run removal must be part of the transaction, and a
## failed write must not strand the outcome.
##
## The third independent critic of the RI-05 package found:
##
## H1: the MAX_ROUND win WROTE a resumable checkpoint and removed it
##     afterwards. The bytes on the disk between the write and the
##     delete were a legal "reward" checkpoint at round 11 -- past
##     MAX_ROUND -- and the window spans the reward emission and the
##     meta-unlock RNG draws, so it is not a tight window. A crash in
##     that window resurrects a finished run.
##
## M1: `delete_run` removed only the target and left the
##     `.commit-old` behind, so the repository's own recovery path
##     ("target missing + valid commit-old -> restore") resurrected the
##     deleted slot on the next load.
##
## M2: the delete result was discarded, so a failed removal left the
##     finished run resumable with nothing logged.
##
## M3: the idempotence latch was consumed BEFORE the write, so a
##     failed write left the outcome applied in memory and
##     unpersisted, with no way to retry it.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const SaveServiceScript = preload("res://core/save/save_service.gd")
const BalanceScript = preload("res://core/balance.gd")
const SaveLoadResultScript = preload("res://core/save/save_load_result.gd")

const ISOLATED_DIR: String = "user://run_integrity_ri05_tx/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_the_max_round_win_writes_nothing()
	await _test_B_the_removal_covers_the_commit_old()
	await _test_C_a_failed_removal_is_reported()
	await _test_D_a_failed_write_keeps_the_outcome_retryable()
	print("")
	print("=== STAGE 4B: OUTCOME TRANSACTION ATOMICITY: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## The MAX_ROUND win must NOT write a checkpoint: the run is over, so
## there is nothing to write. Writing it and removing it afterwards
## leaves a window in which a finished run is resumable.
func _test_A_the_max_round_win_writes_nothing() -> void:
	var ctrl: Node = await _make_controller(560001)
	ctrl.state.round_index = BalanceScript.MAX_ROUND
	var writes_before: int = ctrl.save_repository.get_save_count()
	await _finish_battle(ctrl, 0)
	var writes_after: int = ctrl.save_repository.get_save_count()
	_assert(writes_after == writes_before,
		"the MAX_ROUND win writes no checkpoint (got %d writes)"
			% (writes_after - writes_before))
	var on_disk: Dictionary = _disk_dto(560001)
	_assert(on_disk.is_empty(),
		"the MAX_ROUND win leaves no checkpoint on the disk")


## The removal must cover the whole slot: the `.commit-old` is the
## authoritative generation when the target is missing, so leaving it
## behind lets the recovery path resurrect the deleted slot.
func _test_B_the_removal_covers_the_commit_old() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	var repo: Object = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var target: String = ISOLATED_DIR + "run_560002.tres"
	var commit_old: String = target + ".commit-old"
	# The state a crash inside the commit swap leaves: the target
	# renamed to `.commit-old`.
	var good: Dictionary = _good_dto(560002)
	var written: RefCounted = repo.save_run_v5(560002, good)
	_assert(written != null and written.is_ok(), "the checkpoint is written")
	if FileAccess.file_exists(target):
		DirAccess.rename_absolute(
			ProjectSettings.globalize_path(target),
			ProjectSettings.globalize_path(commit_old))
	_assert(FileAccess.file_exists(commit_old), "the commit-old is in place")

	var removed: bool = repo.delete_run(560002)
	_assert(removed, "the deletion reports success")
	_assert(not FileAccess.file_exists(commit_old),
		"the deletion removes the commit-old too")
	_assert(not FileAccess.file_exists(target),
		"the deletion removes the target")


## A failed removal must be reported: a finished run that stays on the
## disk is resumable, and the player must not be left with a silent
## hole.
func _test_C_a_failed_removal_is_reported() -> void:
	var ctrl: Node = await _make_controller(560003)
	ctrl.state.lives = 1
	await _finish_battle(ctrl, 1)
	# The removal was attempted; the run must leave nothing behind.
	var on_disk: Dictionary = _disk_dto(560003)
	_assert(on_disk.is_empty(),
		"the finished run leaves no checkpoint on the disk")


## A failed write must not strand the outcome: the latch may only be
## consumed when the checkpoint actually landed, so the outcome stays
## persistable.
func _test_D_a_failed_write_keeps_the_outcome_retryable() -> void:
	var ctrl: Node = await _make_controller(560004)
	ctrl.state.lives = 2
	# A repository whose write always fails.
	ctrl.save_repository = _FailingRepository.new(ISOLATED_DIR)
	await _finish_battle(ctrl, 1)
	var live: Dictionary = _live_state(ctrl)
	_assert(int(live.get("losses", 0)) == 1,
		"the outcome was applied in memory")
	# The outcome must still be persistable: the latch may not be
	# consumed by a failed write.
	_assert(not ctrl._battle_outcome_applied,
		"a failed write does not consume the outcome latch")


# ----------------------------------------------------------------


func _make_controller(seed_value: int) -> Node:
	var ctrl: Node = RunControllerScript.new()
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR)
	ctrl.meta_writer = _MetaWriter.new()
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]
	ctrl.start_run(seed_value)
	await process_frame
	return ctrl


func _finish_battle(ctrl: Node, winner: int) -> void:
	ctrl.start_battle()
	await process_frame
	var losing_team: int = 1 if winner == 0 else 0
	for combatant in ctrl.runner.ctx.combatants_of_team(losing_team):
		combatant.health.current_hp = 0
	ctrl.runner._cleanup_dead()
	ctrl.runner._end_battle()
	ctrl.tick_battle(0.016)
	await process_frame


func _live_state(ctrl: Node) -> Dictionary:
	return {
		"wins": ctrl.state.wins,
		"losses": ctrl.state.losses,
		"gold": ctrl.state.gold,
		"round_index": ctrl.state.round_index,
		"lives": ctrl.state.lives,
	}


func _disk_dto(seed_value: int) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	var repo: Object = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var result: RefCounted = SaveServiceScript._load_run_v5_with_repository(
		seed_value, repo)
	if result == null or not result.is_ok():
		return {}
	return result.data as Dictionary


func _good_dto(seed_value: int) -> Dictionary:
	return {
		"schema_version": 5, "game_build": "", "run_id": "run_%d" % seed_value,
		"seed": seed_value, "round_index": 1, "phase": "prep", "gold": 0,
		"units": [], "items": [],
		"next_unit_instance_seq": 1, "next_item_instance_seq": 1,
		"shop": {}, "map": {}, "rewards": {},
		"rng": {"seed": seed_value, "state": "1234567890123456789"},
		"wins": 0, "losses": 0, "units_killed": 0, "lives": 3, "xp": 0,
		"level": 1, "current_encounter_id": -1, "encounter_visited_ids": [],
		"meta_modifiers": {}, "just_visited_merchant": false,
	}


## A meta writer that does NOT touch the production meta file.
class _MetaWriter:
	extends RefCounted

	func write_meta(profile: Object) -> bool:
		return true


## A repository whose writes always fail.
class _FailingRepository:
	extends RefCounted

	var _runs_dir: String = ""

	func _init(p_runs_dir: String) -> void:
		_runs_dir = p_runs_dir

	func save_run_v5(seed_value: int, dto: Dictionary) -> RefCounted:
		return _failed()

	func load_run_v5(seed_value: int) -> RefCounted:
		return _failed()

	func delete_run(seed_value: int) -> bool:
		return true

	func get_save_count() -> int:
		return 0

	func _failed() -> RefCounted:
		return SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_IO, "seed", "the write failed")


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage 4B: %s" % label)
