extends SceneTree

## The persistence gate and the live gate must agree on what a valid
## item instance id is.
##
## The INVENTORY package made the LIVE gate strict: the id must be
## the canonical `item_%06d` form. The RUN INTEGRITY package's
## persistence gate stayed lenient: it only checks the prefix and that
## the remainder is a valid integer, so "item_1", "item_-5" and
## "item_abc" pass it.
##
## The consequence: a checkpoint that passes EVERY v5 gate (shape,
## semantic, repository write, repository load, mapper decode) can
## produce a live inventory in which the ENTIRE item subsystem fails
## closed forever -- grant, equip, unequip AND remove -- and the poison
## is re-written unchanged on every subsequent save, so it is
## self-perpetuating and there is no in-game repair path.
##
## The invariant: every id the persistence gate accepts must be an id
## the live gate accepts.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const SaveServiceScript = preload("res://core/save/save_service.gd")
const RunCheckpointV5MapperScript = preload("res://core/progression/run_checkpoint_v5_mapper.gd")
const RunDomainSemanticValidatorScript = preload("res://core/save/run_domain_semantic_validator.gd")

const ISOLATED_DIR: String = "user://run_integrity_identity/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_the_gates_agree_on_the_canonical_form()
	await _test_B_a_non_canonical_id_is_refused_everywhere()
	await _test_C_a_poisoned_inventory_is_not_a_dead_end()
	await _test_D_the_canonical_form_is_accepted()
	print("")
	print("=== STAGE 4J: THE IDENTITY GATES AGREE: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. The two gates must agree on every form.
func _test_A_the_gates_agree_on_the_canonical_form() -> void:
	var forms: Array = ["item_000001", "item_1", "item_-5", "item_abc",
		"item_", "item_0000001", "ITEM_000001"]
	for form in forms:
		var id: String = String(form)
		var persistence_ok: bool = _persistence_accepts(id)
		var live_ok: bool = _live_accepts(id)
		_assert(persistence_ok == live_ok,
			"the gates agree on '%s' (the persistence gate %s, the live gate %s)"
				% [id, str(persistence_ok), str(live_ok)])


## B. A non-canonical id must be refused by the persistence gate, so it
## never reaches the disk.
func _test_B_a_non_canonical_id_is_refused_everywhere() -> void:
	for form in ["item_1", "item_-5", "item_abc", "item_0000001"]:
		var id: String = String(form)
		_assert(not _persistence_accepts(id),
			"the persistence gate refuses '%s'" % id)


## C. A poisoned inventory must not be a dead end: the item must be
## removable, so the player is never stuck.
func _test_C_a_poisoned_inventory_is_not_a_dead_end() -> void:
	var ctrl: Node = await _make_controller(660001)
	ctrl.grant_item(&"potion_strength")
	var item_id: String = _first_item_id(ctrl)
	_assert(item_id != "", "the item was granted")
	# The item is poisoned: the id no longer matches the canonical form.
	ctrl.state.items[0].instance_id = "item_1"
	_assert(not ctrl.state.is_inventory_valid(),
		"the poisoned inventory is detected")
	# The strict removal refuses it: that is the INVENTORY contract.
	_assert(not ctrl.remove_item_at(0),
		"the strict removal refuses an inconsistent inventory")
	# The REPAIR path is the escape hatch: the player is never locked
	# out of their own inventory.
	var removed: bool = ctrl.remove_item_force_at(0)
	_assert(removed, "the repair path removes a poisoned item")
	_assert(ctrl.state.items.is_empty(), "the poisoned item is gone")
	_assert(ctrl.state.is_inventory_valid(),
		"the inventory is consistent after the removal")


## D. The canonical form is accepted by both gates.
func _test_D_the_canonical_form_is_accepted() -> void:
	_assert(_persistence_accepts("item_000001"),
		"the persistence gate accepts the canonical form")
	_assert(_live_accepts("item_000001"),
		"the live gate accepts the canonical form")


# ----------------------------------------------------------------


## Whether the PERSISTENCE gate accepts an item id.
func _persistence_accepts(item_id: String) -> bool:
	var dto: Dictionary = _dto_with_item(item_id)
	var result: Dictionary = RunDomainSemanticValidatorScript.validate(dto)
	return bool(result.get("success", false))


## Whether the LIVE gate accepts an item id.
func _live_accepts(item_id: String) -> bool:
	var ctrl: Node = RunControllerScript.new()
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR)
	ctrl.meta_writer = _MetaWriter.new()
	var state: Object = RunDomainStateScript.new()
	state.seed = 660099
	state.next_item_instance_seq = 2
	var item: Object = RunItemScript.new()
	item.instance_id = item_id
	item.definition_id = &"potion_strength"
	item.owner_unit_id = ""
	state.items.append(item)
	return bool(state.is_inventory_valid())


## A v5 DTO with one item that carries the given id.
func _dto_with_item(item_id: String) -> Dictionary:
	return {
		"schema_version": 5,
		"game_build": "",
		"run_id": "run_660001",
		"seed": 660001,
		"round_index": 1,
		"phase": "prep",
		"gold": 10,
		"units": [],
		"items": [{
			"instance_id": item_id,
			"definition_id": "potion_strength",
			"owner_unit_id": "",
		}],
		"next_unit_instance_seq": 1,
		"next_item_instance_seq": 2,
		"shop": {},
		"map": {},
		"rewards": {},
		"rng": {"seed": 660001, "state": "1234567890123456789"},
		"wins": 0,
		"losses": 0,
		"units_killed": 0,
		"lives": 1,
		"xp": 0,
		"level": 1,
		"current_encounter_id": -1,
		"encounter_visited_ids": [],
		"meta_modifiers": {},
		"just_visited_merchant": false,
	}


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


func _first_item_id(ctrl: Node) -> String:
	if ctrl.state.items.is_empty():
		return ""
	return str(ctrl.state.items[0].instance_id)


const RunDomainStateScript = preload("res://core/progression/run_domain_state.gd")
const RunItemScript = preload("res://core/progression/run_item.gd")


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
		print("  [FAIL] Stage 4J: %s" % label)
