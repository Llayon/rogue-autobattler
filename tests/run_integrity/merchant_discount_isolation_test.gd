extends SceneTree

## H-02: the merchant discount must not leak between independent runs.
##
## The v5 checkpoint PERSISTS the merchant discount, so
## `restore_snapshot()` installs it. `reset_offer()` clears only the
## offer list and leaves the discount alone -- with the comment "the
## discount is the balance constant, so it stays". That comment is
## only true for a FRESH shop screen: a resumed run installs a
## non-default discount, and the next independent run inherits it.
##
## The contract:
##
##   resume an old run with discount = 0.75
##     -> the old run keeps 0.75
##   start an independent new run
##     -> the new run discount = Balance.MAP_MERCHANT_DISCOUNT (0.5)
##
## The offer order and the RNG generation of the offers must not
## change.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const BalanceScript = preload("res://core/balance.gd")

const ISOLATED_DIR: String = "user://run_integrity_h02/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_a_resumed_run_keeps_its_discount()
	await _test_B_a_new_run_gets_the_balance_discount()
	await _test_C_the_isolation_holds_across_a_resume()
	await _test_D_the_offer_order_and_the_rng_are_unchanged()
	print("")
	print("=== STAGE H02: THE MERCHANT DISCOUNT IS RUN-SCOPED: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. A resumed run keeps ITS OWN discount.
func _test_A_a_resumed_run_keeps_its_discount() -> void:
	var ctrl: Node = await _make_controller(670201)
	ctrl.merchant_shop.set_discount(0.75)
	ctrl.save_now()
	await process_frame
	var resumed: Node = await _make_controller(670202)
	var ok: bool = resumed.resume_run(670201)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(is_equal_approx(resumed.merchant_shop.get_discount(), 0.75),
		"the resumed run keeps its own discount (got %f)"
			% resumed.merchant_shop.get_discount())


## B. An independent new run gets the BALANCE discount, not the one the
## previous run left behind.
func _test_B_a_new_run_gets_the_balance_discount() -> void:
	var ctrl: Node = await _make_controller(670203)
	ctrl.merchant_shop.set_discount(0.75)
	# The new run is INDEPENDENT: a different seed, a fresh state.
	ctrl.start_run(670204)
	await process_frame
	_assert(is_equal_approx(ctrl.merchant_shop.get_discount(),
			BalanceScript.MAP_MERCHANT_DISCOUNT),
		"the new run has the balance discount (got %f, it is %f)"
			% [ctrl.merchant_shop.get_discount(),
				BalanceScript.MAP_MERCHANT_DISCOUNT])


## C. The full isolation path: resume a run with a non-default
## discount, then start an independent new run on the SAME controller.
func _test_C_the_isolation_holds_across_a_resume() -> void:
	var ctrl: Node = await _make_controller(670205)
	ctrl.merchant_shop.set_discount(0.75)
	ctrl.save_now()
	await process_frame
	var ok: bool = ctrl.resume_run(670205)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(is_equal_approx(ctrl.merchant_shop.get_discount(), 0.75),
		"the resumed run keeps the 0.75 discount")
	# The independent new run.
	ctrl.start_run(670206)
	await process_frame
	_assert(is_equal_approx(ctrl.merchant_shop.get_discount(),
			BalanceScript.MAP_MERCHANT_DISCOUNT),
		"the new run after the resume has the balance discount (got %f)"
			% ctrl.merchant_shop.get_discount())


## D. The offer order and the RNG generation are unchanged: two
## controllers with the same seed produce the same offer list.
func _test_D_the_offer_order_and_the_rng_are_unchanged() -> void:
	var first: Node = await _make_controller(670207)
	var second: Node = await _make_controller(670207)
	_assert(_offer_signature(first) == _offer_signature(second),
		"two runs with the same seed produce the same merchant offer")
	_assert(is_equal_approx(first.merchant_shop.get_discount(),
			second.merchant_shop.get_discount()),
		"two runs with the same seed have the same discount")


# ----------------------------------------------------------------


func _offer_signature(ctrl: Node) -> String:
	var parts: Array[String] = []
	for i in ctrl.merchant_shop.get_offered_count():
		parts.append(str(ctrl.merchant_shop.get_item_id(i)))
	return "|".join(parts)


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

	func write_meta(profile: Object) -> bool:
		return true


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage H02: %s" % label)
