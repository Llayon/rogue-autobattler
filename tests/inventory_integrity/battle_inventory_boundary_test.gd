extends SceneTree
## Read-only cross-check of owner projection into battle bonuses.
const StateScript = preload("res://core/progression/run_domain_state.gd")
const UnitScript = preload("res://core/progression/run_unit.gd")
const BuilderScript = preload("res://core/battle_ecs/battle_setup_builder.gd")
const ContentScript = preload("res://core/utils/content_db.gd")
var _passed: int = 0
var _failed: int = 0

func _initialize() -> void:
	ContentScript.load_all()
	var s = StateScript.new()
	var def: Resource = ContentScript.get_by_id_for_type("units", &"warrior")
	var item_def: Resource = ContentScript.get_by_id_for_type("items", &"potion_strength")
	var a = s.create_unit(def.id, def.max_hp, UnitScript.LOCATION_BOARD)
	var b = s.create_unit(def.id, def.max_hp, UnitScript.LOCATION_BOARD)
	var x = s.create_item(item_def.id)
	s.equip_item(x.instance_id, a.instance_id)
	s.equip_item(x.instance_id, b.instance_id)
	var cursor: int = s.next_item_instance_seq
	var setup = BuilderScript.build(s, 123, 1)
	_check(setup.player_units[0].attack_base == def.attack, "previous owner has no item bonus")
	_check(setup.player_units[1].attack_base == def.attack + item_def.bonus_attack, "current owner gets exactly one item bonus")
	_check(x.owner_unit_id == b.instance_id and s.next_item_instance_seq == cursor and s.is_inventory_valid(), "build preserves live ownership and allocator")
	_check(setup.player_units[0].source_run_unit_id == a.instance_id and setup.player_units[1].source_run_unit_id == b.instance_id, "battle preserves unit identity")
	# Characterization: builder trusts owner projection, not reverse equipment list.
	a.equipped_item_ids.append("item_999999")
	setup = BuilderScript.build(s, 123, 1)
	_check(not s.is_inventory_valid() and setup.validate() == "", "known boundary: setup validation does not validate dangling inventory references")
	print("=== battle inventory boundary: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed else 0)

func _check(ok: bool, message: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("[FAIL] " + message)
