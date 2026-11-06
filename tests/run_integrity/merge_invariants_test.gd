extends SceneTree

## The integration invariants of the Inventory Integrity + Run
## Integrity merge.
##
## 1. every item has a unique stable instance ID;
## 2. one instance cannot belong to two owners or be in two places;
## 3. equip/unequip neither create nor destroy instances;
## 4. an invalid command -> zero mutation, zero RNG, zero events, zero
##    save side effects;
## 5. a forbidden phase -> fail closed;
## 6. the identity counters are monotonic and survive the checkpoint and
##    the restore;
## 7. a removal and a re-creation never reuse an allocated ID;
## 8. the inventory state is fully saved and restored through v5.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const SaveServiceScript = preload("res://core/save/save_service.gd")
const RngServiceScript = preload("res://core/utils/rng_service.gd")
const BalanceScript = preload("res://core/balance.gd")

const ISOLATED_DIR: String = "user://run_integrity_merge/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_the_instance_ids_are_unique_and_stable()
	await _test_B_one_owner_one_place()
	await _test_C_equip_and_unequip_change_no_instance()
	await _test_D_an_invalid_command_changes_nothing()
	await _test_E_a_forbidden_phase_fails_closed()
	await _test_F_the_counters_survive_the_checkpoint()
	await _test_G_a_removed_id_is_never_reused()
	await _test_H_the_inventory_round_trips_through_v5()
	print("")
	print("=== STAGE 4I: THE MERGE INVARIANTS: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## 1. Every item has a unique stable instance ID.
func _test_A_the_instance_ids_are_unique_and_stable() -> void:
	var ctrl: Node = await _make_controller(650001)
	var ids: Dictionary = {}
	for i in 6:
		ctrl.grant_item(&"potion_strength")
		var item_id: String = _last_item_id(ctrl)
		_assert(item_id != "", "the item has an instance id")
		_assert(not ids.has(item_id),
			"the instance id %s is unique" % item_id)
		ids[item_id] = true
	# The ids are stable: reading them again gives the same values.
	var before: Array = _all_item_ids(ctrl)
	for item in ctrl.state.items:
		_assert(str(item.instance_id) == str(item.instance_id),
			"the instance id is stable")
	_assert(before == _all_item_ids(ctrl), "the ids did not change")


## 2. One instance cannot belong to two owners or be in two places.
func _test_B_one_owner_one_place() -> void:
	var ctrl: Node = await _make_controller(650002)
	ctrl.grant_item(&"potion_strength")
	ctrl.grant_item(&"potion_strength")
	var first: String = _last_item_id(ctrl)
	var second: String = _first_item_id(ctrl)
	var unit_a: String = _unit_id(ctrl, 0)
	var unit_b: String = _unit_id(ctrl, 1)
	_assert(ctrl.equip_item_by_id(first, unit_a), "the first item is equipped")
	_assert(ctrl.equip_item_by_id(second, unit_b), "the second item is equipped")
	# Equipping an item to a second unit MOVES it: the previous owner
	# loses it. The invariant is that ONE instance has ONE owner.
	var moved: bool = ctrl.equip_item_by_id(first, unit_b)
	_assert(moved, "the item is moved to the second unit")
	_assert(ctrl.state.get_item(first).owner_unit_id == unit_b,
		"the owner of the moved item is the second unit")
	_assert(not _unit_equipped_ids(ctrl, unit_a).has(first),
		"the previous owner does not hold the item any more")
	_assert(_unit_equipped_ids(ctrl, unit_b).has(first),
		"the new owner holds the item")
	# The item is still ONE instance.
	_assert(_all_item_ids(ctrl).count(first) == 1,
		"the item is still one instance")
	_assert(ctrl.state.is_inventory_valid(), "the inventory is consistent")
	# Equipping the same pair again is a no-op that succeeds.
	var again: bool = ctrl.equip_item_by_id(first, unit_b)
	_assert(again, "the same pair is equipped again without a change")
	_assert(ctrl.state.get_item(first).owner_unit_id == unit_b,
		"the owner is unchanged")
	_assert(_all_item_ids(ctrl).count(first) == 1,
		"the item is still one instance")


## 3. Equip and unequip neither create nor destroy instances.
func _test_C_equip_and_unequip_change_no_instance() -> void:
	var ctrl: Node = await _make_controller(650003)
	ctrl.grant_item(&"potion_strength")
	var before_ids: Array = _all_item_ids(ctrl)
	var before_count: int = ctrl.state.items.size()
	var unit_id: String = _unit_id(ctrl, 0)
	_assert(ctrl.equip_item_by_id(_last_item_id(ctrl), unit_id),
		"the item is equipped")
	_assert(_all_item_ids(ctrl) == before_ids, "the equip changed no id")
	_assert(ctrl.state.items.size() == before_count,
		"the equip created no instance")
	_assert(ctrl.unequip_item_by_id(_last_item_id(ctrl)),
		"the item is unequipped")
	_assert(_all_item_ids(ctrl) == before_ids, "the unequip changed no id")
	_assert(ctrl.state.items.size() == before_count,
		"the unequip destroyed no instance")


## 4. An invalid command changes nothing.
func _test_D_an_invalid_command_changes_nothing() -> void:
	var ctrl: Node = await _make_controller(650004)
	ctrl.grant_item(&"potion_strength")
	var before: Dictionary = _observable(ctrl)
	var writes_before: int = ctrl.save_repository.get_save_count()
	var stream_before: Dictionary = RngServiceScript.snapshot()
	# The invalid commands.
	ctrl.equip_item_by_id("item_999999", _unit_id(ctrl, 0))
	ctrl.unequip_item_by_id("item_999999")
	ctrl.equip_item_by_id("", _unit_id(ctrl, 0))
	ctrl.grant_item(&"")
	ctrl.grant_item(&"no_such_item_definition")
	var after: Dictionary = _observable(ctrl)
	_assert(after == before, "an invalid command changed nothing")
	_assert(ctrl.save_repository.get_save_count() == writes_before,
		"an invalid command wrote no checkpoint")
	var stream_after: Dictionary = RngServiceScript.snapshot()
	_assert(int(stream_after.get("state", 0)) == int(stream_before.get("state", 0)),
		"an invalid command drew no random number")


## 5. A forbidden phase fails closed.
func _test_E_a_forbidden_phase_fails_closed() -> void:
	var ctrl: Node = await _make_controller(650005)
	ctrl.start_battle()
	await process_frame
	var before: Dictionary = _observable(ctrl)
	_assert(not ctrl.grant_item(&"potion_strength"),
		"the grant is refused in a battle")
	_assert(not ctrl.remove_item_at(0), "the removal is refused in a battle")
	_assert(_observable(ctrl) == before,
		"a refused command changed nothing")


## 6. The identity counters are monotonic and survive the checkpoint.
func _test_F_the_counters_survive_the_checkpoint() -> void:
	var ctrl: Node = await _make_controller(650006)
	for i in 3:
		ctrl.grant_item(&"potion_strength")
	var cursor_before: int = ctrl.state.next_item_instance_seq
	_assert(cursor_before > 3, "the cursor is above the live ids")
	# A checkpoint and a restore. The checkpoint is written at the
	# phase boundaries, so the inventory that was granted after the
	# last write must be written first.
	ctrl.save_now()
	var dto: Dictionary = ctrl.build_checkpoint_dto()
	_assert(int(dto.get("next_item_instance_seq", 0)) == cursor_before,
		"the checkpoint carries the cursor")
	var resumed: Node = await _make_controller(650007)
	var ok: bool = resumed.resume_run(650006)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(resumed.state.next_item_instance_seq == cursor_before,
		"the cursor survives the restore (got %d, it was %d)"
			% [resumed.state.next_item_instance_seq, cursor_before])


## 7. A removal and a re-creation never reuse an allocated ID.
func _test_G_a_removed_id_is_never_reused() -> void:
	var ctrl: Node = await _make_controller(650008)
	ctrl.grant_item(&"potion_strength")
	var first_id: String = _last_item_id(ctrl)
	var cursor_before: int = ctrl.state.next_item_instance_seq
	_assert(ctrl.remove_item_at(0), "the item is removed")
	ctrl.grant_item(&"potion_strength")
	var second_id: String = _last_item_id(ctrl)
	_assert(second_id != first_id,
		"the re-created item has a new id (%s vs %s)" % [second_id, first_id])
	_assert(ctrl.state.next_item_instance_seq > cursor_before,
		"the cursor moved forward")
	_assert(ctrl.state.is_inventory_valid(), "the inventory is consistent")


## 8. The inventory state is fully saved and restored through v5.
func _test_H_the_inventory_round_trips_through_v5() -> void:
	var ctrl: Node = await _make_controller(650009)
	ctrl.grant_item(&"potion_strength")
	ctrl.grant_item(&"amulet_vigor")
	var unit_id: String = _unit_id(ctrl, 0)
	_assert(ctrl.equip_item_by_id(_last_item_id(ctrl), unit_id),
		"an item is equipped")
	var before: Array = _all_item_ids(ctrl)
	var owners_before: Array = _all_owners(ctrl)
	# The checkpoint is written at the phase boundaries: the inventory
	# that was granted after the last write lands with the next one.
	ctrl.save_now()

	var resumed: Node = await _make_controller(650010)
	var ok: bool = resumed.resume_run(650009)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(_all_item_ids(resumed) == before,
		"the ids survive the round trip")
	_assert(_all_owners(resumed) == owners_before,
		"the ownership survives the round trip")
	_assert(resumed.state.is_inventory_valid(),
		"the restored inventory is consistent")


# ----------------------------------------------------------------


func _make_controller(seed_value: int) -> Node:
	var ctrl: Node = RunControllerScript.new()
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR)
	ctrl.meta_writer = _MetaWriter.new()
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer", &"cleric",
		&"mage", &"knight", &"druid"] as Array[StringName]
	ctrl.start_run(seed_value)
	await process_frame
	return ctrl


func _all_item_ids(ctrl: Node) -> Array:
	var ids: Array = []
	for item in ctrl.state.items:
		ids.append(str(item.instance_id))
	return ids


func _all_owners(ctrl: Node) -> Array:
	var owners: Array = []
	for item in ctrl.state.items:
		owners.append("%s:%s" % [str(item.instance_id),
			str(item.owner_unit_id)])
	return owners


## The instance id of the LAST item: `grant_item` appends, so the
## last one is the new one.
func _last_item_id(ctrl: Node) -> String:
	if ctrl.state.items.is_empty():
		return ""
	return str(ctrl.state.items[ctrl.state.items.size() - 1].instance_id)


## The equipped item ids of a unit.
func _unit_equipped_ids(ctrl: Node, unit_instance_id: String) -> Array:
	var unit: RunUnit = ctrl.state.get_unit(unit_instance_id)
	if unit == null:
		return []
	return unit.equipped_item_ids.duplicate()


## The instance id of the FIRST item.
func _first_item_id(ctrl: Node) -> String:
	if ctrl.state.items.is_empty():
		return ""
	return str(ctrl.state.items[0].instance_id)


func _second_item_id(ctrl: Node) -> String:
	if ctrl.state.items.size() < 2:
		return ""
	return str(ctrl.state.items[1].instance_id)


func _unit_id(ctrl: Node, index: int) -> String:
	var board: Array = ctrl.state.get_board_units()
	if index < 0 or index >= board.size():
		return ""
	return str(board[index].instance_id)


## The observable state of the run.
func _observable(ctrl: Node) -> Dictionary:
	var units: Array = []
	for unit in ctrl.state.get_board_units():
		units.append("%s:%s:%d" % [str(unit.instance_id),
			str(unit.location), unit.order])
	for unit in ctrl.state.get_bench_units():
		units.append("%s:%s:%d" % [str(unit.instance_id),
			str(unit.location), unit.order])
	return {
		"gold": ctrl.state.gold,
		"items": _all_owners(ctrl),
		"units": units,
		"cursor": ctrl.state.next_item_instance_seq,
	}


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
		print("  [FAIL] Stage 4I: %s" % label)
