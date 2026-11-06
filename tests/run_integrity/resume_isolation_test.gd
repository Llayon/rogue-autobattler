extends SceneTree

## H-04: the stale battle runtime across a resume.
##
## The published integration already fixed the CORE of this finding:
## `resume_run` calls `_reset_transient_runtime()` before it installs
## the restored state, so the runner, the participants, the context
## and the outcome latch do not survive the resume.
##
## The mission asks for the ADDITIONAL checks that were not covered:
##
##   - `runner == null` after a successful nonbattle resume;
##   - `ctx == null`;
##   - `_battle_participants == null`;
##   - the outcome latch is reset;
##   - the stale `BattleScene.battle_view._ctx`;
##   - the stale `UIOverlay._ctx`;
##   - the old battle tick does not change the resumed state;
##   - a FAILED resume leaves the old runtime completely unchanged;
##   - the RNG is preserved exactly.
##
## The presentation boundary: `battle_scene.gd` refreshes the view
## only when `run_controller.ctx != null`:
##
##   if run_controller.ctx != null and battle_view._ctx != run_controller.ctx:
##       battle_view.set_context(run_controller.ctx)
##
## So a NULL context -- the state after a successful resume -- does
## NOT clear the stale visual context of the previous battle.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const BattleSceneScript = preload("res://scenes/battle/battle_scene.gd")
const RngServiceScript = preload("res://core/utils/rng_service.gd")
const FaultOps = preload("res://tests/save_repository/support/run_save_file_ops_fault.gd")

const ISOLATED_DIR: String = "user://run_integrity_h04/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_the_core_runtime_is_cleared()
	await _test_B_the_failed_resume_keeps_the_old_runtime()
	await _test_C_the_resume_preserves_the_rng_exactly()
	await _test_D_the_stale_visual_context_is_cleared()
	print("")
	print("=== STAGE H04: THE RESUME CLEARS THE BATTLE RUNTIME: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. The CORE runtime is cleared by a successful resume.
func _test_A_the_core_runtime_is_cleared() -> void:
	var ctrl: Node = await _make_controller(670901)
	ctrl._enter_map()
	await process_frame
	_assert(ctrl.start_battle(), "the battle starts")
	await process_frame
	_assert(ctrl.runner != null, "the battle has a runner")
	_assert(ctrl.ctx != null, "the battle has a context")
	_assert(ctrl._battle_participants != null, "the battle has participants")
	# The outcome latch is armed only after an outcome; the runtime
	# clear must reset it.
	ctrl._battle_outcome_applied = true
	ctrl.save_now()
	await process_frame

	var resumed: Node = await _make_controller(670902)
	var ok: bool = resumed.resume_run(670901)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(resumed.runner == null, "the runner is null after the resume")
	_assert(resumed.ctx == null, "the context is null after the resume")
	_assert(resumed._battle_participants == null,
		"the participants are null after the resume")
	_assert(not resumed._battle_outcome_applied,
		"the outcome latch is reset after the resume")


## B. A FAILED resume leaves the OLD runtime completely unchanged: the
## resume is transactional.
func _test_B_the_failed_resume_keeps_the_old_runtime() -> void:
	var ctrl: Node = await _make_controller(670903)
	ctrl._enter_map()
	await process_frame
	_assert(ctrl.start_battle(), "the battle starts")
	await process_frame
	_assert(ctrl.runner != null, "the battle has a runner")
	var runner_before: Object = ctrl.runner
	var ctx_before: Object = ctrl.ctx
	var participants_before: Object = ctrl._battle_participants

	# The resume of a seed that does not exist FAILS.
	var ok: bool = ctrl.resume_run(999999999)
	await process_frame
	_assert(not ok, "the resume of a missing checkpoint fails")
	_assert(ctrl.runner == runner_before,
		"the failed resume kept the runner")
	_assert(ctrl.ctx == ctx_before,
		"the failed resume kept the context")
	_assert(ctrl._battle_participants == participants_before,
		"the failed resume kept the participants")


## C. The resume preserves the RNG exactly.
func _test_C_the_resume_preserves_the_rng_exactly() -> void:
	var ctrl: Node = await _make_controller(670904)
	ctrl._enter_map()
	await process_frame
	ctrl.start_battle()
	await process_frame
	ctrl.save_now()
	await process_frame
	var before: Dictionary = RngServiceScript.snapshot()

	var resumed: Node = await _make_controller(670905)
	var ok: bool = resumed.resume_run(670904)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	var after: Dictionary = RngServiceScript.snapshot()
	_assert(str(after.get("state", "")) == str(before.get("state", "")),
		"the RNG state survived the resume exactly (got %s, it is %s)"
			% [str(after.get("state", "")), str(before.get("state", ""))])


## D. The stale VISUAL context is cleared: after a successful resume
## the battle view and the UI overlay must not hold the context of the
## previous battle.
func _test_D_the_stale_visual_context_is_cleared() -> void:
	var ctrl: Node = await _make_controller(670906)
	ctrl._enter_map()
	await process_frame
	_assert(ctrl.start_battle(), "the battle starts")
	await process_frame
	_assert(ctrl.ctx != null, "the battle has a context")

	# The scene holds the visual context of the battle. The sync
	# lives in `_process`, which is the production path.
	var scene: Node = BattleSceneScript.new()
	get_root().add_child(scene)
	await process_frame
	scene.run_controller = ctrl
	scene._process(0.016)
	await process_frame
	_assert(scene.battle_view != null, "the scene has a battle view")
	_assert(scene.battle_view._ctx == ctrl.ctx,
		"the battle view holds the context of the battle")

	# The resume clears the core context.
	ctrl.save_now()
	await process_frame
	var resumed: Node = await _make_controller(670907)
	var ok: bool = resumed.resume_run(670906)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(resumed.ctx == null, "the resumed controller has no context")

	# The scene is now bound to the resumed controller.
	scene.run_controller = resumed
	scene._process(0.016)
	await process_frame
	_assert(scene.battle_view._ctx == null,
		"the battle view does NOT hold the stale context")
	_assert(scene.ui_overlay == null or scene.ui_overlay._ctx == null,
		"the UI overlay does NOT hold the stale context")


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


## A meta writer that does NOT touch the production meta file.
class _MetaWriter:
	extends RefCounted

	var fail: bool = false
	var writes: int = 0

	func write_meta(profile: Object) -> bool:
		writes += 1
		return not fail


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage H04: %s" % label)
