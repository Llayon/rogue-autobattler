extends SceneTree

## Tests for the RunUnit.is_alive() sentinel semantics. Sentinel
## is exactly `current_hp == -1` (means "use max_hp"). `current_hp <
## -1` is invalid state and rejected by the validator; this method
## returns `false` for it.

const RunUnitScript = preload("res://core/progression/run_unit.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	print("\n=== run unit is_alive tests ===\n")
	_test_current_hp_minus_one_is_alive()
	_test_current_hp_zero_is_dead()
	_test_current_hp_positive_is_alive()
	_test_dead_flag_overrides_positive_hp()
	_test_dead_flag_overrides_minus_one()
	print("\n=== run unit is_alive: %d passed, %d failed ===\n" % [_passed, _failed])
	if _failed > 0:
		quit(1)
	else:
		quit(0)


func _assert(condition: bool, message: String) -> void:
	if condition:
		_passed += 1
		print("  [OK]   %s" % message)
	else:
		_failed += 1
		printerr("  [FAIL] %s" % message)


func _make_unit(current_hp: int, max_hp: int, dead: bool) -> RefCounted:
	var u: RefCounted = RunUnitScript.new()
	u.instance_id = "unit_000001"
	u.definition_id = &"warrior"
	u.current_hp = current_hp
	u.max_hp = max_hp
	u.dead = dead
	return u


func _test_current_hp_minus_one_is_alive() -> void:
	print("[is_alive] current_hp == -1 -> alive (sentinel)")
	var u: RefCounted = _make_unit(-1, 100, false)
	_assert(u.is_alive() == true, "current_hp=-1, dead=false -> is_alive() == true")


func _test_current_hp_zero_is_dead() -> void:
	print("[is_alive] current_hp == 0 -> dead")
	var u: RefCounted = _make_unit(0, 100, false)
	_assert(u.is_alive() == false, "current_hp=0, dead=false -> is_alive() == false")


func _test_current_hp_positive_is_alive() -> void:
	print("[is_alive] current_hp > 0 -> alive")
	var u: RefCounted = _make_unit(1, 100, false)
	_assert(u.is_alive() == true, "current_hp=1, dead=false -> is_alive() == true")


func _test_dead_flag_overrides_positive_hp() -> void:
	print("[is_alive] dead=true overrides positive HP")
	var u: RefCounted = _make_unit(100, 100, true)
	_assert(u.is_alive() == false, "current_hp=100, dead=true -> is_alive() == false")


func _test_dead_flag_overrides_minus_one() -> void:
	print("[is_alive] dead=true overrides -1 sentinel")
	var u: RefCounted = _make_unit(-1, 100, true)
	_assert(u.is_alive() == false, "current_hp=-1, dead=true -> is_alive() == false")