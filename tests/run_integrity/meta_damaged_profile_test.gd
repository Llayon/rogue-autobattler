extends SceneTree

## A0.1 / D1: the SILENT RESET must be impossible.
##
## The baseline:
##
##   SaveService.load_meta() -> null (the profile is damaged and the
##                                 recovery failed)
##   RunController._ready()   -> if profile == null: profile = MetaProfile.new()
##
## So the game's initialization turned the EXPLICIT failure back into
## a NEW EMPTY PROFILE -- and the next successful write replaced the
## player's damaged profile with that empty one. The protection at the
## service level was bypassed by four lines of the old initialization.
##
## The contract:
##
##   the profile file NEVER existed -> a new profile is correct
##   the profile is DAMAGED          -> an EXPLICIT failure, and the
##                                      damaged file is NOT overwritten
##                                      with an empty profile
##
## The scenario:
##
##   corrupt meta.tres (and its commit-old) -> the controller is
##   initialized -> the damaged profile is NOT replaced, and a
##   subsequent write does NOT overwrite it either.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const MetaStoreScript = preload("res://core/save/meta_store.gd")
const SaveServiceScript = preload("res://core/save/save_service.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")

const ISOLATED_DIR: String = "user://run_integrity_a01_reset/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_a_damaged_profile_is_not_replaced_at_initialization()
	await _test_B_a_damaged_profile_is_not_overwritten_by_a_later_write()
	await _test_C_a_missing_profile_still_creates_a_new_one()
	await _test_D_the_controller_reports_the_damaged_profile()
	# A0.1: the seam is restored, so the production store is used
	# again by anything that runs after this suite.
	SaveServiceScript.set_meta_store_for_test(null)
	print("")
	print("=== A0.1 / D1: THE SILENT RESET IS IMPOSSIBLE: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. A damaged profile is NOT replaced at the initialization.
func _test_A_a_damaged_profile_is_not_replaced_at_initialization() -> void:
	var theDir: String = ISOLATED_DIR + "a/"
	_reset_dir(theDir)
	# A damaged profile: the target AND the previous generation are
	# garbage, so the recovery cannot help.
	_write_garbage(theDir + "meta.tres")
	_write_garbage(theDir + "meta.tres.commit-old")
	var theBytesBefore: PackedByteArray = FileAccess.get_file_as_bytes(
		theDir + "meta.tres")

	SaveServiceScript.set_meta_store_for_test(MetaStoreScript.new(theDir))
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child(ctrl)
	await process_frame

	# The damaged file must be EXACTLY as it was: the initialization
	# did not write a fresh profile over it.
	var theBytesAfter: PackedByteArray = FileAccess.get_file_as_bytes(
		theDir + "meta.tres")
	_assert(theBytesBefore == theBytesAfter,
		"the initialization did NOT overwrite the damaged profile")
	# And the controller must KNOW that the profile is damaged.
	_assert(ctrl.meta_profile_damaged(),
		"the controller reports the damaged profile")
	ctrl.queue_free()
	await process_frame


## B. A damaged profile is NOT overwritten by a later write.
func _test_B_a_damaged_profile_is_not_overwritten_by_a_later_write() -> void:
	var theDir: String = ISOLATED_DIR + "b/"
	_reset_dir(theDir)
	_write_garbage(theDir + "meta.tres")
	_write_garbage(theDir + "meta.tres.commit-old")
	var theBytesBefore: PackedByteArray = FileAccess.get_file_as_bytes(
		theDir + "meta.tres")

	SaveServiceScript.set_meta_store_for_test(MetaStoreScript.new(theDir))
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child(ctrl)
	await process_frame

	# A write attempt: the controller has a profile in memory, and the
	# save path runs.
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.total_runs = 42
	ctrl._save_meta(ctrl.profile)
	await process_frame

	var theBytesAfter: PackedByteArray = FileAccess.get_file_as_bytes(
		theDir + "meta.tres")
	_assert(theBytesBefore == theBytesAfter,
		"the write did NOT overwrite the damaged profile")
	# The write must have been REFUSED, not silently reported as a
	# success.
	_assert(not ctrl._save_meta(ctrl.profile),
		"the write over a damaged profile is REFUSED")
	ctrl.queue_free()
	await process_frame


## C. A missing profile still creates a new one.
func _test_C_a_missing_profile_still_creates_a_new_one() -> void:
	var theDir: String = ISOLATED_DIR + "c/"
	_reset_dir(theDir)
	SaveServiceScript.set_meta_store_for_test(MetaStoreScript.new(theDir))
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child(ctrl)
	await process_frame
	_assert(ctrl.profile != null, "the controller has a profile")
	_assert(not ctrl.meta_profile_damaged(),
		"a missing profile is NOT a damaged profile")
	_assert(int(ctrl.profile.total_runs) == 0,
		"the new profile is the default")
	ctrl.queue_free()
	await process_frame


## D. The controller reports the damaged profile.
func _test_D_the_controller_reports_the_damaged_profile() -> void:
	var theDir: String = ISOLATED_DIR + "d/"
	_reset_dir(theDir)
	_write_garbage(theDir + "meta.tres")
	_write_garbage(theDir + "meta.tres.commit-old")
	SaveServiceScript.set_meta_store_for_test(MetaStoreScript.new(theDir))
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child(ctrl)
	await process_frame
	_assert(ctrl.meta_profile_damaged(),
		"the damaged profile is reported to the caller")
	# The controller must still be usable: a damaged profile must not
	# crash the game.
	_assert(ctrl.profile != null, "the controller still has a profile")
	ctrl.queue_free()
	await process_frame


# ----------------------------------------------------------------


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
	f.store_string("[gd_resource type=\"Resource\" broken")
	f.close()


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] A0.1/D1-reset: %s" % label)
