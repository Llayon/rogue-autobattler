extends SceneTree

## A0.1: the findings of the independent critic.
##
## The critic found four MUST-fix defects that the first three suites
## did not cover:
##
##   F1 (HIGH) -- `MetaStore.save_meta()` ignored the recovery's
##   failure, so a FULLY DAMAGED slot was overwritten: both the
##   damaged target AND the damaged commit-old were destroyed. The
##   contract says "both damaged -> an explicit error and NOTHING is
##   destroyed".
##
##   F2 (HIGH) -- the MAIN MENU still received a DEFAULT profile for
##   a damaged slot, and the next menu write (the battle speed) then
##   replaced the damaged data with that default. The controller's
##   guard did not protect the menu.
##
##   F3 (HIGH) -- `buy_unit()` returned a non-null Resource even when
##   the write failed, NO production caller read the pending flag,
##   and `_process` had no purchase-retry driver: the purchase was
##   silently non-durable and nothing ever retried it.
##
##   F4 (MEDIUM) -- `_write_purchase()` read only
##   `checkpoint_committed`, so a PARTIAL success (the checkpoint
##   landed, the meta pointer did not) was treated as a complete
##   success: the purchase was declared durable while Continue was
##   still not discoverable.
##
## The scenarios:
##
##   A. a write over a fully damaged slot is REFUSED and destroys
##      nothing
##   B. the menu does not write over a damaged profile
##   C. the controller retries the pending purchase automatically
##   D. the partial success is not a durable purchase

const MetaStoreScript = preload("res://core/save/meta_store.gd")
const SaveServiceScript = preload("res://core/save/save_service.gd")
const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const MainMenuScript = preload("res://scenes/main_menu/main_menu.gd")
const FaultOps = preload("res://tests/save_repository/support/run_save_file_ops_fault.gd")

const ISOLATED_DIR: String = "user://run_integrity_a01_findings/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_a_write_over_a_damaged_slot_is_refused()
	await _test_B_the_menu_does_not_write_over_a_damaged_profile()
	await _test_C_the_controller_retries_the_pending_purchase()
	await _test_D_the_partial_success_is_not_a_durable_purchase()
	await _test_E_the_commit_old_cleanup_failure_is_not_a_write_failure()
	await _test_F_the_load_result_tells_whether_the_file_existed()
	print("")
	print("=== A0.1: THE CRITIC'S FINDINGS: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. A write over a fully damaged slot is REFUSED, and nothing is
## destroyed.
func _test_A_a_write_over_a_damaged_slot_is_refused() -> void:
	var theDir: String = ISOLATED_DIR + "a/"
	_reset_dir(theDir)
	# Both generations are damaged.
	_write_garbage(theDir + "meta.tres")
	_write_garbage(theDir + "meta.tres.commit-old")
	var theTargetBefore: PackedByteArray = FileAccess.get_file_as_bytes(
		theDir + "meta.tres")
	var theCommitBefore: PackedByteArray = FileAccess.get_file_as_bytes(
		theDir + "meta.tres.commit-old")

	SaveServiceScript.set_meta_store_for_test(MetaStoreScript.new(theDir))
	var theProfile: MetaProfile = MetaProfileScript.new()
	theProfile.total_runs = 99
	var ok: bool = SaveServiceScript.save_meta(theProfile)
	_assert(not ok, "the write over a fully damaged slot is REFUSED")

	# NOTHING is destroyed: both generations are still there, byte for
	# byte.
	_assert(FileAccess.file_exists(theDir + "meta.tres"),
		"the damaged target was NOT destroyed")
	_assert(FileAccess.file_exists(theDir + "meta.tres.commit-old"),
		"the damaged commit-old was NOT destroyed")
	var theTargetAfter: PackedByteArray = FileAccess.get_file_as_bytes(
		theDir + "meta.tres")
	var theCommitAfter: PackedByteArray = FileAccess.get_file_as_bytes(
		theDir + "meta.tres.commit-old")
	_assert(theTargetBefore == theTargetAfter,
		"the damaged target was NOT overwritten")
	_assert(theCommitBefore == theCommitAfter,
		"the damaged commit-old was NOT overwritten")
	SaveServiceScript.set_meta_store_for_test(null)


## B. The menu does not write over a damaged profile.
func _test_B_the_menu_does_not_write_over_a_damaged_profile() -> void:
	var theDir: String = ISOLATED_DIR + "b/"
	_reset_dir(theDir)
	_write_garbage(theDir + "meta.tres")
	_write_garbage(theDir + "meta.tres.commit-old")
	var theBefore: PackedByteArray = FileAccess.get_file_as_bytes(
		theDir + "meta.tres")

	SaveServiceScript.set_meta_store_for_test(MetaStoreScript.new(theDir))
	# The menu's real load path.
	var theMenu: Node = MainMenuScript.new()
	theMenu.set("_meta_reader", null)
	# The menu reads the profile through its own seam; with the seam
	# unset it goes through the service.
	var theProfile: Object = theMenu.call("_load_meta")
	_assert(theProfile != null, "the menu got a profile object")
	# The menu must KNOW the profile is damaged.
	_assert(bool(theMenu.call("meta_profile_damaged")),
		"the menu reports the damaged profile")
	# And the menu's write must be refused.
	var theWritten: bool = bool(theMenu.call("_save_meta", theProfile))
	_assert(not theWritten,
		"the menu's write over a damaged profile is REFUSED")
	var theAfter: PackedByteArray = FileAccess.get_file_as_bytes(
		theDir + "meta.tres")
	_assert(theBefore == theAfter,
		"the menu did NOT overwrite the damaged profile")
	theMenu.free()
	SaveServiceScript.set_meta_store_for_test(null)


## C. The controller retries the pending purchase automatically.
func _test_C_the_controller_retries_the_pending_purchase() -> void:
	var ctrl: Node = await _make_controller(671201)
	await _enter_prep(ctrl)
	ctrl.state.gold = 1000
	# The write fails.
	var ops: Object = _failing_ops()
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
	_assert(ctrl.buy_unit(0) != null, "the purchase itself succeeds")
	_assert(ctrl.purchase_persistence_pending(),
		"the failed write is pending")

	# The filesystem recovers.
	var healthy: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	ctrl.save_repository = healthy
	# The controller's own tick must drive the retry -- there must be
	# NO manual call.
	ctrl.call("_process", 0.016)
	await process_frame
	_assert(not ctrl.purchase_persistence_pending(),
		"the controller's tick retried the pending purchase")
	# And the checkpoint holds the purchase.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(671201)
	_assert(loaded != null and loaded.is_ok(), "the checkpoint reads back")
	ctrl.queue_free()
	await process_frame


## D. The partial success is not a durable purchase.
func _test_D_the_partial_success_is_not_a_durable_purchase() -> void:
	var ctrl: Node = await _make_controller(671202)
	await _enter_prep(ctrl)
	ctrl.state.gold = 1000
	# The checkpoint lands, but the META write fails: a partial
	# success.
	ctrl.meta_writer = _FailingMetaWriter.new()
	var bought: Resource = ctrl.buy_unit(0)
	_assert(bought != null, "the purchase itself succeeds")
	_assert(ctrl.purchase_persistence_pending(),
		"the partial success is NOT a durable purchase")
	ctrl.queue_free()
	await process_frame


## E. The commit-old cleanup failure is not a write failure.
func _test_E_the_commit_old_cleanup_failure_is_not_a_write_failure() -> void:
	var theDir: String = ISOLATED_DIR + "e/"
	_reset_dir(theDir)
	SaveServiceScript.set_meta_store_for_test(MetaStoreScript.new(theDir))
	var first: MetaProfile = MetaProfileScript.new()
	first.total_runs = 1
	_assert(SaveServiceScript.save_meta(first), "the first write succeeds")

	# The `remove` of the commit-old fails, but the write itself is
	# fine: the new profile IS on the disk.
	var failing: Object = MetaStoreScript.new(theDir)
	failing.set("ops", _remove_failing_ops())
	SaveServiceScript.set_meta_store_for_test(failing)
	var second: MetaProfile = MetaProfileScript.new()
	second.total_runs = 2
	var ok: bool = SaveServiceScript.save_meta(second)
	_assert(ok,
		"the write succeeds even when the commit-old cleanup fails")
	SaveServiceScript.set_meta_store_for_test(null)
	# The new profile is readable.
	var healthy: Object = MetaStoreScript.new(theDir)
	var loaded: Object = healthy.load_meta()
	_assert(loaded != null, "the profile reads back")
	if loaded != null:
		_assert(int(loaded.total_runs) == 2,
			"the NEW profile is on the disk (it is %d)" % int(loaded.total_runs))


## F. The load result tells whether the file existed.
func _test_F_the_load_result_tells_whether_the_file_existed() -> void:
	var theDir: String = ISOLATED_DIR + "f/"
	_reset_dir(theDir)
	SaveServiceScript.set_meta_store_for_test(MetaStoreScript.new(theDir))
	# A MISSING file: the result must say it did not exist.
	var theFirst: Dictionary = SaveServiceScript.load_meta_result()
	_assert(bool(theFirst["ok"]), "the missing profile loads a new one")
	_assert(not bool(theFirst["existed"]),
		"the missing profile is reported as NOT existed")
	# After a write, the file DOES exist.
	var theProfile: MetaProfile = MetaProfileScript.new()
	theProfile.total_runs = 3
	_assert(SaveServiceScript.save_meta(theProfile), "the write succeeds")
	var theSecond: Dictionary = SaveServiceScript.load_meta_result()
	_assert(bool(theSecond["existed"]),
		"the written profile is reported as existed")
	SaveServiceScript.set_meta_store_for_test(null)


# ----------------------------------------------------------------


## The ops whose write fails.
func _failing_ops() -> Object:
	var ops: Object = FaultOps.new()
	ops.fail_methods = {&"write_bytes_and_flush": true}
	return ops


## The ops whose `remove` fails.
func _remove_failing_ops() -> Object:
	var ops: Object = FaultOps.new()
	ops.fail_methods = {&"remove": true}
	return ops


## A meta writer that always fails.
class _FailingMetaWriter:
	extends RefCounted

	func write_meta(profile: Object) -> bool:
		return false


## Enters the PREP phase with a shop offer.
func _enter_prep(ctrl: Node) -> void:
	ctrl._enter_map()
	await process_frame
	ctrl._refresh_shop()
	ctrl._set_phase(0)
	await process_frame


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


## Empties a directory.
func _reset_dir(theDir: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(theDir))
	var theFull: String = ProjectSettings.globalize_path(theDir)
	var theDirAccess: DirAccess = DirAccess.open(theFull)
	if theDirAccess == null:
		return
	for theFile in theDirAccess.get_files():
		theDirAccess.remove(theFile)


## Writes bytes that are not a valid resource.
func _write_garbage(thePath: String) -> void:
	var f: FileAccess = FileAccess.open(thePath, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("[gd_resource type=\"Resource\" format=3 uid=\"uid://a01fnd\"]\n\n[resource]\nresource_name = \"damaged\"\n")
	f.close()


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] A0.1/findings: %s" % label)
