extends SceneTree

## RI-09: every public mutation command has an explicit allowed-phase
## set, and a wrong phase fails closed with ZERO mutation.
##
## The invariant:
##
##   wrong phase:
##       return failure
##       no gold change
##       no inventory change
##       no unit change
##       no map/reward change
##       no RNG draw
##       no event emission
##       no save side effect
##
## The matrix is `docs/ri09_command_phase_matrix.md`. The commands that
## had NO guard at all are the ones this pins:
##
##   board_to_bench, bench_to_board, swap_board_units,
##   swap_units_by_id, board_to_bench_by_id, bench_to_board_by_id,
##   equip_item_by_id, unequip_item_by_id, move_to_board, grant_item,
##   remove_item_at, equip_item_at, unequip_item_at
##
## The exploitable case: `buy_item` spent the gold and granted the
## item in ANY phase, including during a battle.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const RngServiceScript = preload("res://core/utils/rng_service.gd")

const ISOLATED_DIR: String = "user://run_integrity_ri09/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_the_board_commands_fail_closed_in_battle()
	await _test_B_the_gold_commands_fail_closed_in_battle()
	await _test_C_the_inventory_commands_fail_closed_in_battle()
	await _test_D_the_commands_still_work_in_the_allowed_phase()
	await _test_E_a_refusal_mutates_nothing()
	print("")
	print("=== STAGE 4C: COMMAND PHASE GUARDS: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## The board commands must fail closed during a battle.
func _test_A_the_board_commands_fail_closed_in_battle() -> void:
	var ctrl: Node = await _make_controller(570001)
	await _start_battle(ctrl)
	_assert(ctrl.phase == ctrl.Phase.BATTLE, "the run is in a battle")
	var before: Dictionary = _snapshot(ctrl)
	_assert(not ctrl.board_to_bench(0), "board_to_bench fails in a battle")
	_assert(not ctrl.bench_to_board(0), "bench_to_board fails in a battle")
	_assert(not ctrl.swap_board_units(0, 1), "swap_board_units fails in a battle")
	_assert(not ctrl.swap_units_by_id(_unit_id(ctrl, 0), _unit_id(ctrl, 1)),
		"swap_units_by_id fails in a battle")
	_assert(not ctrl.board_to_bench_by_id(_unit_id(ctrl, 0)),
		"board_to_bench_by_id fails in a battle")
	_assert(not ctrl.bench_to_board_by_id(_unit_id(ctrl, 0)),
		"bench_to_board_by_id fails in a battle")
	_assert(not ctrl.move_to_board(0, Vector2i.ZERO),
		"move_to_board fails in a battle")
	_assert(_unchanged(ctrl, before), "the board commands mutated nothing")


## The gold commands must fail closed during a battle.
func _test_B_the_gold_commands_fail_closed_in_battle() -> void:
	var ctrl: Node = await _make_controller(570002)
	await _start_battle(ctrl)
	var before: Dictionary = _snapshot(ctrl)
	_assert(ctrl.buy_unit(0) == null, "buy_unit fails in a battle")
	_assert(not ctrl.buy_item(0), "buy_item fails in a battle")
	_assert(_unchanged(ctrl, before), "the gold commands mutated nothing")


## The inventory commands must fail closed during a battle.
func _test_C_the_inventory_commands_fail_closed_in_battle() -> void:
	var ctrl: Node = await _make_controller(570003)
	await _start_battle(ctrl)
	var before: Dictionary = _snapshot(ctrl)
	_assert(not ctrl.grant_item(&"potion_strength"), "grant_item fails in a battle")
	_assert(not ctrl.remove_item_at(0), "remove_item_at fails in a battle")
	_assert(not ctrl.equip_item_at(0, 0), "equip_item_at fails in a battle")
	_assert(not ctrl.unequip_item_at(0), "unequip_item_at fails in a battle")
	_assert(_unchanged(ctrl, before), "the inventory commands mutated nothing")


## The guards must not break the legal flows: the board commands work
## in PREP, and the equipment commands work in every live phase (the
## inventory overlay is reachable in any phase, and the equipment is
## read only at the start of a battle).
func _test_D_the_commands_still_work_in_the_allowed_phase() -> void:
	var ctrl: Node = await _make_controller(570004)
	_assert(ctrl.phase == ctrl.Phase.PREP, "the run starts in PREP")
	var moved_id: String = _unit_id(ctrl, 0)
	_assert(ctrl.board_to_bench_by_id(moved_id),
		"board_to_bench_by_id works in PREP")
	_assert(ctrl.bench_to_board_by_id(moved_id),
		"bench_to_board_by_id works in PREP")
	_assert(ctrl.swap_units_by_id(_unit_id(ctrl, 0), _unit_id(ctrl, 1)),
		"swap_units_by_id works in PREP")
	_assert(ctrl.grant_item(&"potion_strength"),
		"grant_item works in PREP")
	var item_id: String = _first_item_id(ctrl)
	_assert(item_id != "", "the granted item has an instance id")
	_assert(ctrl.equip_item_by_id(item_id, _unit_id(ctrl, 0)),
		"equip_item_by_id works in PREP")

	# The equipment is legal in a battle too: the bonuses are read at
	# the start of the battle, so the change applies to the next one.
	var ctrl2: Node = await _make_controller(570005)
	ctrl2.grant_item(&"potion_strength")
	var item_id2: String = _first_item_id(ctrl2)
	await _start_battle(ctrl2)
	_assert(ctrl2.equip_item_by_id(item_id2, _unit_id(ctrl2, 0)),
		"equip_item_by_id works in a battle (the overlay is reachable)")


## A refusal must change NOTHING: no gold, no inventory, no unit, no
## stream position, no save.
func _test_E_a_refusal_mutates_nothing() -> void:
	var ctrl: Node = await _make_controller(570006)
	await _start_battle(ctrl)
	var before: Dictionary = _snapshot(ctrl)
	var writes_before: int = ctrl.save_repository.get_save_count()
	var stream_before: Dictionary = RngServiceScript.snapshot()
	ctrl.grant_item(&"potion_strength")
	ctrl.buy_item(0)
	ctrl.board_to_bench(0)
	ctrl.swap_board_units(0, 1)
	ctrl.remove_item_at(0)
	var after: Dictionary = _snapshot(ctrl)
	_assert(after.get("gold") == before.get("gold"), "the gold is unchanged")
	_assert(after.get("items") == before.get("items"),
		"the inventory is unchanged")
	_assert(after.get("board") == before.get("board"), "the board is unchanged")
	_assert(ctrl.save_repository.get_save_count() == writes_before,
		"a refusal writes no checkpoint")
	var stream_after: Dictionary = RngServiceScript.snapshot()
	_assert(int(stream_after.get("state", 0)) == int(stream_before.get("state", 0)),
		"a refusal draws no random number")


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


func _start_battle(ctrl: Node) -> void:
	ctrl.start_battle()
	await process_frame


func _unit_id(ctrl: Node, index: int) -> String:
	var board: Array = ctrl.state.get_board_units()
	if index < 0 or index >= board.size():
		return ""
	return String(board[index].instance_id)


## The instance id of the first item in the inventory.
func _first_item_id(ctrl: Node) -> String:
	if ctrl.state.items.is_empty():
		return ""
	return String(ctrl.state.items[0].instance_id)


## The observable state of the run.
func _snapshot(ctrl: Node) -> Dictionary:
	var board: Array = []
	for unit in ctrl.state.get_board_units():
		board.append("%s:%d:%d" % [unit.instance_id, unit.location, unit.order])
	var bench: Array = []
	for unit in ctrl.state.get_bench_units():
		bench.append("%s:%d:%d" % [unit.instance_id, unit.location, unit.order])
	var items: Array = []
	for item in ctrl.state.items:
		items.append("%s:%s" % [item.instance_id, item.owner_unit_id])
	return {
		"gold": ctrl.state.gold,
		"items": items,
		"board": board,
		"bench": bench,
	}


func _unchanged(ctrl: Node, before: Dictionary) -> bool:
	var after: Dictionary = _snapshot(ctrl)
	return (after.get("gold") == before.get("gold")
		and after.get("items") == before.get("items")
		and after.get("board") == before.get("board")
		and after.get("bench") == before.get("bench"))


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
		print("  [FAIL] Stage 4C: %s" % label)
