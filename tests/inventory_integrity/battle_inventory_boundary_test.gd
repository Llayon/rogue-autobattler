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
##   invalid inventory                   -> a setup that REFUSES to
##                                         start a battle: it is never
##                                         null (the declared return
##                                         type is non-nullable and
##                                         the existing callers
##                                         dereference it), it carries
##                                         NO units, and `validate()`
##                                         reports the refusal reason.
##                                         No silent normalization, no
##                                         duplicated item bonus, no
##                                         domain mutation, no
##                                         unintended RNG consumption,
##                                         no battle startup.
##
## R-02 (independent critic): the refusal was a `null`, and the 23
## existing callsites dereference the result unguarded -- so the
## failure mode was a SCRIPT ERROR, not a clean refusal. The refusal
## is an OBJECT now.
##
## The cases:
## - the valid ownership transfer: A loses the bonus, B gets exactly
##   one, the instance identity is unchanged;
## - a dangling reference in `equipped_item_ids`;
## - a duplicate logical item;
## - a broken mirrored ownership (the item and the unit disagree);
## - an item that is LISTED BY TWO UNITS (the duplicate ownership);
##   this is a DIFFERENT check from the duplicate logical item, and the
##   negative control NC-H11B proved it needed its own case;
## - the SAME unit listing the SAME item TWICE: this is the only shape
##   that the duplicate ownership check alone catches;
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
	await _test_F_a_doubly_owned_item_is_rejected()
	await _test_G_a_unit_that_lists_the_same_item_twice_is_rejected()
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
	_check(setup != null,
		"the refused build is an OBJECT, not a null (no crash at the caller)")
	_check(setup != null and str(setup.validate()) != "",
		"the refused build reports the refusal through validate()")
	_check(setup != null and setup.player_units.is_empty(),
		"the refused build carries no player unit")
	_check(setup != null and setup.enemy_units.is_empty(),
		"the refused build carries no enemy unit")
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
	_check(setup != null,
		"the refused build is an OBJECT, not a null (no crash at the caller)")
	_check(setup != null and str(setup.validate()) != "",
		"the refused build reports the refusal through validate()")
	_check(setup != null and setup.player_units.is_empty(),
		"the refused build carries no player unit")
	_check(setup != null and setup.enemy_units.is_empty(),
		"the refused build carries no enemy unit")
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
	_check(setup != null,
		"the refused build is an OBJECT, not a null (no crash at the caller)")
	_check(setup != null and str(setup.validate()) != "",
		"the refused build reports the refusal through validate()")
	_check(setup != null and setup.player_units.is_empty(),
		"the refused build carries no player unit")
	_check(setup != null and setup.enemy_units.is_empty(),
		"the refused build carries no enemy unit")


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


## F. An item that is LISTED BY TWO UNITS is an invalid domain.
##
## This is a DIFFERENT check from the duplicate logical item of the
## case C. In `RunDomainState.is_inventory_valid()`:
##
##   for item_id in u.equipped_item_ids:
##       if listings.has(item_id):          <- the duplicate OWNERSHIP
##           return false
##   ...
##   if it == null or ... or live_items.has(it.instance_id):
##       return false                       <- the duplicate ITEM
##
## Without the first check, an item that two units both claim is not
## an invalid inventory, so the builder builds a battle from it and
## the item bonus is applied TWICE.
##
## The negative control NC-H11B proved this case was needed: with
## only the case C, removing the duplicate ownership check left the
## whole suite green.
func _test_F_a_doubly_owned_item_is_rejected() -> void:
	var s = StateScript.new()
	var unit_def: Resource = ContentScript.get_by_id_for_type("units", &"warrior")
	if unit_def == null:
		return
	var a = s.create_unit(unit_def.id, unit_def.max_hp, UnitScript.LOCATION_BOARD)
	var b = s.create_unit(unit_def.id, unit_def.max_hp, UnitScript.LOCATION_BOARD)
	var item_def: Resource = ContentScript.get_by_id_for_type("items", &"potion_strength")
	if item_def == null:
		return
	var x = s.create_item(item_def.id)
	# The item is owned by A.
	s.equip_item(x.instance_id, a.instance_id)
	# And B claims the SAME item in its listing. The mirrored
	# ownership now disagrees: the item is owned by A, but two units
	# list it.
	b.equipped_item_ids.append(x.instance_id)
	_check(not s.is_inventory_valid(),
		"the doubly owned item makes the domain invalid")
	var setup: Object = BuilderScript.build(s, 123, 1)
	_check(setup != null,
		"the refused build is an OBJECT, not a null (no crash at the caller)")
	_check(setup != null and str(setup.validate()) != "",
		"the refused build reports the refusal through validate()")
	_check(setup != null and setup.player_units.is_empty(),
		"the refused build carries no player unit")
	# The bonus is NOT applied twice: the refused setup has no units
	# at all, so no bonus can be applied to either side.
	_check(setup != null and setup.enemy_units.is_empty(),
		"the refused build carries no enemy unit")


## G. The SAME unit lists the SAME item TWICE.
##
## This is the ONLY shape that the duplicate ownership check catches.
## The case F shape -- two units list the same item -- is ALSO caught
## by the mirrored ownership check, because `listings[item]` is the
## LAST writer while `owner_unit_id` names the first owner. Here both
## name the SAME unit, so the mirrored check passes and the domain
## would be VALID without the duplicate ownership check.
##
## The negative control NC-H11B proved this case was needed: with
## only the case F, removing the duplicate ownership check left the
## whole suite green.
func _test_G_a_unit_that_lists_the_same_item_twice_is_rejected() -> void:
	var s = StateScript.new()
	var unit_def: Resource = ContentScript.get_by_id_for_type("units", &"warrior")
	var item_def: Resource = ContentScript.get_by_id_for_type("items", &"potion_strength")
	if unit_def == null or item_def == null:
		return
	var a = s.create_unit(unit_def.id, unit_def.max_hp, UnitScript.LOCATION_BOARD)
	var x = s.create_item(item_def.id)
	s.equip_item(x.instance_id, a.instance_id)
	# The SAME unit lists the SAME item twice.
	a.equipped_item_ids.append(x.instance_id)
	_check(not s.is_inventory_valid(),
		"the twice listed item makes the domain invalid")
	var setup: Object = BuilderScript.build(s, 123, 1)
	_check(setup != null,
		"the refused build is an OBJECT, not a null (no crash at the caller)")
	_check(setup != null and str(setup.validate()) != "",
		"the refused build reports the refusal through validate()")
	_check(setup != null and setup.player_units.is_empty(),
		"the refused build carries no player unit")
	_check(setup != null and setup.enemy_units.is_empty(),
		"the refused build carries no enemy unit")


func _check(ok: bool, message: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("[FAIL] " + message)
