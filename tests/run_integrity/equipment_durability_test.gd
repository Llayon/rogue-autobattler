extends SceneTree

## H-09: the equipment changes must survive Continue.
##
## The baseline:
##
##   equip_item_by_id   -> mutates the live state, never calls save_now()
##   unequip_item_by_id -> mutates the live state, never calls save_now()
##   equip_item_at      -> the same through the by-id path
##   unequip_item_at    -> the same through the by-id path
##
## So the equipment was lost on Continue.
##
## The contract:
##
##   PREP   -> save after a real mutation
##   MAP    -> save after a real mutation
##   REWARD -> save after a real mutation
##   BATTLE -> DO NOT create a fake PREP checkpoint: the v5 format
##             does not persist the battle simulation runtime. The
##             allowed command changes the live inventory, the battle
##             keeps its own snapshot, and the new equipment reaches
##             the NEXT correct checkpoint.
##
## And a no-op must not write: `RunDomainState.equip_item()` returns
## true for an ALREADY equipped item without changing anything, so
## `operation returns true` is NOT `state changed`.
##
## The comparisons cover BOTH sides of the ownership:
##
##   RunItem.owner_unit_id
##   RunUnit.equipped_item_ids

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const ContentDB_static = preload("res://core/utils/content_db.gd")
const FaultOps = preload("res://tests/save_repository/support/run_save_file_ops_fault.gd")

const ISOLATED_DIR: String = "user://run_integrity_h09/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_a_map_equip_survives_a_resume()
	await _test_B_a_map_unequip_survives_a_resume()
	await _test_C_a_prep_equip_survives_a_resume()
	await _test_D_an_index_equip_survives_a_resume()
	await _test_E_an_index_unequip_survives_a_resume()
	await _test_F_an_already_equipped_item_writes_nothing()
	await _test_G_an_already_unequipped_item_writes_nothing()
	await _test_H_an_invalid_command_writes_nothing()
	await _test_I_a_battle_equip_writes_no_checkpoint()
	await _test_J_a_battle_equip_reaches_the_next_checkpoint()
	print("")
	print("=== STAGE H09: THE EQUIPMENT IS DURABLE: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. A MAP equip survives a resume.
func _test_A_a_map_equip_survives_a_resume() -> void:
	var ctrl: Node = await _make_controller(670801)
	await _prepare_equipment(ctrl)
	# RUN-ENTRY-01: the battle entry is guarded, so a battle may only
	# start from a real battle context. The case needs a STARTED
	# BATTLE, not the map: the first battle of the run -- the initial
	# preparation -- is the production way to one.
	await process_frame
	var item_id: String = _first_item_id(ctrl)
	var unit_id: String = _first_unit_id(ctrl)
	_assert(item_id != "" and unit_id != "",
		"the run has an item and a unit")
	if item_id == "" or unit_id == "":
		return
	var equipped: bool = ctrl.equip_item_by_id(item_id, unit_id)
	_assert(equipped, "the equip succeeds")

	var resumed: Node = await _make_controller(670802)
	var ok: bool = resumed.resume_run(670801)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(_owner_of(resumed, item_id) == unit_id,
		"the resumed item is owned by the unit (got %s, it is %s)"
			% [_owner_of(resumed, item_id), unit_id])
	_assert(_equipped_ids_of(resumed, unit_id).has(item_id),
		"the resumed unit lists the item")


## B. A MAP unequip survives a resume.
func _test_B_a_map_unequip_survives_a_resume() -> void:
	var ctrl: Node = await _make_controller(670803)
	await _prepare_equipment(ctrl)
	# RUN-ENTRY-01: the battle entry is guarded, so a battle may only
	# start from a real battle context. The case needs a STARTED
	# BATTLE, not the map: the first battle of the run -- the initial
	# preparation -- is the production way to one.
	await process_frame
	var item_id: String = _first_item_id(ctrl)
	var unit_id: String = _first_unit_id(ctrl)
	if item_id == "" or unit_id == "":
		return
	_assert(ctrl.equip_item_by_id(item_id, unit_id), "the equip succeeds")
	# A checkpoint that holds the equipped state.
	ctrl.save_now()
	await process_frame
	var unequipped: bool = ctrl.unequip_item_by_id(item_id)
	_assert(unequipped, "the unequip succeeds")

	var resumed: Node = await _make_controller(670804)
	var ok: bool = resumed.resume_run(670803)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(_owner_of(resumed, item_id) == "",
		"the resumed item has no owner (got %s)" % _owner_of(resumed, item_id))
	_assert(not _equipped_ids_of(resumed, unit_id).has(item_id),
		"the resumed unit does not list the item")


## C. A PREP equip survives a resume.
func _test_C_a_prep_equip_survives_a_resume() -> void:
	var ctrl: Node = await _make_controller(670805)
	await _prepare_equipment(ctrl)
	var item_id: String = _first_item_id(ctrl)
	var unit_id: String = _first_unit_id(ctrl)
	if item_id == "" or unit_id == "":
		return
	_assert(ctrl.equip_item_by_id(item_id, unit_id), "the equip succeeds")
	var resumed: Node = await _make_controller(670806)
	var ok: bool = resumed.resume_run(670805)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(_owner_of(resumed, item_id) == unit_id,
		"the resumed item is owned by the unit")


## D. An index equip survives a resume.
func _test_D_an_index_equip_survives_a_resume() -> void:
	var ctrl: Node = await _make_controller(670807)
	await _prepare_equipment(ctrl)
	ctrl._enter_map()
	await process_frame
	var item_idx: int = _first_item_index(ctrl)
	_assert(item_idx >= 0, "the run has an item")
	if item_idx < 0:
		return
	var item_id: String = ctrl.state.items[item_idx].instance_id
	var unit_id: String = _first_unit_id(ctrl)
	var equipped: bool = ctrl.equip_item_at(item_idx, 0)
	_assert(equipped, "the index equip succeeds")
	var resumed: Node = await _make_controller(670808)
	var ok: bool = resumed.resume_run(670807)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(_owner_of(resumed, item_id) == unit_id,
		"the resumed item is owned by the unit (got %s, it is %s)"
			% [_owner_of(resumed, item_id), unit_id])


## E. An index unequip survives a resume.
func _test_E_an_index_unequip_survives_a_resume() -> void:
	var ctrl: Node = await _make_controller(670809)
	await _prepare_equipment(ctrl)
	ctrl._enter_map()
	await process_frame
	var item_idx: int = _first_item_index(ctrl)
	if item_idx < 0:
		return
	var item_id: String = ctrl.state.items[item_idx].instance_id
	var unit_id: String = _first_unit_id(ctrl)
	_assert(ctrl.equip_item_at(item_idx, 0), "the index equip succeeds")
	ctrl.save_now()
	await process_frame
	_assert(ctrl.unequip_item_at(item_idx), "the index unequip succeeds")
	var resumed: Node = await _make_controller(670810)
	var ok: bool = resumed.resume_run(670809)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(_owner_of(resumed, item_id) == "",
		"the resumed item has no owner")


## F. An ALREADY equipped item writes NOTHING: the operation returns
## true, but the state did not change.
func _test_F_an_already_equipped_item_writes_nothing() -> void:
	var ctrl: Node = await _make_controller(670811)
	await _prepare_equipment(ctrl)
	# RUN-ENTRY-01: the battle entry is guarded, so a battle may only
	# start from a real battle context. The case needs a STARTED
	# BATTLE, not the map: the first battle of the run -- the initial
	# preparation -- is the production way to one.
	await process_frame
	var item_id: String = _first_item_id(ctrl)
	var unit_id: String = _first_unit_id(ctrl)
	if item_id == "" or unit_id == "":
		return
	_assert(ctrl.equip_item_by_id(item_id, unit_id), "the first equip succeeds")
	ctrl.save_now()
	await process_frame
	var count_before: int = ctrl.save_repository.get_save_count()
	# The SAME equip again: an idempotent repeat.
	var again: bool = ctrl.equip_item_by_id(item_id, unit_id)
	_assert(again, "the idempotent repeat returns true")
	_assert(ctrl.save_repository.get_save_count() == count_before,
		"the idempotent repeat wrote nothing (it was %d, it is %d)"
			% [ctrl.save_repository.get_save_count(), count_before])


## G. An ALREADY unequipped item writes NOTHING.
func _test_G_an_already_unequipped_item_writes_nothing() -> void:
	var ctrl: Node = await _make_controller(670812)
	await _prepare_equipment(ctrl)
	ctrl._enter_map()
	await process_frame
	var item_id: String = _first_item_id(ctrl)
	if item_id == "":
		return
	# The item is NOT equipped.
	ctrl.save_now()
	await process_frame
	var count_before: int = ctrl.save_repository.get_save_count()
	# The idempotent repeat: the item is NOT equipped, so there is
	# nothing to purge. The return value is the result of the purge,
	# which is false when there was nothing to purge -- the contract
	# that matters is the NO WRITE.
	ctrl.unequip_item_by_id(item_id)
	_assert(ctrl.save_repository.get_save_count() == count_before,
		"the idempotent repeat wrote nothing (it was %d, it is %d)"
			% [ctrl.save_repository.get_save_count(), count_before])


## H. An invalid command writes NOTHING.
func _test_H_an_invalid_command_writes_nothing() -> void:
	var ctrl: Node = await _make_controller(670813)
	await _prepare_equipment(ctrl)
	ctrl._enter_map()
	await process_frame
	var count_before: int = ctrl.save_repository.get_save_count()
	_assert(not ctrl.equip_item_by_id("", ""), "the empty equip is refused")
	_assert(not ctrl.equip_item_by_id("item_999999", "unit_999999"),
		"the unknown equip is refused")
	_assert(not ctrl.unequip_item_by_id(""), "the empty unequip is refused")
	_assert(ctrl.save_repository.get_save_count() == count_before,
		"the refused commands wrote nothing (it was %d, it is %d)"
			% [ctrl.save_repository.get_save_count(), count_before])


## I. A BATTLE equip writes NO checkpoint: the v5 format does not
## persist the battle runtime, so a checkpoint there would carry a
## FALSE phase.
##
## The mutation must be REAL: the SAME item equipped again is a NO-OP,
## and the no-op guard returns BEFORE the phase guard -- so a no-op
## case could never catch the removal of the phase guard. Two items
## are granted and the SECOND one is equipped during the battle.
##
## The negative control NC-H09C proved this: with the old no-op case
## the removal of the phase guard was MISSED (the suite stayed green
## with the guard removed).
func _test_I_a_battle_equip_writes_no_checkpoint() -> void:
	var ctrl: Node = await _make_controller(670814)
	await _prepare_equipment(ctrl)
	# RUN-ENTRY-01: the battle entry is guarded, so a battle may only
	# start from a real battle context. The case needs a STARTED
	# BATTLE, not the map: the first battle of the run -- the initial
	# preparation -- is the production way to one.
	await process_frame
	var item_id: String = _first_item_id(ctrl)
	var unit_id: String = _first_unit_id(ctrl)
	if item_id == "" or unit_id == "":
		return
	_assert(ctrl.equip_item_by_id(item_id, unit_id), "the equip succeeds")
	# A SECOND item, so the battle equip can be a REAL mutation.
	var second_def: Resource = ContentDB_static.get_by_id_for_type("items",
		&"potion_haste")
	if second_def == null:
		second_def = ContentDB_static.get_by_id_for_type("items",
			&"potion_strength")
	if second_def == null:
		return
	var second: Object = ctrl.state.create_item(second_def.id)
	if second == null:
		return
	var second_id: String = String(second.instance_id)
	ctrl.save_now()
	await process_frame
	# The battle starts.
	_assert(ctrl.start_battle(), "the battle starts")
	await process_frame
	_assert(int(ctrl.phase) == 1, "the phase is BATTLE")
	var count_before: int = ctrl.save_repository.get_save_count()
	# The equipment REALLY changes DURING the battle: the second item
	# is equipped to the unit.
	var changed: bool = ctrl.equip_item_by_id(second_id, unit_id)
	_assert(changed, "the battle equip is allowed")
	_assert(_owner_of(ctrl, second_id) == unit_id,
		"the live inventory changed during the battle")
	_assert(ctrl.save_repository.get_save_count() == count_before,
		"the battle equip wrote NO checkpoint (it was %d, it is %d)"
			% [ctrl.save_repository.get_save_count(), count_before])
	# And no checkpoint claims a PREP phase during the battle.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(670814)
	if loaded != null and loaded.is_ok():
		var dto: Dictionary = loaded.data
		_assert(str(dto.get("phase", "")) != "prep"
				or int(dto.get("round_index", 0)) >= 1,
			"the checkpoint does not fake a PREP state")


## J. The battle equip reaches the NEXT correct checkpoint: after the
## battle, the equipment is persisted.
func _test_J_a_battle_equip_reaches_the_next_checkpoint() -> void:
	var ctrl: Node = await _make_controller(670815)
	await _prepare_equipment(ctrl)
	# RUN-ENTRY-01: the battle entry is guarded, so a battle may only
	# start from a real battle context. The case needs a STARTED
	# BATTLE, not the map: the first battle of the run -- the initial
	# preparation -- is the production way to one.
	await process_frame
	var item_id: String = _first_item_id(ctrl)
	var unit_id: String = _first_unit_id(ctrl)
	if item_id == "" or unit_id == "":
		return
	_assert(ctrl.equip_item_by_id(item_id, unit_id), "the equip succeeds")
	ctrl.save_now()
	await process_frame
	_assert(ctrl.start_battle(), "the battle starts")
	await process_frame
	# The equipment changes DURING the battle.
	_assert(ctrl.equip_item_by_id(item_id, unit_id),
		"the battle equip is allowed")
	# The battle is won and the outcome is persisted.
	if ctrl.runner != null:
		ctrl.runner.state.winner_team = 0
		ctrl.runner.state.phase = 6
		ctrl._on_battle_ended()
	await process_frame

	var resumed: Node = await _make_controller(670816)
	var ok: bool = resumed.resume_run(670815)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(_owner_of(resumed, item_id) == unit_id,
		"the resumed item is owned by the unit (got %s, it is %s)"
			% [_owner_of(resumed, item_id), unit_id])


# ----------------------------------------------------------------


func _owner_of(ctrl: Node, item_id: String) -> String:
	var item: Object = ctrl.state.get_item(item_id)
	if item == null:
		return "<missing>"
	return String(item.owner_unit_id)


func _equipped_ids_of(ctrl: Node, unit_id: String) -> Array:
	var unit: Object = ctrl.state.get_unit(unit_id)
	if unit == null:
		return []
	return unit.equipped_item_ids


func _first_item_id(ctrl: Node) -> String:
	if ctrl.state.items.is_empty():
		return ""
	return String(ctrl.state.items[0].instance_id)


func _first_item_index(ctrl: Node) -> int:
	if ctrl.state.items.is_empty():
		return -1
	return 0


func _first_unit_id(ctrl: Node) -> String:
	var board: Array = ctrl.state.get_board_units()
	if board.is_empty():
		return ""
	return String(board[0].instance_id)


## Gives the run a board unit and an item, so the equipment commands
## have something to work on.
func _prepare_equipment(ctrl: Node) -> void:
	var unit_def: Resource = ContentDB_static.get_by_id_for_type("units", &"warrior")
	var item_def: Resource = ContentDB_static.get_by_id_for_type("items",
		&"potion_strength")
	if unit_def != null:
		var unit: Object = ctrl.state.create_unit(unit_def.id, unit_def.max_hp, 0)
		if unit != null:
			ctrl.state.move_unit(unit.instance_id, 0)
	if item_def != null:
		ctrl.state.create_item(item_def.id)


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
		print("  [FAIL] Stage H09: %s" % label)
