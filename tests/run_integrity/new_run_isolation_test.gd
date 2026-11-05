extends SceneTree

## RI-07: a new run must not retain the runtime objects of the previous
## one.
##
## The defect: `start_run` created a fresh `state` and refreshed the
## shop, but it never reset `encounter_map`, `reward`, `runner`, `ctx`,
## `_battle_participants` or the phase-dependent flags.
##
## The consequence that matters: `_enter_map` creates the map LAZILY
## (`if encounter_map == null`), so the new run inherits the PREVIOUS
## run's map -- the already visited nodes and the current node -- and
## the run continues in the middle of the old map instead of at its
## start.
##
## The invariant: a new run starts from a clean runtime.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")

const ISOLATED_DIR: String = "user://run_integrity_ri07/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_the_new_run_has_no_map()
	await _test_B_the_new_run_has_no_battle_runtime()
	await _test_C_the_new_run_has_no_reward_offer()
	await _test_D_the_new_run_has_no_battle_participants()
	print("")
	print("=== STAGE 4E: NEW RUN ISOLATION: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## The map of the previous run must not survive.
func _test_A_the_new_run_has_no_map() -> void:
	var ctrl: Node = await _make_controller(590001)
	# The first run walks into the map.
	ctrl._enter_map()
	_assert(ctrl.encounter_map != null, "the first run has a map")
	# A new run.
	ctrl.start_run(590002)
	_assert(ctrl.encounter_map == null,
		"the new run has no map of the previous run")


## The battle runtime of the previous run must not survive.
func _test_B_the_new_run_has_no_battle_runtime() -> void:
	var ctrl: Node = await _make_controller(590003)
	ctrl.start_battle()
	await process_frame
	_assert(ctrl.runner != null, "the first run has a runner")
	_assert(ctrl.ctx != null, "the first run has a context")
	ctrl.start_run(590004)
	_assert(ctrl.runner == null, "the new run has no runner")
	_assert(ctrl.ctx == null, "the new run has no battle context")


## The reward offer of the previous run must not survive.
func _test_C_the_new_run_has_no_reward_offer() -> void:
	var ctrl: Node = await _make_controller(590005)
	ctrl.reward.generate_offer(2)
	_assert(ctrl.reward.offered_ids().size() > 0,
		"the first run has a reward offer")
	ctrl.start_run(590006)
	_assert(ctrl.reward.offered_ids().is_empty(),
		"the new run has no reward offer")


## The participant bridge of the previous run must not survive.
func _test_D_the_new_run_has_no_battle_participants() -> void:
	var ctrl: Node = await _make_controller(590007)
	ctrl.start_battle()
	await process_frame
	_assert(ctrl._battle_participants != null,
		"the first run has the participant bridge")
	ctrl.start_run(590008)
	_assert(ctrl._battle_participants == null,
		"the new run has no participant bridge")


# ----------------------------------------------------------------


func _make_controller(seed_value: int) -> Node:
	var ctrl: Node = RunControllerScript.new()
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR)
	ctrl.meta_writer = _MetaWriter.new()
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer", &"cleric",
		&"mage", &"knight", &"druid"] as Array[StringName]
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
		print("  [FAIL] Stage 4E: %s" % label)
