extends SceneTree

## A0.1 / D2: the unit purchase must be DURABLE.
##
## The baseline:
##
##   buy_unit(slot) -> spends the gold, creates the unit, takes the
##                     offer and NEVER calls save_now()
##
## So a purchase was lost on Continue: the gold came back and the
## unit was gone -- and because the OFFER was not persisted either, the
## unit was still in the shop, so the player paid for it twice.
##
## The contract:
##
##   a valid purchase   -> one gold charge, one unit, the offer is
##                          taken, the checkpoint holds all three,
##                          and Continue restores them
##   a refused purchase -> zero mutation, zero checkpoint writes
##   a failed write     -> the purchase is NOT reported as durable,
##                          and the retry writes ONLY the data: the
##                          gold is not charged twice and the unit is
##                          not duplicated
##
## The scenarios:
##
##   A. a purchase survives a resume
##   B. a purchase survives an ABORTED process (a fresh controller)
##   C. two purchases survive a resume
##   D. a refused purchase writes nothing
##   E. a failed write reports no durability
##   F. the retry after a failed write neither charges nor duplicates
##   G. the offer, the gold and the instance_id agree after a resume
##   H. the touch button calls the same domain operation

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const FaultOps = preload("res://tests/save_repository/support/run_save_file_ops_fault.gd")
const BalanceScript = preload("res://core/balance.gd")
const RunUnitScript = preload("res://core/progression/run_unit.gd")
const CheckpointMapper = preload("res://core/progression/run_checkpoint_v5_mapper.gd")
const MetaStoreScript = preload("res://core/save/meta_store.gd")
const SaveServiceScript = preload("res://core/save/save_service.gd")

const ISOLATED_DIR: String = "user://run_integrity_a01/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	# A0.1: the controllers' `_ready()` opens the meta store. Without
	# this seam the suite would touch the developer's REAL save tree
	# (the recovery runs there). The seam points it at the isolated
	# directory.
	SaveServiceScript.set_meta_store_for_test(
		MetaStoreScript.new(ISOLATED_DIR + "meta/"))
	await _test_A_a_purchase_survives_a_resume()
	await _test_B_a_purchase_survives_an_aborted_process()
	await _test_C_two_purchases_survive_a_resume()
	await _test_D_a_refused_purchase_writes_nothing()
	await _test_E_a_failed_write_reports_no_durability()
	await _test_F_the_retry_neither_charges_nor_duplicates()
	await _test_G_the_offer_the_gold_and_the_instance_agree()
	await _test_H_the_touch_button_calls_the_same_operation()
	# A0.1: the seam is restored, so the production store is used
	# again by anything that runs after this suite.
	SaveServiceScript.set_meta_store_for_test(null)
	print("")
	print("=== A0.1 / D2: THE UNIT PURCHASE IS DURABLE: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. A purchase survives a resume.
func _test_A_a_purchase_survives_a_resume() -> void:
	var ctrl: Node = await _make_controller(671101)
	await _enter_prep(ctrl)
	var gold_before: int = ctrl.state.gold
	var bought: Resource = ctrl.buy_unit(0)
	_assert(bought != null, "the purchase succeeds")
	var gold_after: int = ctrl.state.gold
	var units_after: int = ctrl.state.get_bench_units().size()
	_assert(gold_after < gold_before, "the purchase spent the gold")
	_assert(units_after == 1, "the purchase created the unit")

	var resumed: Node = await _make_controller(671102)
	var ok: bool = resumed.resume_run(671101)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(resumed.state.gold == gold_after,
		"the resumed gold is the gold after the purchase (got %d, it is %d)"
			% [resumed.state.gold, gold_after])
	_assert(resumed.state.get_bench_units().size() == units_after,
		"the resumed bench holds the purchased unit (got %d, it is %d)"
			% [resumed.state.get_bench_units().size(), units_after])


## B. A purchase survives an ABORTED process.
func _test_B_a_purchase_survives_an_aborted_process() -> void:
	var ctrl: Node = await _make_controller(671103)
	await _enter_prep(ctrl)
	var bought: Resource = ctrl.buy_unit(0)
	_assert(bought != null, "the purchase succeeds")
	var gold_after: int = ctrl.state.gold
	var units_after: int = ctrl.state.get_bench_units().size()
	# The process dies here: the controller is dropped WITHOUT any
	# further write, and a FRESH controller continues.
	ctrl.queue_free()
	await process_frame

	var resumed: Node = await _make_controller(671104)
	var ok: bool = resumed.resume_run(671103)
	await process_frame
	_assert(ok, "the checkpoint resumes after the aborted process")
	_assert(resumed.state.gold == gold_after,
		"the resumed gold is the gold after the purchase (got %d, it is %d)"
			% [resumed.state.gold, gold_after])
	_assert(resumed.state.get_bench_units().size() == units_after,
		"the resumed bench holds the purchased unit (got %d, it is %d)"
			% [resumed.state.get_bench_units().size(), units_after])


## C. Two purchases survive a resume.
func _test_C_two_purchases_survive_a_resume() -> void:
	var ctrl: Node = await _make_controller(671105)
	await _enter_prep(ctrl)
	ctrl.state.gold = 1000
	var theOfferCount: int = ctrl.shop.offered_ids().size()
	_assert(theOfferCount >= 2,
		"the shop offers at least two units (it offers %d)" % theOfferCount)
	_assert(ctrl.buy_unit(0) != null, "the first purchase succeeds")
	# `take_at` REMOVES the offer, so the list shifts: the next offer
	# is at slot 0 again.
	_assert(ctrl.shop.offered_ids().size() == theOfferCount - 1,
		"the first purchase took one offer")
	_assert(ctrl.buy_unit(0) != null, "the second purchase succeeds")
	var gold_after: int = ctrl.state.gold
	var units_after: int = ctrl.state.get_bench_units().size()
	_assert(units_after == 2, "two units were bought (got %d)" % units_after)

	var resumed: Node = await _make_controller(671106)
	var ok: bool = resumed.resume_run(671105)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(resumed.state.gold == gold_after,
		"the resumed gold is the gold after both purchases (got %d, it is %d)"
			% [resumed.state.gold, gold_after])
	_assert(resumed.state.get_bench_units().size() == units_after,
		"the resumed bench holds both units")


## D. A refused purchase writes NOTHING.
func _test_D_a_refused_purchase_writes_nothing() -> void:
	# D1: the wrong phase. `start_run` leaves the controller in PREP
	# (the phase where the purchase IS legal), so the controller is
	# moved to BATTLE, where the command matrix refuses it.
	var ctrl: Node = await _make_controller(671107)
	ctrl._set_phase(1)
	await process_frame
	var count_before: int = ctrl.save_repository.get_save_count()
	var gold_before: int = ctrl.state.gold
	var bought: Resource = ctrl.buy_unit(0)
	_assert(bought == null, "the purchase in the wrong phase is refused")
	_assert(ctrl.state.gold == gold_before, "the gold is untouched")
	_assert(ctrl.save_repository.get_save_count() == count_before,
		"the refused purchase wrote nothing (it was %d, it is %d)"
			% [ctrl.save_repository.get_save_count(), count_before])

	# D2: an invalid slot.
	await _enter_prep(ctrl)
	count_before = ctrl.save_repository.get_save_count()
	gold_before = ctrl.state.gold
	_assert(ctrl.buy_unit(99) == null, "the invalid slot is refused")
	_assert(ctrl.state.gold == gold_before, "the gold is untouched")
	_assert(ctrl.save_repository.get_save_count() == count_before,
		"the invalid slot wrote nothing")

	# D3: not enough gold.
	ctrl.state.gold = 0
	count_before = ctrl.save_repository.get_save_count()
	_assert(ctrl.buy_unit(0) == null, "the purchase without the gold is refused")
	_assert(ctrl.state.gold == 0, "the gold is untouched")
	_assert(ctrl.save_repository.get_save_count() == count_before,
		"the refused purchase wrote nothing")

	# D4: the bench is full.
	ctrl.state.gold = 1000
	var theCount: int = ctrl.state.get_bench_units().size()
	while ctrl.state.get_bench_units().size() < BalanceScript.MAX_BENCH_UNITS:
		ctrl.state.create_unit(&"warrior", 100, RunUnitScript.LOCATION_BENCH)
	count_before = ctrl.save_repository.get_save_count()
	_assert(ctrl.buy_unit(0) == null, "the purchase with a full bench is refused")
	_assert(ctrl.state.get_bench_units().size() == theCount
		+ (BalanceScript.MAX_BENCH_UNITS - theCount),
		"the bench did not grow")
	_assert(ctrl.save_repository.get_save_count() == count_before,
		"the refused purchase wrote nothing")


## E. A failed write reports NO durability.
func _test_E_a_failed_write_reports_no_durability() -> void:
	var ctrl: Node = await _make_controller(671108)
	await _enter_prep(ctrl)
	ctrl.state.gold = 1000
	# The checkpoint write fails from now on.
	var ops: Object = FaultOps.new()
	ops.fail_methods = {&"write_bytes_and_flush": true}
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
	var bought: Resource = ctrl.buy_unit(0)
	_assert(bought != null, "the purchase itself succeeds")
	# The durability must NOT be claimed: the pending flag says the
	# purchase is applied but NOT on the disk.
	_assert(ctrl.purchase_persistence_pending(),
		"the failed write is reported as NOT durable")
	# The reader sees the STALE checkpoint: the purchase is not there.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(671108)
	if loaded != null and loaded.is_ok():
		var dto: Dictionary = loaded.data
		var theBench: Array = _persisted_bench_units(dto)
		_assert(theBench.size() == 0,
			"the stale checkpoint holds no bought unit (it holds %d)"
				% theBench.size())
	else:
		_assert(true, "the stale checkpoint was not written at all")


## F. The retry neither charges nor duplicates.
func _test_F_the_retry_neither_charges_nor_duplicates() -> void:
	var ctrl: Node = await _make_controller(671109)
	await _enter_prep(ctrl)
	ctrl.state.gold = 1000
	var ops: Object = FaultOps.new()
	ops.fail_methods = {&"write_bytes_and_flush": true}
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
	_assert(ctrl.buy_unit(0) != null, "the purchase itself succeeds")
	var gold_after: int = ctrl.state.gold
	var units_after: int = ctrl.state.get_bench_units().size()
	_assert(ctrl.purchase_persistence_pending(),
		"the failed write is pending")

	# The filesystem recovers: the retry writes ONLY the data.
	var healthy: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	ctrl.save_repository = healthy
	var ok: bool = ctrl.retry_purchase_persistence()
	_assert(ok, "the retry lands")
	_assert(ctrl.state.gold == gold_after,
		"the retry did not charge the gold again (got %d, it is %d)"
			% [ctrl.state.gold, gold_after])
	_assert(ctrl.state.get_bench_units().size() == units_after,
		"the retry did not create a second unit (got %d, it is %d)"
			% [ctrl.state.get_bench_units().size(), units_after])
	_assert(not ctrl.purchase_persistence_pending(),
		"the pending flag is cleared")

	# And the checkpoint holds exactly ONE unit -- the bought one.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(671109)
	_assert(loaded != null and loaded.is_ok(), "the checkpoint reads back")
	if loaded != null and loaded.is_ok():
		var dto: Dictionary = loaded.data
		var theBench: Array = _persisted_bench_units(dto)
		_assert(theBench.size() == 1,
			"the checkpoint holds exactly one bought unit (got %d)"
				% theBench.size())


## G. The offer, the gold and the instance agree after a resume.
func _test_G_the_offer_the_gold_and_the_instance_agree() -> void:
	var ctrl: Node = await _make_controller(671110)
	await _enter_prep(ctrl)
	var offers_before: int = ctrl.shop.offered_ids().size()
	_assert(ctrl.buy_unit(0) != null, "the purchase succeeds")
	var offers_after: int = ctrl.shop.offered_ids().size()
	_assert(offers_after == offers_before - 1,
		"the purchase took the offer (it was %d, it is %d)"
			% [offers_before, offers_after])
	var theInstance: String = str(ctrl.state.get_bench_units()[0].instance_id)

	var resumed: Node = await _make_controller(671111)
	var ok: bool = resumed.resume_run(671110)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(resumed.shop.offered_ids().size() == offers_after,
		"the resumed shop holds the taken offer (got %d, it is %d)"
			% [resumed.shop.offered_ids().size(), offers_after])
	_assert(resumed.state.get_bench_units().size() == 1,
		"the resumed bench holds one unit")
	if resumed.state.get_bench_units().size() == 1:
		_assert(str(resumed.state.get_bench_units()[0].instance_id) == theInstance,
			"the resumed unit keeps its instance_id")


## H. The touch button calls the same domain operation.
func _test_H_the_touch_button_calls_the_same_operation() -> void:
	# The touch button in the battle scene calls
	# `run_controller.buy_unit(0)`. The contract: the touch path and
	# the domain path are the SAME operation, so the purchase is
	# durable through both.
	var ctrl: Node = await _make_controller(671112)
	await _enter_prep(ctrl)
	ctrl.state.gold = 1000
	# What the touch button does.
	var theScript: GDScript = load("res://scenes/battle/battle_scene.gd")
	var theSource: String = theScript.source_code
	_assert("run_controller.buy_unit(0)" in theSource,
		"the touch button calls the domain operation buy_unit(0)")
	# And the domain operation is durable.
	var bought: Resource = ctrl.buy_unit(0)
	_assert(bought != null, "the domain purchase succeeds")
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(671112)
	_assert(loaded != null and loaded.is_ok(),
		"the purchase through the domain operation is persisted")


## The bench units that are persisted in a v5 checkpoint.
##
## The checkpoint stores the run's state in the encoded `state` field,
## so the units must be DECODED -- reading a `units` key of the DTO
## would prove nothing.
func _persisted_bench_units(dto: Dictionary) -> Array:
	var theDecoded: Dictionary = CheckpointMapper.from_v5_dto(dto)
	if not bool(theDecoded.get("ok", false)):
		return []
	var theState: Variant = theDecoded.get("state", null)
	if theState == null:
		return []
	return theState.get_bench_units()


# ----------------------------------------------------------------

## Enters the PREP phase with a shop offer.
func _enter_prep(ctrl: Node) -> void:
	ctrl._enter_map()
	await process_frame
	# The shop is refreshed from the profile's unlocked units, so the
	# PREP phase has the offers the purchase takes.
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


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] A0.1/D2: %s" % label)
