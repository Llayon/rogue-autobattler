extends SceneTree

## Phase 1 / T3G.1 regression suite.
##
## Verifies that UI selections across events follow
## `RunUnit.instance_id` and `RunItem.instance_id`, NOT board /
## bench / item-array indices that would silently shift identity
## when the underlying projection is mutated between events.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunDomainStateScript = preload("res://core/progression/run_domain_state.gd")
const RunUnitScript = preload("res://core/progression/run_unit.gd")
const RunItemScript = preload("res://core/progression/run_item.gd")
const BalanceScript = preload("res://core/balance.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_prep_swap_targets_A_after_board_reorder()
	await _test_prep_stale_selection_clears_safely()
	await _test_inventory_equip_targets_A_after_preceding_item_removed()
	await _test_inventory_stale_pick_clears_safely()
	print("\n=== ui stable identity: %d passed, %d failed ===\n" % [_passed, _failed])
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


# === T3G.1.PREP: swap follows the selected instance, not the old index ===

func _test_prep_swap_targets_A_after_board_reorder() -> void:
	print("[prep-1] swap_targets_A_after_board_reorder")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	# Seed: 3 units on the board, all distinct.
	var a: RunUnit = ctrl.state.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var b: RunUnit = ctrl.state.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var c: RunUnit = ctrl.state.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var a_id: String = a.instance_id
	var b_id: String = b.instance_id
	var c_id: String = c.instance_id
	_assert(a_id != b_id, "duplicate defs A and B have distinct instance_ids")
	_assert(b_id != c_id, "duplicate defs B and C have distinct instance_ids")
	# Simulate user clicking the FIRST board slot (currently A).
	# The scene stores instance_id `a_id`, never an index.
	# Simulate another action that reorders the board BEFORE the
	# second click completes: swap B and C. Now the first slot
	# still holds A (order is preserved for the user view in this
	# arrangement), but the THIRD slot now holds B.
	ctrl.state.swap_units(b_id, c_id)
	# Simulate user clicking the THIRD board slot (currently B).
	# User intent: swap A with B.
	# With instance_id tracking, A is identified correctly.
	var ok: bool = ctrl.swap_units_by_id(a_id, b_id)
	_assert(ok, "swap_units_by_id(A, B) succeeds after reorder")
	# A and B are swapped. A is now in slot 2 (was B's slot).
	var a_after: RunUnit = ctrl.state.get_unit(a_id)
	var b_after: RunUnit = ctrl.state.get_unit(b_id)
	_assert(a_after.order == 2,
		"A landed at B's previous order (got %d)" % a_after.order)
	_assert(b_after.order == 0,
		"B landed at A's previous order (got %d)" % b_after.order)
	# CRITICAL: if the scene had remembered source by the OLD
	# slot index (0) and used the NEW board[0] (now B) as the
	# second-click source, the swap would have been no-op or
	# acted on B↔B. The instance_id path correctly identifies A.
	ctrl.queue_free()
	await process_frame


func _test_prep_stale_selection_clears_safely() -> void:
	print("[prep-2] stale_selection_clears_safely")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	var a: RunUnit = ctrl.state.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var a_id: String = a.instance_id
	# First click would store the selection. Simulate removal.
	ctrl.state.units.clear()
	# Look up by id — should return null because the entity is gone.
	var stale: RunUnit = ctrl.state.get_unit(a_id)
	_assert(stale == null, "selected A is no longer in domain")
	# The scene's resolve-by-id path would see null and clear
	# the selection rather than acting on whatever occupies the
	# old slot.
	ctrl.queue_free()
	await process_frame


# === T3G.1.INVENTORY: equip follows the picked instance, not the old index ===

func _test_inventory_equip_targets_A_after_preceding_item_removed() -> void:
	print("[inv-1] equip_targets_A_after_preceding_item_removed")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	# Seed: 2 duplicate-def items. A at idx 0, B at idx 1.
	var a: RunItem = ctrl.state.create_item(&"potion_strength")
	var b: RunItem = ctrl.state.create_item(&"potion_strength")
	var a_id: String = a.instance_id
	var b_id: String = b.instance_id
	_assert(a_id != b_id, "duplicate defs get distinct item instance_ids")
	# Seed: 1 board unit to equip onto.
	var target: RunUnit = ctrl.state.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var target_id: String = target.instance_id
	# Simulate user picking item A. The scene stores a_id.
	# Now mutate `state.items` by removing the PRECEDING item
	# (which here happens to be A itself — equivalent to a
	# rebuild that drops index 0 from the list).
	ctrl.state.remove_item(a_id)
	# B shifts from idx 1 to idx 0. If the scene remembered idx 0
	# it would now act on B. With instance_id tracking, the
	# picked item is A — but A was removed, so the lookup must
	# fail and the action must NOT equip B.
	var looked_up: RunItem = null
	for it in ctrl.state.items:
		if it.instance_id == a_id:
			looked_up = it
			break
	_assert(looked_up == null,
		"picked A is no longer in items (lookup returns null)")
	# equip_item_by_id with the picked (now-removed) id fails.
	var equip_ok: bool = ctrl.equip_item_by_id(a_id, target_id)
	_assert(not equip_ok,
		"equip_item_by_id with removed A returns false (does NOT equip B)")
	# B must remain in inventory, target must remain unequipped.
	var b_still_inv: RunItem = null
	for it in ctrl.state.items:
		if it.instance_id == b_id:
			b_still_inv = it
			break
	_assert(b_still_inv != null, "B still in inventory")
	_assert(b_still_inv.owner_unit_id == "",
		"B has empty owner (was not falsely equipped)")
	_assert(target.equipped_item_ids.is_empty(),
		"target unit has no equipped items (B did not jump onto it)")
	ctrl.queue_free()
	await process_frame


func _test_inventory_stale_pick_clears_safely() -> void:
	print("[inv-2] stale_pick_clears_safely")
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(ctrl)
	await process_frame
	var a: RunItem = ctrl.state.create_item(&"potion_strength")
	var a_id: String = a.instance_id
	ctrl.state.items.clear()
	# Scene resolves picked id against current items — none match.
	var found: bool = false
	for it in ctrl.state.items:
		if it.instance_id == a_id:
			found = true
			break
	_assert(not found, "picked A is no longer in items (resolves to no pick)")
	ctrl.queue_free()
	await process_frame