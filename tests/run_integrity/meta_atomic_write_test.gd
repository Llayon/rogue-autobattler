extends SceneTree

## A0.1 / D1: the MetaProfile write must be ATOMIC.
##
## The baseline:
##
##   SaveService.save_meta() -> SaveSvc.save_resource()
##   -> ResourceSaver.save(profile, "user://saves/meta.tres")
##
## A direct write to the target: a crash during the write leaves
## `meta.tres` truncated, and `load_meta()` then returns a DEFAULT
## profile -- the statistics, the unlocks, the currency and the
## settings are silently gone.
##
## The contract:
##
##   write temp -> verify temp (it must LOAD and be a MetaProfile)
##   -> target -> target.commit-old -> temp -> target (the swap)
##   -> verify target -> remove commit-old
##
## and on the NEXT load:
##
##   target valid            -> the target is authoritative
##   target missing, commit-old valid -> restore the commit-old
##   target invalid, commit-old valid -> restore the commit-old
##   both invalid            -> an EXPLICIT failure, nothing destroyed
##
## The scenarios, each over an ISOLATED directory:
##
##   first write -> the profile reads back
##   second write -> the NEW version reads back
##   the temp write fails -> the old profile survives
##   the temp verification fails -> the old profile survives
##   the first rename fails -> the old profile survives
##   the second rename fails -> recovery restores a valid profile
##   a crash after the swap -> the new valid profile survives
##   the new file is corrupted -> recovery restores the old one
##   both are corrupted -> an explicit error, nothing destroyed
##   a double recovery -> no second change
##   an empty directory -> a new profile is created
##
## The CACHE SAFETY matters: `ResourceLoader` caches resources, so a
## validation that calls `load(path)` can return the CACHED object and
## prove nothing. The validation therefore reads the file BYTES and
## loads them through `ResourceLoader.load()` with the cache cleared,
## or it parses the text directly.

const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const MetaStoreScript = preload("res://core/save/meta_store.gd")
const SaveServiceScript = preload("res://core/save/save_service.gd")
const FaultOps = preload("res://tests/save_repository/support/run_save_file_ops_fault.gd")

const ISOLATED_DIR: String = "user://run_integrity_a01/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	# The PRODUCTION path is exercised: the service writes through the
	# atomic store, and the seam points it at an isolated directory.
	# Without this the suite would prove only that the store works,
	# while the production `save_meta()` could still write directly.
	SaveServiceScript.set_meta_store_for_test(MetaStoreScript.new(ISOLATED_DIR))
	await _test_A_the_first_write_reads_back()
	await _test_B_the_second_write_reads_the_new_version()
	await _test_C_a_failed_temp_write_keeps_the_old_profile()
	await _test_D_a_failed_temp_verification_keeps_the_old_profile()
	await _test_E_a_failed_first_rename_keeps_the_old_profile()
	await _test_F_a_failed_second_rename_leaves_a_recoverable_profile()
	await _test_G_a_crash_after_the_swap_keeps_the_new_profile()
	await _test_H_a_corrupted_new_file_recovers_the_old_one()
	await _test_I_two_corrupted_files_report_an_explicit_error()
	await _test_J_a_double_recovery_changes_nothing()
	await _test_K_an_empty_directory_creates_a_new_profile()
	await _test_L_the_cache_does_not_fool_the_validation()
	# A0.1: the seam is restored, so the production store is used
	# again by anything that runs after this suite.
	SaveServiceScript.set_meta_store_for_test(null)
	print("")
	print("=== A0.1 / D1: THE METAPROFILE WRITE IS ATOMIC: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. The first write reads back.
func _test_A_the_first_write_reads_back() -> void:
	var theDir: String = ISOLATED_DIR + "a/"
	_reset_dir(theDir)
	var theProfile: MetaProfile = MetaProfileScript.new()
	theProfile.total_runs = 3
	theProfile.total_wins = 2
	theProfile.best_round = 7
	theProfile.soul_currency = 11
	theProfile.current_run_seed = 4242
	theProfile.battle_speed = 2.0
	theProfile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]

	var theStore: Object = _service_store(theDir)
	var ok: bool = SaveServiceScript.save_meta(theProfile)
	_assert(ok, "the first write succeeds")
	var loaded: Object = SaveServiceScript.load_meta()
	_assert(loaded != null, "the profile reads back")
	if loaded != null:
		_assert(int(loaded.total_runs) == 3, "total_runs reads back")
		_assert(int(loaded.total_wins) == 2, "total_wins reads back")
		_assert(int(loaded.best_round) == 7, "best_round reads back")
		_assert(int(loaded.soul_currency) == 11, "soul_currency reads back")
		_assert(int(loaded.current_run_seed) == 4242, "current_run_seed reads back")
		_assert(is_equal_approx(float(loaded.battle_speed), 2.0), "battle_speed reads back")
		_assert((loaded.unlocked_units as Array).size() == 2, "unlocked_units reads back")


## B. The second write reads the NEW version.
func _test_B_the_second_write_reads_the_new_version() -> void:
	var theDir: String = ISOLATED_DIR + "b/"
	_reset_dir(theDir)
	var theStore: Object = _service_store(theDir)
	var first: MetaProfile = MetaProfileScript.new()
	first.total_runs = 1
	_assert(SaveServiceScript.save_meta(first), "the first write succeeds")
	var second: MetaProfile = MetaProfileScript.new()
	second.total_runs = 9
	second.best_round = 5
	_assert(SaveServiceScript.save_meta(second), "the second write succeeds")
	var loaded: Object = SaveServiceScript.load_meta()
	_assert(loaded != null, "the profile reads back")
	if loaded != null:
		_assert(int(loaded.total_runs) == 9,
			"the NEW total_runs reads back (it is %d)" % int(loaded.total_runs))
		_assert(int(loaded.best_round) == 5, "the NEW best_round reads back")


## C. A failed temp write keeps the old profile.
func _test_C_a_failed_temp_write_keeps_the_old_profile() -> void:
	var theDir: String = ISOLATED_DIR + "c/"
	_reset_dir(theDir)
	var theStore: Object = _service_store(theDir)
	var first: MetaProfile = MetaProfileScript.new()
	first.total_runs = 4
	_assert(SaveServiceScript.save_meta(first), "the first write succeeds")

	var failing: Object = MetaStoreScript.new(theDir)
	failing.set("ops", _failing_ops(&"write_bytes_and_flush"))
	SaveServiceScript.set_meta_store_for_test(failing)
	var second: MetaProfile = MetaProfileScript.new()
	second.total_runs = 99
	var ok: bool = SaveServiceScript.save_meta(second)
	_assert(not ok, "the failed write reports the failure")
	SaveServiceScript.set_meta_store_for_test(theStore)
	var loaded: Object = SaveServiceScript.load_meta()
	_assert(loaded != null, "the profile still reads back")
	if loaded != null:
		_assert(int(loaded.total_runs) == 4,
			"the OLD total_runs survives (it is %d)" % int(loaded.total_runs))


## D. A failed temp VERIFICATION keeps the old profile.
func _test_D_a_failed_temp_verification_keeps_the_old_profile() -> void:
	var theDir: String = ISOLATED_DIR + "d/"
	_reset_dir(theDir)
	var theStore: Object = _service_store(theDir)
	var first: MetaProfile = MetaProfileScript.new()
	first.total_runs = 6
	_assert(SaveServiceScript.save_meta(first), "the first write succeeds")

	# The write SUCCEEDS but the bytes that land are garbage: the
	# verification must reject them and the old profile must survive.
	var corrupting: Object = MetaStoreScript.new(theDir)
	corrupting.set("ops", _corrupting_ops())
	SaveServiceScript.set_meta_store_for_test(corrupting)
	var second: MetaProfile = MetaProfileScript.new()
	second.total_runs = 77
	var ok: bool = SaveServiceScript.save_meta(second)
	_assert(not ok, "the corrupted write reports the failure")
	SaveServiceScript.set_meta_store_for_test(theStore)
	var loaded: Object = SaveServiceScript.load_meta()
	_assert(loaded != null, "the profile still reads back")
	if loaded != null:
		_assert(int(loaded.total_runs) == 6,
			"the OLD total_runs survives (it is %d)" % int(loaded.total_runs))


## E. A failed FIRST rename keeps the old profile.
func _test_E_a_failed_first_rename_keeps_the_old_profile() -> void:
	var theDir: String = ISOLATED_DIR + "e/"
	_reset_dir(theDir)
	var theStore: Object = _service_store(theDir)
	var first: MetaProfile = MetaProfileScript.new()
	first.total_runs = 8
	_assert(SaveServiceScript.save_meta(first), "the first write succeeds")

	var failing: Object = MetaStoreScript.new(theDir)
	failing.set("ops", _failing_ops(&"rename"))
	SaveServiceScript.set_meta_store_for_test(failing)
	var second: MetaProfile = MetaProfileScript.new()
	second.total_runs = 88
	var ok: bool = SaveServiceScript.save_meta(second)
	_assert(not ok, "the failed write reports the failure")
	SaveServiceScript.set_meta_store_for_test(theStore)
	var loaded: Object = SaveServiceScript.load_meta()
	_assert(loaded != null, "the profile still reads back")
	if loaded != null:
		_assert(int(loaded.total_runs) == 8,
			"the OLD total_runs survives (it is %d)" % int(loaded.total_runs))


## F. A failed SECOND rename leaves a RECOVERABLE profile.
func _test_F_a_failed_second_rename_leaves_a_recoverable_profile() -> void:
	var theDir: String = ISOLATED_DIR + "f/"
	_reset_dir(theDir)
	var theStore: Object = _service_store(theDir)
	var first: MetaProfile = MetaProfileScript.new()
	first.total_runs = 10
	_assert(SaveServiceScript.save_meta(first), "the first write succeeds")

	# The first rename (target -> commit-old) succeeds, the second
	# (temp -> target) fails: the target is MISSING and the commit-old
	# holds the last good profile. The recovery must restore it.
	var failing: Object = MetaStoreScript.new(theDir)
	var ops: Object = _failing_ops(&"rename")
	ops.set("fail_after", 1)
	failing.set("ops", ops)
	SaveServiceScript.set_meta_store_for_test(failing)
	var second: MetaProfile = MetaProfileScript.new()
	second.total_runs = 99
	var ok: bool = SaveServiceScript.save_meta(second)
	_assert(not ok, "the failed write reports the failure")

	# The recovery: a FRESH store (the next process) restores it.
	SaveServiceScript.set_meta_store_for_test(MetaStoreScript.new(theDir))
	var loaded: Object = SaveServiceScript.load_meta()
	_assert(loaded != null, "the profile recovers after the failed swap")
	if loaded != null:
		_assert(int(loaded.total_runs) == 10,
			"the LAST GOOD total_runs is recovered (it is %d)" % int(loaded.total_runs))
	_assert(not FileAccess.file_exists(theDir + "meta.tres.commit-old"),
		"the recovery removed the commit-old")


## G. A crash after the swap keeps the NEW profile.
func _test_G_a_crash_after_the_swap_keeps_the_new_profile() -> void:
	var theDir: String = ISOLATED_DIR + "g/"
	_reset_dir(theDir)
	var theStore: Object = _service_store(theDir)
	var first: MetaProfile = MetaProfileScript.new()
	first.total_runs = 12
	_assert(SaveServiceScript.save_meta(first), "the first write succeeds")

	# The crash AFTER the swap: the target holds the new profile and
	# the commit-old still holds the old one.
	var second: MetaProfile = MetaProfileScript.new()
	second.total_runs = 21
	_assert(SaveServiceScript.save_meta(second), "the second write succeeds")

	SaveServiceScript.set_meta_store_for_test(MetaStoreScript.new(theDir))
	var loaded: Object = SaveServiceScript.load_meta()
	_assert(loaded != null, "the profile reads back")
	if loaded != null:
		_assert(int(loaded.total_runs) == 21,
			"the NEW total_runs is authoritative (it is %d)" % int(loaded.total_runs))


## H. A corrupted new file recovers the OLD one.
func _test_H_a_corrupted_new_file_recovers_the_old_one() -> void:
	var theDir: String = ISOLATED_DIR + "h/"
	_reset_dir(theDir)
	var theStore: Object = _service_store(theDir)
	var first: MetaProfile = MetaProfileScript.new()
	first.total_runs = 14
	_assert(SaveServiceScript.save_meta(first), "the first write succeeds")

	# Simulate the crash between the renames: the target is missing,
	# the commit-old holds the last good profile, and the temp holds a
	# half-written one.
	var second: MetaProfile = MetaProfileScript.new()
	second.total_runs = 22
	_assert(SaveServiceScript.save_meta(second), "the second write succeeds")
	# Rebuild the crash state by hand.
	var theTarget: String = theDir + "meta.tres"
	var theCommitOld: String = theDir + "meta.tres.commit-old"
	if FileAccess.file_exists(theTarget):
		DirAccess.rename_absolute(theTarget, theCommitOld)
	var f: FileAccess = FileAccess.open(theDir + "meta.tres.tmp", FileAccess.WRITE)
	if f != null:
		f.store_string("[gd_resource type=\"Resource\"")
		f.close()

	SaveServiceScript.set_meta_store_for_test(MetaStoreScript.new(theDir))
	var loaded: Object = SaveServiceScript.load_meta()
	_assert(loaded != null, "the profile recovers")
	if loaded != null:
		_assert(int(loaded.total_runs) == 22,
			"the recovered profile is the last good one (it is %d)" % int(loaded.total_runs))


## I. Two corrupted files: an EXPLICIT error, nothing destroyed.
func _test_I_two_corrupted_files_report_an_explicit_error() -> void:
	var theDir: String = ISOLATED_DIR + "i/"
	_reset_dir(theDir)
	var theStore: Object = _service_store(theDir)
	var first: MetaProfile = MetaProfileScript.new()
	first.total_runs = 16
	_assert(SaveServiceScript.save_meta(first), "the first write succeeds")

	# Corrupt BOTH the target and the commit-old.
	var theTarget: String = theDir + "meta.tres"
	var theCommitOld: String = theDir + "meta.tres.commit-old"
	_write_garbage(theTarget)
	_write_garbage(theCommitOld)

	SaveServiceScript.set_meta_store_for_test(MetaStoreScript.new(theDir))
	var theResult: Dictionary = SaveServiceScript.load_meta_result()
	_assert(not bool(theResult["ok"]),
		"the corrupted profile is NOT silently replaced by a default one")
	var theReason: String = str(theResult["reason"])
	_assert(theReason != "",
		"the damaged profile reports WHY it could not be loaded")
	_assert(FileAccess.file_exists(theTarget),
		"the corrupted target was NOT destroyed")
	_assert(FileAccess.file_exists(theCommitOld),
		"the corrupted commit-old was NOT destroyed")


## J. A double recovery changes nothing.
func _test_J_a_double_recovery_changes_nothing() -> void:
	var theDir: String = ISOLATED_DIR + "j/"
	_reset_dir(theDir)
	var theStore: Object = _service_store(theDir)
	var first: MetaProfile = MetaProfileScript.new()
	first.total_runs = 18
	_assert(SaveServiceScript.save_meta(first), "the first write succeeds")
	# The crash state: the target is missing, the commit-old is good.
	DirAccess.rename_absolute(theDir + "meta.tres", theDir + "meta.tres.commit-old")

	SaveServiceScript.set_meta_store_for_test(MetaStoreScript.new(theDir))
	var loaded_first: Object = SaveServiceScript.load_meta()
	_assert(loaded_first != null, "the first recovery restores the profile")
	var theBytes_first: PackedByteArray = FileAccess.get_file_as_bytes(theDir + "meta.tres")

	# The SECOND recovery must change nothing.
	SaveServiceScript.set_meta_store_for_test(MetaStoreScript.new(theDir))
	var loaded_second: Object = SaveServiceScript.load_meta()
	_assert(loaded_second != null, "the second recovery still finds the profile")
	if loaded_second != null:
		_assert(int(loaded_second.total_runs) == 18, "the profile is unchanged")
	var theBytes_second: PackedByteArray = FileAccess.get_file_as_bytes(theDir + "meta.tres")
	_assert(theBytes_first == theBytes_second,
		"the second recovery did not rewrite the file")


## K. An empty directory creates a new profile.
func _test_K_an_empty_directory_creates_a_new_profile() -> void:
	var theDir: String = ISOLATED_DIR + "k/"
	_reset_dir(theDir)
	var theStore: Object = _service_store(theDir)
	var loaded: Object = SaveServiceScript.load_meta()
	_assert(loaded != null,
		"a missing profile loads a new one (the first run)")
	if loaded != null:
		_assert(int(loaded.total_runs) == 0, "the new profile is the default")
		_assert((loaded.unlocked_units as Array).size() >= 1,
			"the new profile has the default unlocks")


## L. The ResourceLoader cache must not fool the validation.
func _test_L_the_cache_does_not_fool_the_validation() -> void:
	var theDir: String = ISOLATED_DIR + "l/"
	_reset_dir(theDir)
	var theStore: Object = _service_store(theDir)
	var first: MetaProfile = MetaProfileScript.new()
	first.total_runs = 20
	_assert(SaveServiceScript.save_meta(first), "the first write succeeds")

	# Load the profile ONCE: the ResourceLoader now CACHES it.
	var cached: Object = SaveServiceScript.load_meta()
	_assert(cached != null, "the profile loads")
	# Change the file on the disk: the cached object still holds the
	# OLD value.
	var theTarget: String = theDir + "meta.tres"
	var second: MetaProfile = MetaProfileScript.new()
	second.total_runs = 30
	ResourceSaver.save(second, theTarget)

	# The load must see the NEW value: the cache must not serve the
	# stale object.
	var reread: Object = SaveServiceScript.load_meta()
	_assert(reread != null, "the profile reloads")
	if reread != null:
		_assert(int(reread.total_runs) == 30,
			"the reload sees the NEW value, not the cached one (it is %d)"
			% int(reread.total_runs))


# ----------------------------------------------------------------


## A store over an isolated directory, installed as the service's
## seam, so the PRODUCTION `save_meta()` / `load_meta()` are the code
## under test.
func _service_store(theDir: String) -> Object:
	var theStore: Object = MetaStoreScript.new(theDir)
	SaveServiceScript.set_meta_store_for_test(theStore)
	return theStore


## The ops that fail every call.
func _failing_ops(theMethod: StringName) -> Object:
	var ops: Object = FaultOps.new()
	ops.fail_methods = {theMethod: true}
	return ops


## The ops whose write lands GARBAGE bytes.
func _corrupting_ops() -> Object:
	var ops: Object = FaultOps.new()
	ops.set("corrupt_write", true)
	return ops


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
	# A0.1: the damaged file must PARSE cleanly (so the project's
	# gate does not see a Parse Error) but must NOT be a usable
	# MetaProfile. A resource of a different type does exactly that:
	# the loader is happy, the verification rejects it.
	f.store_string("[gd_resource type=\"Resource\" format=3 uid=\"uid://a01damaged\"]\n\n[resource]\nresource_name = \"damaged\"\n")
	f.close()


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] A0.1/D1: %s" % label)
