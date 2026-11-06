extends SceneTree
## Content resolution belongs at the controller boundary, never the pure domain.
const ControllerScript = preload("res://core/progression/run_controller.gd")
const UnitScript = preload("res://core/progression/run_unit.gd")
const ContentScript = preload("res://core/utils/content_db.gd")
var _passed: int = 0
var _failed: int = 0

func _initialize() -> void:
	ContentScript.load_all()
	var c = ControllerScript.new()
	var u = c.state.create_unit(&"warrior", 100, UnitScript.LOCATION_BOARD)
	var cursor: int = c.state.next_item_instance_seq
	_check(not c.grant_item(&"unknown_inventory_definition") and c.state.items.is_empty() and c.state.next_item_instance_seq == cursor, "unknown grant is atomic failure")
	_check(not c.grant_item(&"warrior"), "unit definition cannot be granted as item")
	c.state.items.clear()
	c.state.next_item_instance_seq = cursor
	_check(c.grant_item(&"potion_strength"), "shipping item grant succeeds")
	var bad = c.state.create_item(&"unknown_inventory_definition")
	_check(not c.equip_item_by_id(bad.instance_id, u.instance_id) and bad.owner_unit_id == "" and u.equipped_item_ids.is_empty(), "unknown definition equip by id rejects atomically")
	_check(not c.equip_item_at(c.state.items.find(bad), 0) and bad.owner_unit_id == "" and u.equipped_item_ids.is_empty(), "compatibility equip also rejects unknown definition")
	c.state.remove_item(bad.instance_id)
	c.state.next_item_instance_seq = 1
	var count: int = c.state.items.size()
	_check(not c.grant_item(&"potion_strength") and c.state.items.size() == count and c.state.next_item_instance_seq == 1, "grant propagates domain rejection")
	c.free()
	print("=== controller inventory: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed else 0)

func _check(ok: bool, message: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("[FAIL] " + message)
