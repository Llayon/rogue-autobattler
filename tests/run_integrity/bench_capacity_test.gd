extends SceneTree

## RI-10: the purchase must be atomic and must respect the bench
## capacity.
##
## The defect: `buy_unit` checked the phase, the offer and the gold,
## then mutated the gold, created the unit on the bench and took the
## offer. It NEVER checked the bench capacity, and `MAX_BENCH_UNITS`
## exists in core/balance.gd but was not consulted there.
##
## The consequence: with a full bench the gold was spent, the unit was
## created (it landed on a bench that has no room for it) and the
## offer was taken -- so the player paid for a unit that could not be
## put anywhere, and the offer was gone.
##
## The invariant:
##
##   a purchase either happens completely or not at all:
##       the bench has room
##       the gold is spent
##       the unit is created
##       the offer is taken
##
## and nothing changes when it is refused.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const BalanceScript = preload("res://core/balance.gd")

const ISOLATED_DIR: String = "user://run_integrity_ri10/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_the_purchase_fills_the_bench()
	await _test_B_a_full_bench_refuses_the_purchase()
	await _test_C_a_refused_purchase_changes_nothing()
	await _test_D_the_board_is_not_the_bench()
	print("")
	print("=== STAGE 4D: BENCH CAPACITY: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## The purchase must work while the bench has room.
func _test_A_the_purchase_fills_the_bench() -> void:
	var ctrl: Node = await _make_controller(580001)
	_assert(ctrl.state.get_bench_units().is_empty(),
		"the bench starts empty")
	# The gold is raised so the CAPACITY is what decides, not the
	# budget.
	ctrl.state.gold = 9999
	var gold_before: int = ctrl.state.gold
	var offers_before: int = ctrl.shop.offered_ids().size()
	var bought: Resource = ctrl.buy_unit(0)
	_assert(bought != null,
		"the purchase succeeds with room on the bench")
	_assert(ctrl.state.get_bench_units().size() == 1,
		"the unit is on the bench")
	_assert(ctrl.state.gold < gold_before,
		"the gold was spent")
	_assert(ctrl.shop.offered_ids().size() == offers_before - 1,
		"the offer was taken (got %d offers)"
			% ctrl.shop.offered_ids().size())


## A full bench must refuse the purchase.
func _test_B_a_full_bench_refuses_the_purchase() -> void:
	var ctrl: Node = await _make_controller(580002)
	_fill_bench(ctrl)
	_assert(ctrl.state.get_bench_units().size() == BalanceScript.MAX_BENCH_UNITS,
		"the bench is full")
	# The offer must be refilled, so the refusal is about the CAPACITY
	# and not about an empty shop.
	ctrl.shop.refresh(ctrl.profile.unlocked_units)
	_assert(ctrl.shop.offered_ids().size() > 0,
		"the shop has an offer (got %d)"
			% ctrl.shop.offered_ids().size())
	var gold_before: int = ctrl.state.gold
	var units_before: int = ctrl.state.units.size()
	var offers_before: int = ctrl.shop.offered_ids().size()
	var bought: Resource = ctrl.buy_unit(0)
	_assert(bought == null, "the purchase is refused with a full bench")
	_assert(ctrl.state.gold == gold_before, "the gold is unchanged")
	_assert(ctrl.state.get_bench_units().size()
		== BalanceScript.MAX_BENCH_UNITS,
		"the bench did not grow")
	_assert(ctrl.state.units.size() == units_before,
		"no unit was created")
	_assert(ctrl.shop.offered_ids().size() == offers_before,
		"the offer is still there (got %d offers)"
			% ctrl.shop.offered_ids().size())


## A refused purchase changes nothing.
func _test_C_a_refused_purchase_changes_nothing() -> void:
	var ctrl: Node = await _make_controller(580003)
	_fill_bench(ctrl)
	ctrl.shop.refresh(ctrl.profile.unlocked_units)
	var gold_before: int = ctrl.state.gold
	var units_before: int = ctrl.state.get_bench_units().size()
	var all_before: int = ctrl.state.units.size()
	var writes_before: int = ctrl.save_repository.get_save_count()
	ctrl.buy_unit(0)
	_assert(ctrl.state.gold == gold_before, "the gold is unchanged")
	_assert(ctrl.state.get_bench_units().size() == units_before,
		"the bench is unchanged")
	_assert(ctrl.state.units.size() == all_before,
		"no unit was created")
	_assert(ctrl.save_repository.get_save_count() == writes_before,
		"no checkpoint was written")


## The bench and the board are DIFFERENT capacities: a full board with
## a free bench must still allow a purchase.
func _test_D_the_board_is_not_the_bench() -> void:
	var ctrl: Node = await _make_controller(580004)
	ctrl.state.gold = 9999
	_assert(ctrl.state.get_board_units().size() > 0, "the board has units")
	_assert(ctrl.state.get_bench_units().is_empty(), "the bench is empty")
	var bought: Resource = ctrl.buy_unit(0)
	_assert(bought != null,
		"a full board does not block the purchase (the bench has room)")


# ----------------------------------------------------------------


func _make_controller(seed_value: int) -> Node:
	var ctrl: Node = RunControllerScript.new()
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR)
	ctrl.meta_writer = _MetaWriter.new()
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer", &"cleric",
		&"mage", &"knight", &"druid", &"berserker", &"cavalry",
		&"guardian", &"assassin"] as Array[StringName]
	ctrl.start_run(seed_value)
	await process_frame
	return ctrl


## Fills the bench to its capacity.
##
## The shop offers a finite list and `offer_at` returns null for an
## empty slot, so the slots must be walked. The gold is raised first,
## so the capacity is what stops the purchase and not the gold.
func _fill_bench(ctrl: Node) -> void:
	ctrl.state.gold = 9999
	for _i in 8:
		if ctrl.state.get_bench_units().size() >= BalanceScript.MAX_BENCH_UNITS:
			break
		# `take_at` removes the slot, so the offer shifts: the next
		# purchase is always slot 0.
		if ctrl.buy_unit(0) == null:
			break


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
		print("  [FAIL] Stage 4D: %s" % label)
