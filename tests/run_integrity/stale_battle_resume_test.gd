extends SceneTree

## The resume must clear the BATTLE runtime.
##
## The independent critic of the INVENTORY + RUN INTEGRITY integration
## left one lead INCONCLUSIVE: "the stale battle runtime across
## `resume_run`". It was a real defect, and it is measured here.
##
## `resume_run` replaced the domain state, the shop, the merchant, the
## reward and the map -- but NOT `runner` and `_battle_participants`.
## A stale runner therefore survived the resume: `tick_battle(dt)`
## advances it unconditionally, and when it ENDS,
## `_on_battle_ended()` applies the OLD battle's outcome to the NEW
## state.
##
## The measured failure, before the fix:
##
##   the stale runner survived the resume: true
##   the gold after the ticks: 16     (it was 10)
##   the round after the ticks: 2      (it was 1)
##   >>> the stale battle mutated the resumed run: true
##
## That is a violation of the RI-05 outcome transaction (the outcome
## of a battle that the resumed run never fought) and of the RI-07
## isolation.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")

const ISOLATED_DIR: String = "user://run_integrity_stale_battle/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_the_resume_clears_the_battle_runtime()
	await _test_B_a_stale_battle_cannot_mutate_the_resumed_run()
	await _test_C_the_resumed_run_can_still_fight()
	print("")
	print("=== STAGE 4K: THE RESUME CLEARS THE BATTLE RUNTIME: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. The battle runtime is gone after a resume.
func _test_A_the_resume_clears_the_battle_runtime() -> void:
	var ctrl: Node = await _make_controller(670003)
	ctrl.start_battle()
	await process_frame
	_assert(ctrl.runner != null, "the battle has a runner")
	_assert(ctrl._battle_participants != null,
		"the battle has the participants")
	ctrl.save_now()
	var resumed: bool = ctrl.resume_run(670003)
	await process_frame
	_assert(resumed, "the checkpoint resumes")
	_assert(ctrl.runner == null,
		"the resume cleared the stale runner")
	_assert(ctrl._battle_participants == null,
		"the resume cleared the stale participants")
	_assert(not ctrl._battle_outcome_applied,
		"the resume cleared the outcome latch")


## B. A stale battle cannot mutate the resumed run.
func _test_B_a_stale_battle_cannot_mutate_the_resumed_run() -> void:
	var ctrl: Node = await _make_controller(670004)
	ctrl.start_battle()
	await process_frame
	var gold_before: int = ctrl.state.gold
	var round_before: int = ctrl.state.round_index
	var losses_before: int = ctrl.state.losses
	var lives_before: int = ctrl.state.lives
	ctrl.save_now()
	var resumed: bool = ctrl.resume_run(670004)
	await process_frame
	_assert(resumed, "the checkpoint resumes")
	# The phase AFTER the resume is the one from the checkpoint. The
	# stale battle must not move it.
	var phase_before: int = int(ctrl.phase)

	# Tick as hard as the stale battle would.
	for i in 4000:
		ctrl.tick_battle(0.05)
		if int(ctrl.phase) == 3:
			break

	_assert(ctrl.state.gold == gold_before,
		"the stale battle changed no gold (got %d, it was %d)"
			% [ctrl.state.gold, gold_before])
	_assert(ctrl.state.round_index == round_before,
		"the stale battle changed no round (got %d, it was %d)"
			% [ctrl.state.round_index, round_before])
	_assert(ctrl.state.losses == losses_before,
		"the stale battle changed no losses")
	_assert(ctrl.state.lives == lives_before,
		"the stale battle changed no lives")
	_assert(int(ctrl.phase) == phase_before,
		"the stale battle left the phase alone (got %d, it was %d)"
			% [int(ctrl.phase), phase_before])


## C. The resumed run can still fight: the fix must not disable the
## battle.
func _test_C_the_resumed_run_can_still_fight() -> void:
	var ctrl: Node = await _make_controller(670005)
	ctrl.save_now()
	var resumed: bool = ctrl.resume_run(670005)
	await process_frame
	_assert(resumed, "the checkpoint resumes")
	var started: bool = ctrl.start_battle()
	await process_frame
	_assert(started, "the resumed run can start a battle")
	_assert(ctrl.runner != null, "the new battle has a runner")
	_assert(int(ctrl.phase) == 1, "the phase is BATTLE")


# ----------------------------------------------------------------


func _make_controller(seed_value: int) -> Node:
	var ctrl: Node = RunControllerScript.new()
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR)
	ctrl.meta_writer = _MetaWriter.new()
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer", &"cleric",
		&"mage"] as Array[StringName]
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
		print("  [FAIL] Stage 4K: %s" % label)
