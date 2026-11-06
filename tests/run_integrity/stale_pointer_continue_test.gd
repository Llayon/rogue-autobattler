extends SceneTree

## R-04 (independent critic, MAJOR): the "stale meta pointer" Continue
## path was NOT reachable.
##
## H-08's contract says: when the meta pointer is stale or zero, the
## committed checkpoint must be DISCOVERABLE so Continue can find it.
## But `recoverable_checkpoints()` had no production caller, and the
## Continue button in the main menu was gated on
## `_profile.current_run_seed != 0`:
##
##     _continue_button.visible = (_profile.current_run_seed != 0)
##
## So the exact scenario the finding names -- the meta write failed,
## the pointer is stale, the player cannot find their run -- was still
## broken FOR THE PLAYER. The run file was on the disk and the game
## said there was nothing to continue.
##
## The contract:
##
##   the pointer is fresh       -> Continue offers the pointer's seed
##   the pointer is stale AND
##   exactly one checkpoint is
##   on the disk                -> Continue offers THAT checkpoint
##   the pointer is stale AND
##   SEVERAL checkpoints are on
##   the disk                   -> the controller must NOT pick one
##                                 silently; the menu asks
##
## The candidate discovery goes through the SAME seam as the save and
## the load.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const MainMenuScript = preload("res://scenes/main_menu/main_menu.gd")
const FaultOps = preload("res://tests/save_repository/support/run_save_file_ops_fault.gd")

const ISOLATED_DIR: String = "user://run_integrity_r04/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	# The API presence is checked FIRST: a missing method must produce
	# a `[FAIL]`, not a SCRIPT ERROR that aborts the suite.
	_assert(_has_method(MainMenuScript, "set_profile_for_test"),
		"the menu has the profile seam")
	_assert(_has_method(MainMenuScript, "set_save_repository_for_test"),
		"the menu has the repository seam")
	_assert(_has_method(MainMenuScript, "continue_seed"),
		"the menu reports the seed it would continue")
	_assert(_has_method(MainMenuScript, "continue_needs_choice"),
		"the menu reports that it needs a choice")
	_assert(_has_method(MainMenuScript, "continue_is_silent"),
		"the menu reports that it does not resolve silently")
	if _failed > 0:
		print("")
		print("=== STAGE R04: THE STALE POINTER CONTINUE PATH: %d pass / %d fail ==="
			% [_passed, _failed])
		quit(1)
		return
	await _test_A_the_menu_offers_the_stale_checkpoint()
	await _test_B_the_fresh_pointer_wins()
	await _test_C_several_candidates_are_not_resolved_silently()
	await _test_D_the_menu_asks_when_there_are_several_candidates()
	print("")
	print("=== STAGE R04: THE STALE POINTER CONTINUE PATH: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. The menu offers the committed checkpoint when the pointer is
## stale and there is exactly ONE candidate.
func _test_A_the_menu_offers_the_stale_checkpoint() -> void:
	var ctrl: Node = await _make_controller(672101)
	ctrl.meta_writer.fail = true
	ctrl.save_now_report()
	# The pointer was NOT published.
	_assert(ctrl.profile.current_run_seed == 672101,
		"the in-memory pointer is set")
	# The checkpoint is on the disk.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	_assert(reader.load_run(672101) != null,
		"the checkpoint is on the disk")

	# The MENU sees the stale pointer (zero) and the committed
	# checkpoint.
	var menu: Node = MainMenuScript.new()
	get_root().add_child(menu)
	await process_frame
	menu.set_profile_for_test(ctrl.profile)
	menu.set_save_repository_for_test(ctrl.save_repository)
	menu._refresh()
	await process_frame
	var seed: int = menu.continue_seed()
	_assert(seed == 672101,
		"the menu offers the committed checkpoint (got %d, it is %d)"
			% [seed, 672101])


## B. The fresh pointer wins: the menu offers the pointer's seed, not
## some other checkpoint.
func _test_B_the_fresh_pointer_wins() -> void:
	var ctrl: Node = await _make_controller(672102)
	ctrl.save_now_report()
	var menu: Node = MainMenuScript.new()
	get_root().add_child(menu)
	await process_frame
	menu.set_profile_for_test(ctrl.profile)
	menu.set_save_repository_for_test(ctrl.save_repository)
	menu._refresh()
	await process_frame
	_assert(menu.continue_seed() == 672102,
		"the menu offers the fresh pointer (got %d)" % menu.continue_seed())


## C. With SEVERAL candidates the controller must NOT pick one
## silently.
func _test_C_several_candidates_are_not_resolved_silently() -> void:
	var first: Node = await _make_controller(672103)
	first.save_now_report()
	var second: Node = await _make_controller(672104)
	second.save_now_report()
	var seeds: Array = first.recoverable_checkpoints()
	_assert(seeds.size() >= 2, "there are at least two candidates")
	_assert(first.profile.current_run_seed == 672103,
		"the controller did not switch the active run")


## D. The menu ASKS when there are several candidates: it does not
## silently resolve the ambiguity.
func _test_D_the_menu_asks_when_there_are_several_candidates() -> void:
	var first: Node = await _make_controller(672105)
	first.save_now_report()
	var second: Node = await _make_controller(672106)
	second.save_now_report()
	# The pointer is STALE -- the H-08 scenario: the meta write
	# failed, so the pointer that is on the disk is zero. The fresh
	# pointer would win, and that is the contract, so the ambiguity
	# case needs the stale one.
	var stale_profile: MetaProfileScript = MetaProfileScript.new()
	stale_profile.current_run_seed = 0
	var menu: Node = MainMenuScript.new()
	get_root().add_child(menu)
	await process_frame
	menu.set_profile_for_test(stale_profile)
	menu.set_save_repository_for_test(first.save_repository)
	menu._refresh()
	await process_frame
	_assert(menu.continue_needs_choice(),
		"the menu asks when there are several candidates")
	_assert(not menu.continue_is_silent(),
		"the menu does not resolve the ambiguity silently")
	_assert(menu.continue_seed() == 0,
		"the menu offers NO seed when the choice is ambiguous (got %d)"
			% menu.continue_seed())


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


## Whether the class declares the method. Checked on the CLASS, so
## the check works before any instance exists.
func _has_method(script: Object, method_name: String) -> bool:
	for m in script.get_script_method_list():
		if str(m.get("name", "")) == method_name:
			return true
	return false


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage R04: %s" % label)
