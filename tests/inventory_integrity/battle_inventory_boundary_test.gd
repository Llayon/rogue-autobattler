extends SceneTree

## H-11: the ECS battle setup must not start from an INCONSISTENT
## inventory.
##
## `BattleSetupBuilder.build()` reads `p_state.get_equipped_items()` and
## never checks `p_state.is_inventory_valid()`. The previous
## characterization test ASSERTED that boundary as acceptable:
##
##   "known boundary: setup validation does not validate dangling
##    inventory references"
##
## That is the defect. The contract now is:
##
##   state.is_inventory_valid() == true  -> a valid BattleSetup
##   invalid inventory                   -> NO battle setup at all:
##                                         no silent normalization, no
##                                         duplicated item bonus, no
##                                         domain mutation, no
##                                         unintended RNG consumption,
##                                         no battle startup
##
## The cases:
## - the valid ownership transfer: A loses the bonus, B gets exactly
##   one, the instance identity is unchanged;
## - a dangling reference in `equipped_item_ids`;
## - a duplicate logical item;
## - a broken mirrored ownership (the item and the unit disagree);
## - the valid state: the same seed produces the same setup and no
##   unexpected global RNG draws.

const StateScript = preload("res://core/progression/run_domain_state.gd")
const UnitScript = preload("res://core/progression/run_unit.gd")
const BuilderScript = preload("res://core/battle_ecs/battle_setup_builder.gd")
const ContentScript = preload("res://core/utils/content_db.gd")
const RngServiceScript = preload("res://core/utils/rng_service.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentScript.load_all()
	await _test_A_the_valid_ownership_transfer()
	await _test_B_a_dangling_reference_is_rejected()
	await _test_C_a_duplicate_logical_item_is_rejected()
	await _test_D_a_broken_mirrored_ownership_is_rejected()
	await _test_E_the_valid_state_is_deterministic()
	print("")
	print("=== battle inventory boundary: %d passed, %d failed ==="
		% [_passed, _failed])
	quit(1 if _failed else 0)


## A. The valid transfer: A loses the bonus, B gets exactly one, the
## identity is unchanged.
func _test_A_the_valid_ownership_transfer() -> void:
	var s: Object = StateScript.new()
	var def: Resource = ContentScript.get_by_id_for_type("units", &"warrior")
	var item_def: Resource = ContentScript.get_by_id_for_type("items",
		&"potion_strength")
	var a: Object = s.create_unit(def.id, def.max_hp, UnitScript.LOCATION_BOARD)
	var b: Object = s.create_unit(def.id, def.max_hp, UnitScript.LOCATION_BOARD)
	var x: Object = s.create_item(item_def.id)
	_check(s.equip_item(x.instance_id, a.instance_id),
		"the item equips to A")
	_check(s.equip_item(x.instance_id, b.instance_id),
		"the item transfers to B")
	var cursor: int = s.next_item_instance_seq
	var setup: Object = BuilderScript.build(s, 123, 1)
	_check(setup != null, "the valid state produces a setup")
	if setup != null:
		_check(setup.player_units[0].attack_base == def.attack,
			"the previous owner has no item bonus")
		_check(setup.player_units[1].attack_base == def.attack + item_def.bonus_attack,
			"the current owner gets exactly one item bonus")
	_check(str(x.owner_unit_id) == str(b.instance_id),
		"the live ownership is the new owner")
	_check(s.next_item_instance_seq == cursor,
		"the build preserved the allocator")
	_check(s.is_inventory_valid(), "the live inventory is consistent")
	_check(setup.player_units[0].source_run_unit_id == a.instance_id
			and setup.player_units[1].source_run_unit_id == b.instance_id,
		"the battle preserved the unit identity")


## B. A dangling reference in `equipped_item_ids` makes the domain
## invalid, and the build must be REJECTED.
func _test_B_a_dangling_reference_is_rejected() -> void:
	var s: Object = StateScript.new()
	var def: Resource = ContentScript.get_by_id_for_type("units", &"warrior")
	var a: Object = s.create_unit(def.id, def.max_hp, UnitScript.LOCATION_BOARD)
	a.equipped_item_ids.append("item_999999")
	_check(not s.is_inventory_valid(),
		"the dangling reference makes the domain invalid")
	var before_cursor: int = s.next_item_instance_seq
	var setup: Object = BuilderScript.build(s, 123, 1)
	_check(setup == null, "the build is REJECTED for a dangling reference")
	_check(s.next_item_instance_seq == before_cursor,
		"the rejected build consumed no allocation")
	_check(not s.is_inventory_valid(),
		"the rejected build did not normalize the domain")


## C. A duplicate logical item: two RunItems with the same instance id.
func _test_C_a_duplicate_logical_item_is_rejected() -> void:
	var s: Object = StateScript.new()
	var def: Resource = ContentScript.get_by_id_for_type("units", &"warrior")
	var item_def: Resource = ContentScript.get_by_id_for_type("items",
		&"potion_strength")
	var a: Object = s.create_unit(def.id, def.max_hp, UnitScript.LOCATION_BOARD)
	var x: Object = s.create_item(item_def.id)
	_check(s.equip_item(x.instance_id, a.instance_id), "the item equips")
	# A SECOND item with the SAME instance id: a duplicated logical
	# item, which would apply the bonus twice.
	var twin: Object = ItemScript.new()
	twin.instance_id = x.instance_id
	twin.definition_id = item_def.id
	twin.owner_unit_id = ""
	s.items.append(twin)
	_check(not s.is_inventory_valid(),
		"the duplicate instance id makes the domain invalid")
	var setup: Object = BuilderScript.build(s, 123, 1)
	_check(setup == null, "the build is REJECTED for a duplicate item")
	_check(not s.is_inventory_valid(),
		"the rejected build did not normalize the domain")


## D. The mirrored ownership disagrees: the item says one owner, the
## unit lists another.
func _test_D_a_broken_mirrored_ownership_is_rejected() -> void:
	var s: Object = StateScript.new()
	var def: Resource = ContentScript.get_by_id_for_type("units", &"warrior")
	var item_def: Resource = ContentScript.get_by_id_for_type("items",
		&"potion_strength")
	var a: Object = s.create_unit(def.id, def.max_hp, UnitScript.LOCATION_BOARD)
	var b: Object = s.create_unit(def.id, def.max_hp, UnitScript.LOCATION_BOARD)
	var x: Object = s.create_item(item_def.id)
	_check(s.equip_item(x.instance_id, a.instance_id), "the item equips to A")
	# The mirrored ownership breaks: A still lists the item, but the
	# item says B owns it.
	x.owner_unit_id = b.instance_id
	_check(not s.is_inventory_valid(),
		"the broken mirrored ownership makes the domain invalid")
	var setup: Object = BuilderScript.build(s, 123, 1)
	_check(setup == null, "the build is REJECTED for a broken ownership")


## E. The valid state: the same seed produces the same setup, and the
## global stream is not consumed.
func _test_E_the_valid_state_is_deterministic() -> void:
	var s: Object = StateScript.new()
	var def: Resource = ContentScript.get_by_id_for_type("units", &"warrior")
	var item_def: Resource = ContentScript.get_by_id_for_type("items",
		&"potion_strength")
	var a: Object = s.create_unit(def.id, def.max_hp, UnitScript.LOCATION_BOARD)
	var x: Object = s.create_item(item_def.id)
	_check(s.equip_item(x.instance_id, a.instance_id), "the item equips")
	_check(s.is_inventory_valid(), "the state is valid")

	# The global stream before the build.
	var before: Dictionary = RngServiceScript.snapshot()
	var first: Object = BuilderScript.build(s, 7777, 3)
	var after: Dictionary = RngServiceScript.snapshot()
	_check(first != null, "the valid state produces a setup")
	_check(int(after.get("state", 0)) == int(before.get("state", 0)),
		"the build consumed no global RNG state")

	var second: Object = BuilderScript.build(s, 7777, 3)
	_check(first != null and second != null, "both builds produced a setup")
	if first != null and second != null:
		_check(first.player_units.size() == second.player_units.size(),
			"the same seed produces the same setup size")
		if first.player_units.size() > 0:
			_check(first.player_units[0].attack_base
					== second.player_units[0].attack_base,
				"the same seed produces the same attack")


const ItemScript = preload("res://core/progression/run_item.gd")


func _check(ok: bool, message: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("[FAIL] " + message)
