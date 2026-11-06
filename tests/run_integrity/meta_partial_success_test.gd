extends SceneTree

## H-08: a checkpoint that COMMITTED with a META FAILURE is a PARTIAL
## SUCCESS, and the caller must be told so.
##
## The baseline:
##
##   profile.current_run_seed = state.seed
##   _save_meta(profile)   # the boolean is IGNORED
##   GameBus.emit_run_saved(state.seed)
##   return true
##
## So when the meta write fails, the checkpoint IS on the disk but the
## caller is told the save succeeded and `run_saved` is emitted. The
## pointer that makes Continue discoverable was not written, and the
## caller cannot tell.
##
## The contract:
##
##   checkpoint success + meta success -> complete success
##   checkpoint success + meta failure -> the checkpoint stays VALID,
##                                      the status reports a PARTIAL
##                                      failure, no false run_saved
##                                      success, and only the META
##                                      publication is retried
##   checkpoint failure               -> no claim of a persisted
##                                      checkpoint
##
## And the meta retry must NOT replay the gameplay outcome.
##
## The discovery path: when the meta pointer is stale or zero, the
## checkpoints that are on the disk must be DISCOVERABLE, so Continue
## can find the committed checkpoint. With more than one candidate the
## controller must NOT pick one silently.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const FaultOps = preload("res://tests/save_repository/support/run_save_file_ops_fault.gd")

const ISOLATED_DIR: String = "user://run_integrity_h08/"

var _passed: int = 0
var _failed: int = 0
var _bus: Node = null


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	# The signals are instance-level. The autoload is registered in
	# project.godot, so the suite uses it -- exactly like the legacy
	# suite does -- instead of creating a second bus with the same
	# name (which would NOT receive the controller's emissions).
	_bus = get_root().get_node_or_null("EventBus")
	_assert(_bus != null, "the EventBus autoload is present")
	if _bus == null:
		quit(1)
		return
	# The API contract is checked FIRST: a missing method must produce
	# a `[FAIL]`, not a SCRIPT ERROR that aborts the suite. A
	# trustworthy RED is a `[FAIL]` line with zero script errors.
	_assert(ctrl_has_method(RunControllerScript, "save_now_report"),
		"the controller has the structured save report")
	_assert(ctrl_has_method(RunControllerScript, "retry_meta_publication"),
		"the controller has the meta publication retry")
	_assert(ctrl_has_method(RunControllerScript, "recoverable_checkpoints"),
		"the controller has the checkpoint discovery path")
	if _failed > 0:
		print("")
		print("=== STAGE H08: THE META PARTIAL SUCCESS: %d pass / %d fail ==="
			% [_passed, _failed])
		quit(1)
		return
	await _test_A_a_complete_success_is_reported_as_success()
	await _test_B_a_checkpoint_failure_is_not_a_persisted_checkpoint()
	await _test_C_a_meta_failure_is_a_partial_success()
	await _test_D_a_meta_failure_does_not_emit_a_false_run_saved()
	await _test_E_the_meta_retry_does_not_replay_the_outcome()
	await _test_F_the_checkpoint_survives_a_meta_failure()
	await _test_G_the_committed_checkpoint_is_discoverable()
	await _test_H_two_checkpoints_are_not_resolved_silently()
	print("")
	print("=== STAGE H08: THE META PARTIAL SUCCESS: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. The complete success: the checkpoint and the meta both land.
func _test_A_a_complete_success_is_reported_as_success() -> void:
	var ctrl: Node = await _make_controller(670501, true)
	var saved: Array = []
	_bus.run_saved.connect(func(seed_value: int) -> void: saved.append(seed_value))
	var report: Object = ctrl.save_now_report()
	_assert(report != null, "the save reports a structured result")
	if report != null:
		_assert(bool(report.checkpoint_committed),
			"the complete success committed the checkpoint")
		_assert(bool(report.meta_committed),
			"the complete success committed the meta pointer")
		_assert(report.is_complete(), "the complete success is COMPLETE")
		_assert(not report.is_partial(),
			"the complete success is not PARTIAL")
	_assert(saved.size() == 1, "the complete success emits run_saved")
	_assert(ctrl.profile.current_run_seed == 670501,
		"the meta pointer was written")


## B. A checkpoint failure is NOT a persisted checkpoint.
func _test_B_a_checkpoint_failure_is_not_a_persisted_checkpoint() -> void:
	var ctrl: Node = await _make_controller(670502, true)
	# The repository fails every write.
	var ops: RefCounted = FaultOps.new()
	ops.fail_methods = {&"write_bytes_and_flush": true}
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
	var saved: Array = []
	_bus.run_saved.connect(func(seed_value: int) -> void: saved.append(seed_value))
	var report: Object = ctrl.save_now_report()
	_assert(report != null, "the failed save reports a structured result")
	if report != null:
		_assert(not bool(report.checkpoint_committed),
			"the failed save committed NO checkpoint")
		_assert(not report.is_complete(),
			"the failed save is not COMPLETE")
		_assert(not report.is_partial(),
			"the failed save is not PARTIAL -- nothing was committed")
	_assert(saved.is_empty(),
		"the checkpoint failure emits no run_saved (the emitted list is %s)"
			% str(saved))


## C. A checkpoint that committed with a meta failure is a PARTIAL
## success.
func _test_C_a_meta_failure_is_a_partial_success() -> void:
	var ctrl: Node = await _make_controller(670503, true)
	ctrl.meta_writer.fail = true
	var report: Object = ctrl.save_now_report()
	_assert(report != null, "the partial save reports a structured result")
	if report != null:
		_assert(bool(report.checkpoint_committed),
			"the partial success DID commit the checkpoint")
		_assert(not bool(report.meta_committed),
			"the partial success did NOT commit the meta pointer")
		_assert(report.is_partial(),
			"the partial success is PARTIAL")
		_assert(not report.is_complete(),
			"the partial success is not COMPLETE")
	# The CHECKPOINT is valid: it is on the disk.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(670503)
	_assert(loaded != null and loaded.is_ok(),
		"the checkpoint is valid after the meta failure")


## D. A meta failure emits no false run_saved.
func _test_D_a_meta_failure_does_not_emit_a_false_run_saved() -> void:
	var ctrl: Node = await _make_controller(670504, true)
	ctrl.meta_writer.fail = true
	var saved: Array = []
	_bus.run_saved.connect(func(seed_value: int) -> void: saved.append(seed_value))
	ctrl.save_now_report()
	_assert(saved.is_empty(),
		"the meta failure emits no run_saved (the emitted list is %s)"
			% str(saved))


## E. The meta retry does NOT replay the gameplay outcome.
func _test_E_the_meta_retry_does_not_replay_the_outcome() -> void:
	var ctrl: Node = await _make_controller(670505, true)
	ctrl.meta_writer.fail = true
	ctrl.save_now_report()
	# The state after the first attempt.
	var gold_before: int = ctrl.state.gold
	var wins_before: int = ctrl.state.wins
	var round_before: int = ctrl.state.round_index
	var losses_before: int = ctrl.state.losses
	var lives_before: int = ctrl.state.lives
	var writes_before: int = ctrl.meta_writer.writes

	# The META is retried alone.
	ctrl.meta_writer.fail = false
	var meta_ok: bool = ctrl.retry_meta_publication()
	_assert(meta_ok, "the meta retry succeeds")
	_assert(ctrl.state.gold == gold_before,
		"the meta retry changed no gold")
	_assert(ctrl.state.wins == wins_before,
		"the meta retry changed no win")
	_assert(ctrl.state.round_index == round_before,
		"the meta retry changed no round")
	_assert(ctrl.state.losses == losses_before,
		"the meta retry changed no loss")
	_assert(ctrl.state.lives == lives_before,
		"the meta retry changed no lives")
	_assert(ctrl.meta_writer.writes == writes_before + 1,
		"the meta retry wrote the meta EXACTLY once (it was %d, it is %d)"
			% [ctrl.meta_writer.writes, writes_before])
	_assert(ctrl.profile.current_run_seed == 670505,
		"the meta retry published the pointer")
	# The checkpoint was NOT rewritten by the meta retry.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var count_before: int = reader.get_save_count()
	ctrl.retry_meta_publication()
	_assert(reader.get_save_count() == count_before,
		"the meta retry wrote no checkpoint")


## F. The checkpoint survives the meta failure: the run is still
## continuable by seed.
func _test_F_the_checkpoint_survives_a_meta_failure() -> void:
	var ctrl: Node = await _make_controller(670506, true)
	ctrl.meta_writer.fail = true
	ctrl.save_now_report()
	# The checkpoint is on the disk and loadable.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(670506)
	_assert(loaded != null and loaded.is_ok(),
		"the checkpoint on the disk is loadable")
	# A FRESH controller can resume it by seed.
	var resumed: Node = await _make_controller(670507, true)
	var ok: bool = resumed.resume_run(670506)
	await process_frame
	_assert(ok, "the checkpoint resumes on a fresh controller")


## G. The committed checkpoint is DISCOVERABLE when the meta pointer is
## stale: the Continue path can find it.
func _test_G_the_committed_checkpoint_is_discoverable() -> void:
	var ctrl: Node = await _make_controller(670508, true)
	ctrl.meta_writer.fail = true
	ctrl.save_now_report()
	# The meta pointer was NOT published.
	_assert(ctrl.profile.current_run_seed == 670508,
		"the in-memory pointer is set even when the meta write failed")
	# The DISCOVERY path finds the committed checkpoint.
	var seeds: Array = ctrl.recoverable_checkpoints()
	_assert(seeds.has(670508),
		"the committed checkpoint is discoverable (the seeds are %s)" % str(seeds))


## H. With more than one candidate the controller must NOT pick one
## silently.
func _test_H_two_checkpoints_are_not_resolved_silently() -> void:
	var first: Node = await _make_controller(670509, true)
	first.save_now_report()
	var second: Node = await _make_controller(670510, true)
	second.save_now_report()
	var seeds: Array = first.recoverable_checkpoints()
	_assert(seeds.size() >= 2, "the two checkpoints are discoverable")
	_assert(seeds.has(670509) and seeds.has(670510),
		"both checkpoints are in the discovery list (the seeds are %s)"
			% str(seeds))
	# The controller did NOT silently choose one.
	_assert(first.profile.current_run_seed == 670509,
		"the controller did not silently switch the active run")


# ----------------------------------------------------------------


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


## A meta writer that can fail, so the partial success is reachable.
class _MetaWriter:
	extends RefCounted

	var fail: bool = false
	var writes: int = 0

	func write_meta(profile: Object) -> bool:
		writes += 1
		return not fail


## Whether the controller class declares the method. Checked on the
## CLASS, not on an instance, so the check works before any instance
## exists.
func ctrl_has_method(script: Object, method_name: String) -> bool:
	for m in script.get_script_method_list():
		if str(m.get("name", "")) == method_name:
			return true
	return false


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage H08: %s" % label)
