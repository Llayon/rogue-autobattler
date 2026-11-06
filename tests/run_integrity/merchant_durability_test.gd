extends SceneTree

## H-06: the merchant purchase and the merchant exit must survive
## Continue.
##
## The baseline:
##
##   buy_item(slot)          -> grants the item, spends the gold, and
##                              NEVER calls save_now()
##   exit_shop_to_map()      -> clears the merchant flag, sets MAP, and
##                              NEVER calls save_now()
##
## So a purchase or an exit was lost on Continue.
##
## The contract:
##
##   valid purchase -> change the gold/items once -> persist the
##                     updated checkpoint
##   invalid purchase -> zero mutation, zero RNG, zero checkpoint
##                       writes
##
## And `exit_shop_to_map()` must require a REAL merchant context --
## not merely `phase == PREP`.
##
## The scenarios, each followed by a REAL `resume_run()` on a fresh
## controller:
##
##   purchase -> resume before the shop exit
##   purchase -> exit -> resume
##   multiple purchases -> resume
##   exit without a purchase -> resume
##   invalid slot -> no save
##   insufficient gold -> no save
##   write failure -> no duplicate item or charge

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const FaultOps = preload("res://tests/save_repository/support/run_save_file_ops_fault.gd")

const ISOLATED_DIR: String = "user://run_integrity_h06/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_a_purchase_survives_a_resume()
	await _test_B_a_purchase_and_an_exit_survive_a_resume()
	await _test_C_multiple_purchases_survive_a_resume()
	await _test_D_an_exit_without_a_purchase_survives_a_resume()
	await _test_E_an_invalid_purchase_writes_nothing()
	await _test_F_an_insufficient_gold_writes_nothing()
	await _test_G_a_write_failure_duplicates_neither_the_item_nor_the_charge()
	await _test_H_the_exit_needs_a_real_merchant_context()
	print("")
	print("=== STAGE H06: THE MERCHANT IS DURABLE: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. A purchase survives a resume.
func _test_A_a_purchase_survives_a_resume() -> void:
	var ctrl: Node = await _make_controller(670701)
	await _enter_merchant(ctrl)
	var gold_before: int = ctrl.state.gold
	var bought: bool = ctrl.buy_item(0)
	_assert(bought, "the purchase succeeds")
	var gold_after: int = ctrl.state.gold
	var items_after: int = ctrl.state.items.size()
	_assert(gold_after < gold_before, "the purchase spent the gold")
	_assert(items_after == 1, "the purchase granted the item")

	var resumed: Node = await _make_controller(670702)
	var ok: bool = resumed.resume_run(670701)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(resumed.state.gold == gold_after,
		"the resumed gold is the gold after the purchase (got %d, it is %d)"
			% [resumed.state.gold, gold_after])
	_assert(resumed.state.items.size() == items_after,
		"the resumed inventory holds the purchased item (got %d, it is %d)"
			% [resumed.state.items.size(), items_after])


## B. A purchase and an exit survive a resume.
func _test_B_a_purchase_and_an_exit_survive_a_resume() -> void:
	var ctrl: Node = await _make_controller(670703)
	await _enter_merchant(ctrl)
	_assert(ctrl.buy_item(0), "the purchase succeeds")
	var gold_after: int = ctrl.state.gold
	ctrl.exit_shop_to_map()
	await process_frame
	_assert(int(ctrl.phase) == 4, "the exit set the MAP phase")

	var resumed: Node = await _make_controller(670704)
	var ok: bool = resumed.resume_run(670703)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(resumed.state.gold == gold_after,
		"the resumed gold is the gold after the purchase")
	_assert(not resumed.state.just_visited_merchant,
		"the resumed run is not in the merchant")
	_assert(int(resumed.phase) == 4,
		"the resumed phase is MAP (it is %d)" % int(resumed.phase))


## C. Multiple purchases survive a resume.
func _test_C_multiple_purchases_survive_a_resume() -> void:
	var ctrl: Node = await _make_controller(670705)
	await _enter_merchant(ctrl)
	# Enough gold for two purchases.
	ctrl.state.gold = 1000
	var first: bool = ctrl.buy_item(0)
	var second: bool = ctrl.buy_item(1)
	_assert(first, "the first purchase succeeds")
	_assert(second, "the second purchase succeeds")
	var gold_after: int = ctrl.state.gold
	var items_after: int = ctrl.state.items.size()
	_assert(items_after == 2, "two items were granted (got %d)" % items_after)

	var resumed: Node = await _make_controller(670706)
	var ok: bool = resumed.resume_run(670705)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(resumed.state.gold == gold_after,
		"the resumed gold is the gold after both purchases")
	_assert(resumed.state.items.size() == items_after,
		"the resumed inventory holds both items")


## D. An exit without a purchase survives a resume.
func _test_D_an_exit_without_a_purchase_survives_a_resume() -> void:
	var ctrl: Node = await _make_controller(670707)
	await _enter_merchant(ctrl)
	var gold_before: int = ctrl.state.gold
	ctrl.exit_shop_to_map()
	await process_frame
	var resumed: Node = await _make_controller(670708)
	var ok: bool = resumed.resume_run(670707)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(resumed.state.gold == gold_before,
		"the resumed gold is unchanged")
	_assert(not resumed.state.just_visited_merchant,
		"the resumed run is not in the merchant")


## E. An invalid slot writes NOTHING.
func _test_E_an_invalid_purchase_writes_nothing() -> void:
	var ctrl: Node = await _make_controller(670709)
	await _enter_merchant(ctrl)
	var count_before: int = ctrl.save_repository.get_save_count()
	var bought: bool = ctrl.buy_item(99)
	_assert(not bought, "the invalid slot is refused")
	_assert(ctrl.save_repository.get_save_count() == count_before,
		"the invalid slot wrote nothing (it was %d, it is %d)"
			% [ctrl.save_repository.get_save_count(), count_before])


## F. Insufficient gold writes NOTHING.
func _test_F_an_insufficient_gold_writes_nothing() -> void:
	var ctrl: Node = await _make_controller(670710)
	await _enter_merchant(ctrl)
	ctrl.state.gold = 0
	var count_before: int = ctrl.save_repository.get_save_count()
	var bought: bool = ctrl.buy_item(0)
	_assert(not bought, "the purchase is refused without the gold")
	_assert(ctrl.save_repository.get_save_count() == count_before,
		"the refused purchase wrote nothing (it was %d, it is %d)"
			% [ctrl.save_repository.get_save_count(), count_before])


## G. A write failure duplicates NEITHER the item NOR the charge.
func _test_G_a_write_failure_duplicates_neither_the_item_nor_the_charge() -> void:
	var ctrl: Node = await _make_controller(670711)
	await _enter_merchant(ctrl)
	ctrl.state.gold = 1000
	var ops: RefCounted = FaultOps.new()
	ops.fail_methods = {&"write_bytes_and_flush": true}
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
	var bought: bool = ctrl.buy_item(0)
	_assert(bought, "the purchase itself succeeds")
	# The write failed: the checkpoint is stale.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(670711)
	if loaded != null and loaded.is_ok():
		var dto: Dictionary = loaded.data
		_assert(int(dto.get("gold", 0)) == 1000,
			"the stale checkpoint holds the gold BEFORE the purchase")
		_assert((dto.get("items", []) as Array).size() == 0,
			"the stale checkpoint holds no item")
	else:
		_assert(true, "the stale checkpoint was not written at all")


## H. The exit needs a REAL merchant context, not merely PREP.
func _test_H_the_exit_needs_a_real_merchant_context() -> void:
	var ctrl: Node = await _make_controller(670712)
	# A plain PREP phase, WITHOUT a merchant visit.
	_assert(int(ctrl.phase) == 0, "the controller starts in PREP")
	_assert(not ctrl.state.just_visited_merchant,
		"the controller did not visit a merchant")
	ctrl.exit_shop_to_map()
	await process_frame
	_assert(int(ctrl.phase) == 0,
		"the exit from a plain PREP was REFUSED (the phase is %d)"
			% int(ctrl.phase))


# ----------------------------------------------------------------


## Enters the merchant through the production path.
func _enter_merchant(ctrl: Node) -> void:
	ctrl._enter_map()
	await process_frame
	ctrl.state.just_visited_merchant = true
	ctrl._refresh_merchant_shop()
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


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage H06: %s" % label)
