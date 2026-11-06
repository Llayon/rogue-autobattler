extends SceneTree
## Independent semantic probes: each uses fresh state and survives a broken invariant.
const StateScript = preload("res://core/progression/run_domain_state.gd")
const UnitScript = preload("res://core/progression/run_unit.gd")
var _passed: int = 0
var _failed: int = 0

func _initialize() -> void:
	var selected: String = ""
	if not OS.get_cmdline_user_args().is_empty():
		selected = OS.get_cmdline_user_args()[0]
	for n in range(1, 8):
		if selected == "" or selected == str(n):
			_probe(n)
	print("=== inventory negative probes: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed else 0)

func _probe(n: int) -> void:
	var s = StateScript.new()
	var a = s.create_unit(&"warrior", 100, UnitScript.LOCATION_BOARD)
	var b = s.create_unit(&"warrior", 100, UnitScript.LOCATION_BOARD)
	var x = s.create_item(&"sword")
	var y = s.create_item(&"sword")
	var z = s.create_item(&"sword")
	var ok: bool = false
	match n:
		1:
			y.instance_id = x.instance_id
			ok = not s.is_inventory_valid()
		2:
			s.remove_item(z.instance_id)
			ok = s.next_item_instance_seq == 4
		3:
			s.equip_item(x.instance_id, a.instance_id)
			s.equip_item(x.instance_id, b.instance_id)
			ok = not a.equipped_item_ids.has(x.instance_id) and b.equipped_item_ids.count(x.instance_id) == 1
		4:
			s.move_unit(b.instance_id, UnitScript.LOCATION_BENCH)
			ok = not s.equip_item(x.instance_id, b.instance_id) and x.owner_unit_id == "" and b.equipped_item_ids.is_empty()
		5:
			var id: String = x.instance_id
			s.equip_item(id, a.instance_id)
			s.unequip_item(id)
			ok = s.get_item(id) == x and s.next_item_instance_seq == 4
		6:
			s.items.reverse()
			var id: String = y.instance_id
			s.remove_item(id)
			ok = s.get_item(id) == null and s.get_item(x.instance_id) == x and s.get_item(z.instance_id) == z
		7:
			ok = not s.equip_item(x.instance_id, "unit_999999") and x.owner_unit_id == "" and a.equipped_item_ids.is_empty() and s.next_item_instance_seq == 4
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("[FAIL] NC-I%d" % n)
