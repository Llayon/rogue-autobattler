extends SceneTree

## H-05: a failed OUTCOME write needs a safe, REACHABLE retry.
##
## The baseline:
##
##   battle finished
##     -> the outcome was applied to the live state
##     -> the write failed
##     -> the latch stayed false
##
## The normal tick cannot retry it: `tick_battle` only calls
## `_on_battle_ended()` while the runner is ENDED, and the first
## application moved the runner to APPLIED. So the outcome is lost.
##
## The obvious manual retry -- calling `_on_battle_ended()` again --
## is NOT safe: it re-applies the win counter, the gold, the round
## advance, the combat drop and the reward offer.
##
## The contract:
##
##   OUTCOME_NOT_APPLIED
##   OUTCOME_APPLIED_PENDING_PERSIST
##   OUTCOME_PERSISTED
##
## A retry MUST preserve the ALREADY applied result. The retry may
## NOT:
##   - repeat the win/loss counters;
##   - repeat the gold/lives mutation;
##   - advance the round index again;
##   - throw the loot again;
##   - regenerate the reward offer;
##   - make new gameplay RNG draws;
##   - re-emit the outcome gameplay events.
##
## The retry path must be REACHABLE -- not a dead method without a
## caller -- and it must not write on every frame.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const FaultOps = preload("res://tests/save_repository/support/run_save_file_ops_fault.gd")
const RngServiceScript = preload("res://core/utils/rng_service.gd")

const ISOLATED_DIR: String = "user://run_integrity_h05/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	# The API presence is checked FIRST: a missing method must produce
	# a `[FAIL]`, not a SCRIPT ERROR that aborts the suite.
	_assert(_has_method(RunControllerScript, "retry_outcome_persistence"),
		"the controller has the reachable outcome retry")
	_assert(_has_method(RunControllerScript, "outcome_persistence_pending"),
		"the controller reports the pending persistence state")
	if _failed > 0:
		print("")
		print("=== STAGE H05: THE OUTCOME RETRY IS EXACTLY ONCE: %d pass / %d fail ==="
			% [_passed, _failed])
		quit(1)
		return
	await _test_A_a_failed_outcome_write_is_retryable()
	await _test_B_the_retry_preserves_the_applied_outcome()
	await _test_C_the_retry_makes_no_extra_gameplay_rng_draw()
	await _test_D_the_retry_does_not_regenerate_the_reward_offer()
	await _test_E_a_successful_outcome_is_not_retryable()
	await _test_F_the_retry_is_reachable_from_the_tick()
	print("")
	print("=== STAGE H05: THE OUTCOME RETRY IS EXACTLY ONCE: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. A failed outcome write leaves the outcome PENDING, not lost.
func _test_A_a_failed_outcome_write_is_retryable() -> void:
	var ctrl: Node = await _make_controller(670601, true)
	ctrl._enter_map()
	await process_frame
	# A fight that is won.
	ctrl.start_battle()
	await process_frame
	_assert(ctrl.runner != null, "the battle started")
	if ctrl.runner == null:
		return
	ctrl.runner.state.winner_team = 0
	ctrl.runner.state.phase = 6
	# The write fails.
	var ops: RefCounted = FaultOps.new()
	ops.fail_methods = {&"write_bytes_and_flush": true}
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
	ctrl._on_battle_ended()
	await process_frame
	_assert(bool(ctrl.outcome_persistence_pending()),
		"the failed outcome write is PENDING")
	_assert(ctrl.state.wins == 1, "the outcome was applied once")
	_assert(int(ctrl.state.round_index) == 2, "the round advanced once")


## B. The retry persists the ALREADY applied outcome and does not
## re-apply it.
func _test_B_the_retry_preserves_the_applied_outcome() -> void:
	var ctrl: Node = await _make_controller(670602, true)
	ctrl._enter_map()
	await process_frame
	ctrl.start_battle()
	await process_frame
	if ctrl.runner == null:
		return
	ctrl.runner.state.winner_team = 0
	ctrl.runner.state.phase = 6
	var ops: RefCounted = FaultOps.new()
	ops.fail_methods = {&"write_bytes_and_flush": true}
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
	ctrl._on_battle_ended()
	await process_frame

	# The state after the failed write.
	var wins: int = ctrl.state.wins
	var gold: int = ctrl.state.gold
	var round_index: int = ctrl.state.round_index
	var losses: int = ctrl.state.losses
	var lives: int = ctrl.state.lives
	var items_before: int = ctrl.state.items.size()

	# The write is recovered.
	ops.fail_methods = {}
	var ok: bool = ctrl.retry_outcome_persistence()
	_assert(ok, "the retry succeeds")
	_assert(ctrl.state.wins == wins, "the retry did not repeat the win")
	_assert(ctrl.state.gold == gold, "the retry did not repeat the gold")
	_assert(ctrl.state.round_index == round_index,
		"the retry did not advance the round")
	_assert(ctrl.state.losses == losses, "the retry did not repeat the loss")
	_assert(ctrl.state.lives == lives, "the retry did not repeat the life")
	_assert(ctrl.state.items.size() == items_before,
		"the retry did not throw the loot again")
	_assert(not bool(ctrl.outcome_persistence_pending()),
		"the retry cleared the pending state")

	# The checkpoint now holds the outcome.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(670602)
	_assert(loaded != null and loaded.is_ok(),
		"the checkpoint landed after the retry")
	if loaded != null and loaded.is_ok():
		var dto: Dictionary = loaded.data
		_assert(int(dto.get("wins", 0)) == wins,
			"the checkpoint carries the win counter")
		_assert(int(dto.get("round_index", 0)) == round_index,
			"the checkpoint carries the round")


## C. The retry makes NO extra gameplay RNG draw.
func _test_C_the_retry_makes_no_extra_gameplay_rng_draw() -> void:
	var ctrl: Node = await _make_controller(670603, true)
	ctrl._enter_map()
	await process_frame
	ctrl.start_battle()
	await process_frame
	if ctrl.runner == null:
		return
	ctrl.runner.state.winner_team = 0
	ctrl.runner.state.phase = 6
	var ops: RefCounted = FaultOps.new()
	ops.fail_methods = {&"write_bytes_and_flush": true}
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
	ctrl._on_battle_ended()
	await process_frame

	# The stream before the retry.
	var before: Dictionary = RngServiceScript.snapshot()
	ops.fail_methods = {}
	ctrl.retry_outcome_persistence()
	var after: Dictionary = RngServiceScript.snapshot()
	_assert(int(after.get("state", 0)) == int(before.get("state", 0)),
		"the retry made no gameplay RNG draw")


## D. The retry does not regenerate the reward offer.
func _test_D_the_retry_does_not_regenerate_the_reward_offer() -> void:
	var ctrl: Node = await _make_controller(670604, true)
	ctrl._enter_map()
	await process_frame
	ctrl.start_battle()
	await process_frame
	if ctrl.runner == null:
		return
	ctrl.runner.state.winner_team = 0
	ctrl.runner.state.phase = 6
	var ops: RefCounted = FaultOps.new()
	ops.fail_methods = {&"write_bytes_and_flush": true}
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
	ctrl._on_battle_ended()
	await process_frame
	# The offer of the FIRST application.
	var offer_before: Array = ctrl.reward.offered_ids()
	ops.fail_methods = {}
	ctrl.retry_outcome_persistence()
	var offer_after: Array = ctrl.reward.offered_ids()
	_assert(offer_after.size() == offer_before.size(),
		"the retry did not change the offer size")
	for i in range(mini(offer_before.size(), offer_after.size())):
		_assert(str(offer_after[i]) == str(offer_before[i]),
			"the retry did not change the offer entry %d" % i)


## E. A successful outcome is NOT retryable: the retry must not write
## a second checkpoint.
func _test_E_a_successful_outcome_is_not_retryable() -> void:
	var ctrl: Node = await _make_controller(670605, true)
	ctrl._enter_map()
	await process_frame
	ctrl.start_battle()
	await process_frame
	if ctrl.runner == null:
		return
	ctrl.runner.state.winner_team = 0
	ctrl.runner.state.phase = 6
	ctrl._on_battle_ended()
	await process_frame
	_assert(not bool(ctrl.outcome_persistence_pending()),
		"the successful outcome is not pending")
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var count_before: int = reader.get_save_count()
	var ok: bool = ctrl.retry_outcome_persistence()
	_assert(not ok, "the retry of a persisted outcome reports no work")
	_assert(reader.get_save_count() == count_before,
		"the retry of a persisted outcome wrote nothing")


## F. The retry is REACHABLE from the normal tick: the controller
## retries the pending persistence without a manual call, and it does
## not write on every frame.
func _test_F_the_retry_is_reachable_from_the_tick() -> void:
	var ctrl: Node = await _make_controller(670606, true)
	ctrl._enter_map()
	await process_frame
	ctrl.start_battle()
	await process_frame
	if ctrl.runner == null:
		return
	ctrl.runner.state.winner_team = 0
	ctrl.runner.state.phase = 6
	var ops: RefCounted = FaultOps.new()
	ops.fail_methods = {&"write_bytes_and_flush": true}
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
	ctrl._on_battle_ended()
	await process_frame
	_assert(bool(ctrl.outcome_persistence_pending()),
		"the failed outcome write is PENDING")

	# The write is recovered, and the ORDINARY tick retries it.
	ops.fail_methods = {}
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var count_before: int = reader.get_save_count()
	ctrl.tick_battle(0.016)
	await process_frame
	_assert(not bool(ctrl.outcome_persistence_pending()),
		"the ordinary tick cleared the pending state")
	_assert(reader.get_save_count() == count_before + 1,
		"the ordinary tick wrote the checkpoint exactly once (it was %d, it is %d)"
			% [reader.get_save_count(), count_before])


# ----------------------------------------------------------------


func _has_method(script: Object, method_name: String) -> bool:
	for m in script.get_script_method_list():
		if str(m.get("name", "")) == method_name:
			return true
	return false


func _make_controller(seed_value: int, meta_ok: bool) -> Node:
	var ctrl: Node = RunControllerScript.new()
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR)
	ctrl.meta_writer = _MetaWriter.new()
	ctrl.meta_writer.fail = not meta_ok
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]
	ctrl.start_run(seed_value)
	await process_frame
	return ctrl


## A meta writer that does NOT touch the production meta file.
class _MetaWriter:
	extends RefCounted

	func write_meta(profile: Object) -> bool:
		return true


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage H05: %s" % label)
