extends SceneTree

## A0.1: the CHECKPOINT and the META PUBLICATION are retried apart.
##
## The reviewer's point: when the checkpoint landed but the meta
## pointer did not, the checkpoint IS ALREADY DURABLE. Repeating the
## whole commit for that case creates a needless new checkpoint
## generation -- the existing `retry_meta_publication()` publishes
## ONLY the pointer.
##
## The contract:
##
##   checkpoint failed + meta failed -> the retry writes BOTH again
##   checkpoint landed + meta failed -> the retry publishes ONLY the
##                                     meta pointer, and the
##                                     checkpoint is NOT rewritten
##
## The scenario the reviewer named:
##
##   buy_unit -> checkpoint committed -> meta failure -> retry meta
##   only -> Continue
##
## and it must hold: no second gold charge, no second unit, and the
## checkpoint on the disk is not damaged.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaStoreScript = preload("res://core/save/meta_store.gd")
const SaveServiceScript = preload("res://core/save/save_service.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const FaultOps = preload("res://tests/save_repository/support/run_save_file_ops_fault.gd")

const ISOLATED_DIR: String = "user://run_integrity_a01_split/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	SaveServiceScript.set_meta_store_for_test(
		MetaStoreScript.new(ISOLATED_DIR + "meta/"))
	await _test_A_a_meta_only_retry_does_not_rewrite_the_checkpoint()
	await _test_B_a_full_failure_retries_both()
	await _test_C_the_continue_after_a_meta_only_retry()
	await _test_D_the_checkpoint_generation_is_not_bumped()
	print("")
	print("=== A0.1: THE CHECKPOINT AND THE META RETRY APART: %d pass / %d fail ==="
		% [_passed, _failed])
	SaveServiceScript.set_meta_store_for_test(null)
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. A meta-only retry does NOT rewrite the checkpoint.
func _test_A_a_meta_only_retry_does_not_rewrite_the_checkpoint() -> void:
	var ctrl: Node = await _make_controller(671301)
	await _enter_prep(ctrl)
	ctrl.state.gold = 1000
	# The checkpoint lands, the META fails: a partial success.
	ctrl.meta_writer = _FailingMetaWriter.new()
	var bought: Resource = ctrl.buy_unit(0)
	_assert(bought != null, "the purchase itself succeeds")
	_assert(ctrl.purchase_persistence_pending(),
		"the partial success is pending")

	var theCountBefore: int = ctrl.save_repository.get_save_count()
	# The meta recovers.
	ctrl.meta_writer = _HealthyMetaWriter.new()
	var ok: bool = ctrl.retry_purchase_persistence()
	_assert(ok, "the retry lands")
	_assert(ctrl.save_repository.get_save_count() == theCountBefore,
		"the retry did NOT write a new checkpoint generation (it was %d, it is %d)"
			% [ctrl.save_repository.get_save_count(), theCountBefore])
	_assert(not ctrl.purchase_persistence_pending(),
		"the pending flag is cleared")
	ctrl.queue_free()
	await process_frame


## B. A full failure retries BOTH.
func _test_B_a_full_failure_retries_both() -> void:
	var ctrl: Node = await _make_controller(671302)
	await _enter_prep(ctrl)
	ctrl.state.gold = 1000
	# The CHECKPOINT fails.
	var ops: Object = FaultOps.new()
	ops.fail_methods = {&"write_bytes_and_flush": true}
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
	_assert(ctrl.buy_unit(0) != null, "the purchase itself succeeds")
	_assert(ctrl.purchase_persistence_pending(),
		"the failed checkpoint is pending")
	var theCountBefore: int = ctrl.save_repository.get_save_count()

	# The filesystem recovers.
	var healthy: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	ctrl.save_repository = healthy
	var ok: bool = ctrl.retry_purchase_persistence()
	_assert(ok, "the retry lands")
	_assert(ctrl.save_repository.get_save_count() > theCountBefore,
		"the retry DID write the checkpoint (it was %d, it is %d)"
			% [ctrl.save_repository.get_save_count(), theCountBefore])
	_assert(not ctrl.purchase_persistence_pending(),
		"the pending flag is cleared")
	ctrl.queue_free()
	await process_frame


## C. The Continue after a meta-only retry.
func _test_C_the_continue_after_a_meta_only_retry() -> void:
	var ctrl: Node = await _make_controller(671303)
	await _enter_prep(ctrl)
	ctrl.state.gold = 1000
	ctrl.meta_writer = _FailingMetaWriter.new()
	_assert(ctrl.buy_unit(0) != null, "the purchase itself succeeds")
	var theGold: int = ctrl.state.gold
	var theUnits: int = ctrl.state.get_bench_units().size()

	# The meta recovers: the retry publishes ONLY the pointer.
	ctrl.meta_writer = _HealthyMetaWriter.new()
	_assert(ctrl.retry_purchase_persistence(), "the retry lands")

	# The purchase must NOT be charged or duplicated by the retry.
	_assert(ctrl.state.gold == theGold,
		"the retry did not charge the gold again (got %d, it is %d)"
			% [ctrl.state.gold, theGold])
	_assert(ctrl.state.get_bench_units().size() == theUnits,
		"the retry did not create a second unit (got %d, it is %d)"
			% [ctrl.state.get_bench_units().size(), theUnits])

	# And Continue restores the purchase.
	var resumed: Node = await _make_controller(671304)
	var ok: bool = resumed.resume_run(671303)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(resumed.state.gold == theGold,
		"the resumed gold is the gold after the purchase (got %d, it is %d)"
			% [resumed.state.gold, theGold])
	_assert(resumed.state.get_bench_units().size() == theUnits,
		"the resumed bench holds the purchased unit (got %d, it is %d)"
			% [resumed.state.get_bench_units().size(), theUnits])
	ctrl.queue_free()
	await process_frame


## D. The checkpoint generation is NOT bumped by a meta-only retry.
func _test_D_the_checkpoint_generation_is_not_bumped() -> void:
	var ctrl: Node = await _make_controller(671305)
	await _enter_prep(ctrl)
	ctrl.state.gold = 1000
	ctrl.meta_writer = _FailingMetaWriter.new()
	_assert(ctrl.buy_unit(0) != null, "the purchase itself succeeds")

	# The checkpoint's BYTES before the meta-only retry.
	var thePath: String = ISOLATED_DIR + "run_671305.tres"
	var theBytesBefore: PackedByteArray = FileAccess.get_file_as_bytes(thePath)
	_assert(theBytesBefore.size() > 0, "the checkpoint is on the disk")

	ctrl.meta_writer = _HealthyMetaWriter.new()
	_assert(ctrl.retry_purchase_persistence(), "the retry lands")
	var theBytesAfter: PackedByteArray = FileAccess.get_file_as_bytes(thePath)
	_assert(theBytesBefore == theBytesAfter,
		"the checkpoint's bytes are UNCHANGED by the meta-only retry")
	ctrl.queue_free()
	await process_frame


# ----------------------------------------------------------------


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
	ctrl.meta_writer = _HealthyMetaWriter.new()
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]
	ctrl.start_run(seed_value)
	await process_frame
	return ctrl


## A meta writer that always fails.
class _FailingMetaWriter:
	extends RefCounted

	var writes: int = 0

	func write_meta(profile: Object) -> bool:
		writes += 1
		return false


## A meta writer that always succeeds.
class _HealthyMetaWriter:
	extends RefCounted

	var writes: int = 0

	func write_meta(profile: Object) -> bool:
		writes += 1
		return true


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] A0.1/split: %s" % label)
