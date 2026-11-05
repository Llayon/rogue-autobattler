extends SceneTree
## Inventory identity, ownership, lifecycle and failure atomicity contracts.
const StateScript = preload("res://core/progression/run_domain_state.gd")
const UnitScript = preload("res://core/progression/run_unit.gd")
var _passed: int = 0
var _failed: int = 0

func _initialize() -> void:
	var s = StateScript.new()
	var a = s.create_unit(&"warrior", 100, UnitScript.LOCATION_BOARD)
	var b = s.create_unit(&"warrior", 100, UnitScript.LOCATION_BOARD)
	var bench = s.create_unit(&"warrior", 100, UnitScript.LOCATION_BENCH)
	var x = s.create_item(&"sword")
	var y = s.create_item(&"sword")
	var z = s.create_item(&"sword")
	_check(x.instance_id != y.instance_id, "T1 distinct instances of same definition")
	_check(s.remove_item(z.instance_id) and s.next_item_instance_seq == 4, "T2 deletion retains cursor")
	_check(s.create_item(&"sword").instance_id == "item_000004", "T2 consumed identity not reused")
	s.next_item_instance_seq = 100
	_check(s.create_item(&"sword").instance_id == "item_000100", "T3 large cursor gap allocates correctly")
	_check(s.equip_item(x.instance_id, a.instance_id), "equip first owner")
	_check(s.equip_item(x.instance_id, b.instance_id), "T5 transfer is permitted")
	_check(not a.equipped_item_ids.has(x.instance_id) and b.equipped_item_ids.count(x.instance_id) == 1, "T5 exactly one owner after transfer")
	var before: String = _snapshot(s)
	_check(s.equip_item(x.instance_id, b.instance_id) and _snapshot(s) == before, "T10 repeated equip is no-op success")
	_check(s.equip_item(y.instance_id, b.instance_id) and b.equipped_item_ids.size() == 2, "T11 multiple items coexist; no slot replacement")
	before = _snapshot(s)
	_check(not s.equip_item(x.instance_id, bench.instance_id) and _snapshot(s) == before, "T6 board-only compatibility rejects atomically")
	_check(not s.equip_item("item_999999", a.instance_id) and _snapshot(s) == before, "T7 missing item atomic")
	_check(not s.equip_item(x.instance_id, "unit_999999") and _snapshot(s) == before, "T8 missing unit atomic")
	_check(not s.remove_item("item_999999") and _snapshot(s) == before, "T13 invalid remove atomic")
	_check(not s.unequip_item("item_999999") and _snapshot(s) == before, "invalid unequip atomic")
	var identity: String = x.instance_id
	var cursor: int = s.next_item_instance_seq
	_check(s.unequip_item(identity) and s.get_item(identity) == x and x.owner_unit_id == "" and s.next_item_instance_seq == cursor, "T9 unequip preserves object identity and cursor")
	s.items.reverse()
	_check(s.remove_item(y.instance_id) and s.get_item(identity) == x and s.get_item("item_000004") != null, "T12 exact removal after reorder of identical definitions")
	_check(not b.equipped_item_ids.has(y.instance_id), "T14 equipped removal clears owner link")
	before = _snapshot(s)
	_check(s.create_item(&"") == null and _snapshot(s) == before, "empty definition rejected atomically")
	s.next_item_instance_seq = 1
	before = _snapshot(s)
	_check(s.create_item(&"sword") == null and _snapshot(s) == before, "T4 stale cursor rejected without mutation")
	s.next_item_instance_seq = cursor
	var duplicate = s.create_item(&"sword")
	duplicate.instance_id = x.instance_id
	before = _snapshot(s)
	_check(not s.equip_item(x.instance_id, a.instance_id) and _snapshot(s) == before, "T1 duplicate identity rejected atomically")
	s.items.erase(duplicate)
	a.equipped_item_ids.append("item_999999")
	before = _snapshot(s)
	_check(not s.equip_item(x.instance_id, a.instance_id) and _snapshot(s) == before, "dangling equipment rejected atomically")
	a.equipped_item_ids.clear()
	x.owner_unit_id = "unit_999999"
	before = _snapshot(s)
	_check(not s.equip_item(x.instance_id, a.instance_id) and _snapshot(s) == before, "invalid old owner rejected atomically")
	print("=== inventory integrity: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed else 0)

func _snapshot(s) -> String:
	var units: Array = []
	var items: Array = []
	for u in s.units:
		units.append([u.instance_id, u.definition_id, u.current_hp, u.max_hp, u.dead, u.location, u.order, u.equipped_item_ids.duplicate()])
	for it in s.items:
		items.append([it.instance_id, it.definition_id, it.owner_unit_id])
	return var_to_str([units, items, s.next_item_instance_seq, s.next_unit_instance_seq, s.gold, s.meta_modifiers])

func _check(ok: bool, message: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("[FAIL] " + message)
