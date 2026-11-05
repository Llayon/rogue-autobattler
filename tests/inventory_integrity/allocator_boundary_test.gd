extends SceneTree
## Public allocator rejects malformed/exhausted cursors without consuming identity.
const StateScript = preload("res://core/progression/run_domain_state.gd")
var _passed: int = 0
var _failed: int = 0

func _initialize() -> void:
	for cursor in [0, -1, 9223372036854775807]:
		var s = StateScript.new()
		s.next_item_instance_seq = cursor
		_check(s.allocate_item_instance_id() == "" and s.next_item_instance_seq == cursor, "invalid/exhausted direct cursor rejected: " + str(cursor))
		var t = StateScript.new()
		t.next_item_instance_seq = cursor
		_check(t.create_item(&"sword") == null and t.items.is_empty() and t.next_item_instance_seq == cursor, "create cannot wrap invalid/exhausted cursor: " + str(cursor))
	var s = StateScript.new()
	s.create_item(&"sword")
	s.next_item_instance_seq = 1
	_check(s.allocate_item_instance_id() == "" and s.next_item_instance_seq == 1, "direct stale allocator rejects existing identity")
	print("=== allocator boundary: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed else 0)

func _check(ok: bool, message: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("[FAIL] " + message)
