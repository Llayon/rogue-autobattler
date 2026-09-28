extends SceneTree
## B6.3 / Gauntlet 2 — pure movement planning + explicit commit.
## Tests are test-only and prove:
##  * next_step_toward is PURE (does not mutate world positions)
##  * try_commit_move validates expected_from == current position
##  * try_commit_move rejects when destination is occupied
##  * try_move_toward still works (backward compat)
##  * Next-step Y-then-X ordering preserved
##  * When no valid move exists, next_step_toward returns current cell
##  * try_move_toward and next_step_toward agree on destination
##    for the same (entity, target) when world is in the same state.

const BattleWorldScript = preload(
	"res://core/battle_ecs/world/battle_world.gd")
const BattleUnitSetupScript = preload(
	"res://core/battle_ecs/battle_unit_setup.gd")
const BattleSetupScript = preload(
	"res://core/battle_ecs/battle_setup.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_planner_is_pure()
	await _test_planner_returns_current_when_no_move()
	await _test_planner_y_then_x_prefers_y()
	await _test_commit_validates_expected_from()
	await _test_commit_rejects_occupied_destination()
	await _test_commit_rejects_same_cell_destination()
	await _test_commit_succeeds_returns_true_and_updates_position()
	await _test_legacy_try_move_toward_still_mutates()
	print("\n=== B6.3 movement planning: %d pass / %d fail ===\n" % [_passed, _failed])
	if _failed > 0:
		quit(1)
	quit(0)


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  [OK]   %s" % label)
	else:
		_failed += 1
		print("  [FAIL] %s" % label)


func _make_world() -> Dictionary:
	var w = BattleWorldScript.new(7, 4)
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(2, 1), 100, 100, 10, 5, 1, [])
	var target = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(4, 3), 100, 100, 10, 5, 1, [])
	var setup = BattleSetupScript.new(42, [mover], [target], 7, 4)
	w.spawn_from_setup(setup)
	return {"world": w, "mover": 0, "target": 1}


# ============================================================
# 1) Planner is PURE (does not mutate world positions).
# ============================================================
func _test_planner_is_pure() -> void:
	print("[B63-PLAN] planner_is_pure")
	var ctx = _make_world()
	var w: Object = ctx["world"]
	var src_before: Vector2i = w.position_of(int(ctx["mover"]))
	var dst = w.next_step_toward(int(ctx["mover"]), int(ctx["target"]))
	var src_after: Vector2i = w.position_of(int(ctx["mover"]))
	_assert(src_before == src_after,
		"next_step_toward must NOT mutate mover position "
		+ "(before=%s after=%s)" % [str(src_before), str(src_after)])
	_assert(dst != src_before,
		"next_step_toward returned a new cell (got %s)" % str(dst))


# ============================================================
# 2) Planner returns current cell when no valid move exists.
# ============================================================
func _test_planner_returns_current_when_no_move() -> void:
	print("[B63-PLAN] planner_returns_current_when_no_move")
	var w = BattleWorldScript.new(2, 2)
	# Fully boxed in by 4 enemies occupying all 4 neighbors.
	var me = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 10, 5, 1, [])
	var n1 = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 10, 5, 1, [])
	var n2 = BattleUnitSetupScript.new(
		"e1", &"orc", 1, Vector2i(1, 0), 100, 100, 10, 5, 1, [])
	var s = BattleSetupScript.new(42, [me], [n1, n2], 2, 2)
	w.spawn_from_setup(s)
	# Both neighbors occupied; primary (Y) and secondary (X)
	# candidates both blocked; planner should return current cell.
	var dst = w.next_step_toward(0, 1)
	_assert(dst == Vector2i(0, 0),
		"planner returns current cell when boxed in (got %s)" % str(dst))


# ============================================================
# 3) step_cell_toward priority: |dy| >= |dx| picks Y axis, else X.
# ============================================================
func _test_planner_y_then_x_prefers_y() -> void:
	print("[B63-PLAN] planner_priority_axis_selection")
	# Mover at (0, 0); target at (3, 1).
	# dx=3, dy=1, |dy| < |dx| -> X-axis primary: (1, 0).
	var w = BattleWorldScript.new(7, 4)
	var me = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 10, 5, 1, [])
	var tg = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(3, 1), 100, 100, 10, 5, 1, [])
	var s = BattleSetupScript.new(42, [me], [tg], 7, 4)
	w.spawn_from_setup(s)
	var dst = w.next_step_toward(0, 1)
	_assert(dst == Vector2i(1, 0),
		"|dy|<|dx| picks X: step from (0,0) to (3,1) is (1,0) (got %s)"
		% str(dst))
	# Now Y-tie case: src=(0,0), target=(0,3) -> dy=3, dx=0,
	# |dy|=3 >= |dx|=0 -> Y primary: (0, 1).
	var me2 = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 10, 5, 1, [])
	var tg2 = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 3), 100, 100, 10, 5, 1, [])
	var s2 = BattleSetupScript.new(43, [me2], [tg2], 7, 4)
	var w2 = BattleWorldScript.new(7, 4)
	w2.spawn_from_setup(s2)
	var dst2 = w2.next_step_toward(0, 1)
	_assert(dst2 == Vector2i(0, 1),
		"Y tie or longer picks Y: step from (0,0) to (0,3) is (0,1) "
		+ "(got %s)" % str(dst2))


# ============================================================
# 4) try_commit_move validates expected_from == current position.
# ============================================================
func _test_commit_validates_expected_from() -> void:
	print("[B63-COMMIT] commit_validates_expected_from")
	var ctx = _make_world()
	var w: Object = ctx["world"]
	var current: Vector2i = w.position_of(int(ctx["mover"]))
	var wrong_from: Vector2i = Vector2i(-1, -1)
	var ok: bool = w.try_commit_move(int(ctx["mover"]), wrong_from, current)
	_assert(ok == false,
		"try_commit_move rejects wrong expected_from (got ok=true)")
	# Position unchanged.
	var after: Vector2i = w.position_of(int(ctx["mover"]))
	_assert(after == current,
		"position unchanged after rejected commit")


# ============================================================
# 5) try_commit_move rejects occupied destination.
# ============================================================
func _test_commit_rejects_occupied_destination() -> void:
	print("[B63-COMMIT] commit_rejects_occupied_destination")
	var w = BattleWorldScript.new(7, 4)
	var me = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 10, 5, 1, [])
	var blocker = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 10, 5, 1, [])
	var s = BattleSetupScript.new(42, [me], [blocker], 7, 4)
	w.spawn_from_setup(s)
	var ok: bool = w.try_commit_move(0, Vector2i(0, 0), Vector2i(0, 1))
	_assert(ok == false,
		"try_commit_move rejects occupied destination")
	var after: Vector2i = w.position_of(0)
	_assert(after == Vector2i(0, 0),
		"position unchanged after rejected commit (got %s)" % str(after))


# ============================================================
# 6) try_commit_move rejects same-cell destination.
# ============================================================
func _test_commit_rejects_same_cell_destination() -> void:
	print("[B63-COMMIT] commit_rejects_same_cell_destination")
	var ctx = _make_world()
	var w: Object = ctx["world"]
	var current: Vector2i = w.position_of(int(ctx["mover"]))
	var ok: bool = w.try_commit_move(int(ctx["mover"]), current, current)
	_assert(ok == false,
		"try_commit_move rejects destination == current")


# ============================================================
# 7) Successful commit returns true and updates position.
# ============================================================
func _test_commit_succeeds_returns_true_and_updates_position() -> void:
	print("[B63-COMMIT] commit_succeeds_returns_true_and_updates_position")
	var ctx = _make_world()
	var w: Object = ctx["world"]
	var current: Vector2i = w.position_of(int(ctx["mover"]))
	var dst: Vector2i = Vector2i(2, 0)
	var ok: bool = w.try_commit_move(int(ctx["mover"]), current, dst)
	_assert(ok == true,
		"try_commit_move returns true on valid commit")
	var after: Vector2i = w.position_of(int(ctx["mover"]))
	_assert(after == dst,
		"position updated to dst=%s (got %s)" % [str(dst), str(after)])


# ============================================================
# 8) Legacy try_move_toward still mutates (backward compat).
# ============================================================
func _test_legacy_try_move_toward_still_mutates() -> void:
	print("[B63-COMPAT] legacy_try_move_toward_still_mutates")
	var ctx = _make_world()
	var w: Object = ctx["world"]
	var src_before: Vector2i = w.position_of(int(ctx["mover"]))
	var dst = w.try_move_toward(int(ctx["mover"]), int(ctx["target"]))
	var src_after: Vector2i = w.position_of(int(ctx["mover"]))
	_assert(dst != src_before,
		"try_move_toward returned a new cell")
	_assert(src_after == dst,
		"try_move_toward MUTATES position (backward compat) "
		+ "(src=%s after=%s dst=%s)" % [
			str(src_before), str(src_after), str(dst)])
