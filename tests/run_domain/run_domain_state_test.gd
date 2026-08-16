extends SceneTree

## Phase 1 / T1 contract tests for the new canonical live state.
##
## RunDomainState is a dumb data container for the run domain. These
## tests assert:
##   - default scalars match the spec
##   - entity collections accept RunUnit / RunItem
##   - two distinct instances do NOT share mutable defaults
##
## Allocation of instance IDs is covered by T2 and is intentionally
## not tested here.

const RUN_UNIT_PRELOAD: GDScript = preload("res://core/progression/run_unit.gd")
const RUN_ITEM_PRELOAD: GDScript = preload("res://core/progression/run_item.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	_test_new_state_defaults()
	_test_counters_start_at_one()
	_test_units_accept_run_unit()
	_test_items_accept_run_item()
	_test_two_instances_do_not_share_state()
	_test_unit_sequence_starts_at_one()
	_test_item_sequence_starts_at_one()
	_test_unit_and_item_streams_are_independent()
	_test_existing_counter_continues_exactly()
	_test_consumed_id_is_never_reused()
	_test_separate_runs_have_independent_allocators()
	_test_allocator_returns_string_type()
	_test_allocator_handles_more_than_six_digits()
	_test_two_warriors_get_distinct_ids_and_hp()
	_test_create_unit_board_bench_orders()
	_test_get_unit_finds_only_by_instance_id()
	_test_move_board_to_bench_normalises_both_sides()
	_test_move_bench_to_board_insert_at_middle()
	_test_swap_exchanges_only_order_keeps_identity()
	_test_repeated_moves_keep_contiguous_orders()
	_test_move_unknown_instance_id_is_no_op()
	_test_move_with_invalid_location_is_no_op()
	_test_swap_unknown_instance_id_is_no_op()
	_test_hp_stays_with_instance_id_through_moves()
	_test_two_potions_get_distinct_ids()
	_test_create_item_starts_in_inventory()
	_test_equip_item_sets_both_sides_of_link()
	_test_unequip_item_clears_both_sides_of_link()
	_test_two_identical_units_with_two_identical_items()
	_test_equip_re_equip_moves_link_atomically()
	_test_multiple_items_on_one_unit()
	_test_move_equipped_unit_to_bench_keeps_ownership()
	_test_equip_directly_onto_bench_unit_is_rejected()
	_test_remove_equipped_item_clears_owner_link()
	_test_equip_unknown_id_is_no_op()
	_test_remove_unknown_id_is_no_op()
	_test_remove_then_counter_continues()
	print("\n=== run domain state: %d passed, %d failed ===\n" % [_passed, _failed])
	if _failed > 0:
		quit(1)



func _test_unit_sequence_starts_at_one() -> void:
	# Spec: next_unit_instance_seq defaults to 1, allocator produces
	# "unit_000001", "unit_000002", "unit_000003" and counter ends at 4.
	print("[unit seq] allocator produces unit_000001 .. unit_NNNNNN")
	var s = RunDomainState.new()
	_assert(s.allocate_unit_instance_id() == "unit_000001",
		"first allocation == unit_000001")
	_assert(s.allocate_unit_instance_id() == "unit_000002",
		"second allocation == unit_000002")
	_assert(s.allocate_unit_instance_id() == "unit_000003",
		"third allocation == unit_000003")
	_assert(s.next_unit_instance_seq == 4,
		"next_unit_instance_seq == 4 after three allocations")


func _test_item_sequence_starts_at_one() -> void:
	# Spec: next_item_instance_seq defaults to 1, allocator produces
	# "item_000001", "item_000002" and counter ends at 3.
	print("[item seq] allocator produces item_000001 .. item_NNNNNN")
	var s = RunDomainState.new()
	_assert(s.allocate_item_instance_id() == "item_000001",
		"first allocation == item_000001")
	_assert(s.allocate_item_instance_id() == "item_000002",
		"second allocation == item_000002")
	_assert(s.next_item_instance_seq == 3,
		"next_item_instance_seq == 3 after two allocations")


func _test_unit_and_item_streams_are_independent() -> void:
	# Unit allocation must NOT move the item counter and vice versa.
	# This is the cross-stream independence contract.
	print("[streams] unit and item allocators are independent")
	var s = RunDomainState.new()
	_assert(s.allocate_unit_instance_id() == "unit_000001",
		"first unit allocation")
	_assert(s.allocate_item_instance_id() == "item_000001",
		"first item allocation")
	_assert(s.allocate_unit_instance_id() == "unit_000002",
		"second unit allocation")
	_assert(s.allocate_item_instance_id() == "item_000002",
		"second item allocation")
	_assert(s.next_unit_instance_seq == 3,
		"unit counter at 3 (only unit allocations moved it)")
	_assert(s.next_item_instance_seq == 3,
		"item counter at 3 (only item allocations moved it)")


func _test_existing_counter_continues_exactly() -> void:
	# Persisted counter continues exactly from where it stopped. A
	# save/load pair hands the live allocator a non-default
	# counter and the next allocation must be `unit_<N>` / `item_<N>`
	# (NOT `unit_000001` / `item_000001` again).
	print("[persist] existing counter continues exactly")
	var u = RunDomainState.new()
	u.next_unit_instance_seq = 42
	_assert(u.allocate_unit_instance_id() == "unit_000042",
		"unit with counter=42 produces unit_000042")
	_assert(u.next_unit_instance_seq == 43,
		"counter advances to 43")
	var it = RunDomainState.new()
	it.next_item_instance_seq = 17
	_assert(it.allocate_item_instance_id() == "item_000017",
		"item with counter=17 produces item_000017")
	_assert(it.next_item_instance_seq == 18,
		"item counter advances to 18")


func _test_consumed_id_is_never_reused() -> void:
	# The allocator never decrements. A consumed id (whose entity is
	# later "removed") is gone — the next allocation must be the
	# strictly larger sequence. No collision scan, no reuse.
	print("[no reuse] consumed id is never reissued")
	var s = RunDomainState.new()
	var first: String = s.allocate_unit_instance_id()
	var second: String = s.allocate_unit_instance_id()
	_assert(first == "unit_000001", "first allocation == unit_000001")
	_assert(second == "unit_000002", "second allocation == unit_000002")
	# Simulate the run entity being removed (do NOT keep a reference,
	# do NOT mutate the counter): the next allocation is unit_000003.
	var third: String = s.allocate_unit_instance_id()
	_assert(third == "unit_000003",
		"third allocation == unit_000003 (no reuse of unit_000001)")


func _test_separate_runs_have_independent_allocators() -> void:
	# Instance id uniqueness is per-run, not global. Two distinct
	# RunDomainState instances both start at unit_000001.
	print("[per-run isolation] separate runs each get unit_000001")
	var a = RunDomainState.new()
	var b = RunDomainState.new()
	_assert(a.allocate_unit_instance_id() == "unit_000001",
		"run A first unit == unit_000001")
	_assert(b.allocate_unit_instance_id() == "unit_000001",
		"run B first unit == unit_000001")
	# And advancing A does NOT touch B's counter. Two more unit
	# allocations on A: counter goes 1 -> 2 -> 3.
	a.allocate_unit_instance_id()
	a.allocate_unit_instance_id()
	_assert(a.next_unit_instance_seq == 4,
		"run A counter advanced to 4 (three unit allocations)")
	_assert(b.next_unit_instance_seq == 2,
		"run B counter still 2 (one unit allocation, independent)")


func _test_allocator_returns_string_type() -> void:
	# The id type is String, not StringName. Saves, validators and
	# UI all assume String; coercing to StringName here would silently
	# break the contract.
	print("[type] allocator returns String")
	var s = RunDomainState.new()
	var u_id: String = s.allocate_unit_instance_id()
	var i_id: String = s.allocate_item_instance_id()
	_assert(typeof(u_id) == TYPE_STRING, "unit id is TYPE_STRING")
	_assert(typeof(i_id) == TYPE_STRING, "item id is TYPE_STRING")


func _test_allocator_handles_more_than_six_digits() -> void:
	# %06d is a MINIMUM width, not a cap. Beyond 999999 the allocator
	# must still produce a unique monotonic id (e.g. unit_1000000),
	# not overflow or recycle.
	print("[overflow] allocator produces ids beyond 6 digits without wrap")
	var s = RunDomainState.new()
	s.next_unit_instance_seq = 1000000
	var id: String = s.allocate_unit_instance_id()
	_assert(id == "unit_1000000",
		"counter=1000000 produces unit_1000000 (no wrap, no recycle)")
	_assert(s.next_unit_instance_seq == 1000001,
		"counter advances to 1000001")




func _test_two_warriors_get_distinct_ids_and_hp() -> void:
	# Two units with the same definition id must get distinct
	# instance ids and their per-unit state (max_hp here) is per
	# instance, never per definition. This is the central reason
	# we are moving off definition+index identity.
	print("[identity] two warriors get distinct ids and independent hp")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 30, RunUnit.LOCATION_BOARD)
	var b: RunUnit = s.create_unit(&"warrior", 80, RunUnit.LOCATION_BOARD)
	_assert(a.instance_id == "unit_000001", "first warrior id")
	_assert(b.instance_id == "unit_000002", "second warrior id")
	_assert(a.definition_id == &"warrior" and b.definition_id == &"warrior",
		"both have definition_id = warrior")
	_assert(a.max_hp == 30 and b.max_hp == 80,
		"max_hp is per instance (30 / 80)")
	_assert(a != b, "two distinct RunUnit instances")


func _test_create_unit_board_bench_orders() -> void:
	# create_unit at LOCATION_BOARD appends in order 0..N-1.
	# create_unit at LOCATION_BENCH does the same independently.
	print("[create] create_unit assigns contiguous orders per location")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var b: RunUnit = s.create_unit(&"archer", 80, RunUnit.LOCATION_BOARD)
	var c: RunUnit = s.create_unit(&"mage", 60, RunUnit.LOCATION_BENCH)
	_assert(a.order == 0 and a.location == RunUnit.LOCATION_BOARD,
		"first board unit order=0")
	_assert(b.order == 1 and b.location == RunUnit.LOCATION_BOARD,
		"second board unit order=1")
	_assert(c.order == 0 and c.location == RunUnit.LOCATION_BENCH,
		"first bench unit order=0 (independent stream)")
	_assert(s.get_board_units().size() == 2, "2 board units")
	_assert(s.get_bench_units().size() == 1, "1 bench unit")


func _test_get_unit_finds_only_by_instance_id() -> void:
	# Definition id is NOT identity; get_unit must only resolve by
	# instance id. Two warriors created above differ only by
	# instance id.
	print("[get_unit] resolves by instance id only")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 30, RunUnit.LOCATION_BOARD)
	var b: RunUnit = s.create_unit(&"warrior", 80, RunUnit.LOCATION_BENCH)
	_assert(s.get_unit(a.instance_id) == a, "find by a.instance_id")
	_assert(s.get_unit(b.instance_id) == b, "find by b.instance_id")
	_assert(s.get_unit("") == null, "empty id -> null")
	_assert(s.get_unit("unit_999999") == null, "unknown id -> null")


func _test_move_board_to_bench_normalises_both_sides() -> void:
	# Move B from board[1] to bench. After the move:
	#   board: A(0), C(2 -> 1) -> contiguous 0..N-1
	#   bench: B(0)
	print("[move board->bench] both sides normalised 0..N-1")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var b: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var c: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	_assert(s.move_unit(b.instance_id, RunUnit.LOCATION_BENCH),
		"move b to bench")
	_assert(a.order == 0, "a stays at order 0")
	_assert(c.order == 1, "c shifts down to order 1 (was 2)")
	_assert(b.location == RunUnit.LOCATION_BENCH and b.order == 0,
		"b lands at bench order 0")
	var board: Array[RunUnit] = s.get_board_units()
	_assert(board.size() == 2 and board[0] == a and board[1] == c,
		"board is [A, C] in order")
	var bench: Array[RunUnit] = s.get_bench_units()
	_assert(bench.size() == 1 and bench[0] == b, "bench is [B]")


func _test_move_bench_to_board_insert_at_middle() -> void:
	# After move_board_to_bench above, take B from bench back to
	# board at order 1. Expected board: A(0), B(1), C(2). Bench
	# becomes empty.
	print("[move bench->board] insertion at middle shifts orders correctly")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var b: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var c: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	s.move_unit(b.instance_id, RunUnit.LOCATION_BENCH)
	_assert(s.move_unit(b.instance_id, RunUnit.LOCATION_BOARD, 1),
		"insert b back at board order 1")
	_assert(a.order == 0, "a stays at 0")
	_assert(b.order == 1, "b lands at 1")
	_assert(c.order == 2, "c shifts up to 2")
	_assert(s.get_bench_units().is_empty(), "bench is empty")
	var board: Array[RunUnit] = s.get_board_units()
	_assert(board.size() == 3 and board[0] == a and board[1] == b 			and board[2] == c, "board is [A, B, C] in order")


func _test_swap_exchanges_only_order_keeps_identity() -> void:
	# Swap two board units. Identity, definition, max_hp, equipment
	# are unchanged; only `order` is exchanged.
	print("[swap] exchanges order only, keeps identity and hp")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var b: RunUnit = s.create_unit(&"archer", 60, RunUnit.LOCATION_BOARD)
	var pre_a_order: int = a.order
	var pre_b_order: int = b.order
	var pre_a_equip: Array = a.equipped_item_ids.duplicate()
	_assert(s.swap_units(a.instance_id, b.instance_id), "swap ok")
	_assert(a.instance_id == "unit_000001", "a instance_id unchanged")
	_assert(b.instance_id == "unit_000002", "b instance_id unchanged")
	_assert(a.definition_id == &"warrior", "a definition_id unchanged")
	_assert(b.definition_id == &"archer", "b definition_id unchanged")
	_assert(a.max_hp == 100 and b.max_hp == 60, "max_hp unchanged")
	_assert(a.equipped_item_ids == pre_a_equip, "a equipment unchanged")
	_assert(a.order == pre_b_order, "a order is now b's old order")
	_assert(b.order == pre_a_order, "b order is now a's old order")


func _test_repeated_moves_keep_contiguous_orders() -> void:
	# After a series of create / move / swap / move, both board and
	# bench must have contiguous orders 0..N-1, no holes, no
	# duplicates.
	print("[invariant] repeated moves preserve contiguous orders")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var b: RunUnit = s.create_unit(&"archer", 80, RunUnit.LOCATION_BOARD)
	var c: RunUnit = s.create_unit(&"mage", 60, RunUnit.LOCATION_BOARD)
	var d: RunUnit = s.create_unit(&"cleric", 50, RunUnit.LOCATION_BENCH)
	s.move_unit(c.instance_id, RunUnit.LOCATION_BENCH)
	s.swap_units(a.instance_id, d.instance_id)  # mixed locations -> fails
	# d is on bench, a is on board; swap should fail without mutation.
	var board: Array[RunUnit] = s.get_board_units()
	var bench: Array[RunUnit] = s.get_bench_units()
	# After c moved to bench: board [A(0), B(1)], bench [D(0), C(1)]
	_assert(board.size() == 2, "board has 2")
	for i in board.size():
		_assert(board[i].order == i,
			"board[%d].order == %d (was %d)" % [i, i, board[i].order])
	_assert(bench.size() == 2, "bench has 2")
	for i in bench.size():
		_assert(bench[i].order == i,
			"bench[%d].order == %d (was %d)" % [i, i, bench[i].order])
	# A positive swap test that respects the same-location rule.
	var e: RunUnit = s.create_unit(&"rogue", 70, RunUnit.LOCATION_BOARD)
	# Now board: A(0), B(1), E(2). Swap B and E.
	_assert(s.swap_units(b.instance_id, e.instance_id), "swap b and e on board")
	board = s.get_board_units()
	for i in board.size():
		_assert(board[i].order == i, "after second swap, board contiguous")
	# Identity untouched.
	_assert(s.get_unit("unit_000001") == a, "unit_000001 still a")
	_assert(s.get_unit("unit_000005") == e, "unit_000005 still e")


func _test_move_unknown_instance_id_is_no_op() -> void:
	print("[no-op] move with unknown instance id does not mutate state")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var pre_units: int = s.units.size()
	var pre_a_order: int = a.order
	_assert(not s.move_unit("unit_999999", RunUnit.LOCATION_BENCH),
		"unknown id -> false")
	_assert(s.units.size() == pre_units, "units count unchanged")
	_assert(a.order == pre_a_order, "a.order unchanged")


func _test_move_with_invalid_location_is_no_op() -> void:
	print("[no-op] move with invalid location does not mutate state")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var pre_order: int = a.order
	var pre_loc: int = a.location
	_assert(not s.move_unit(a.instance_id, 7),
		"invalid location 7 -> false")
	_assert(not s.move_unit(a.instance_id, -1),
		"invalid location -1 -> false")
	_assert(a.order == pre_order, "a.order unchanged")
	_assert(a.location == pre_loc, "a.location unchanged")


func _test_swap_unknown_instance_id_is_no_op() -> void:
	print("[no-op] swap with unknown id does not mutate state")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var b: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var pre_a: int = a.order
	var pre_b: int = b.order
	_assert(not s.swap_units("unit_999999", b.instance_id),
		"first id unknown -> false")
	_assert(not s.swap_units(a.instance_id, "unit_999999"),
		"second id unknown -> false")
	_assert(not s.swap_units(a.instance_id, a.instance_id),
		"same id -> false")
	_assert(a.order == pre_a and b.order == pre_b, "orders unchanged")
	# Mixed-location swap fails.
	var c: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BENCH)
	_assert(not s.swap_units(a.instance_id, c.instance_id),
		"mixed locations -> false")


func _test_hp_stays_with_instance_id_through_moves() -> void:
	# The very point of stable instance identity: two warriors with
	# different max_hp must keep their hp values across moves and
	# swaps. Under the old definition+index model, hp at a board
	# slot would have followed the slot, not the unit.
	print("[hp identity] hp sticks to instance id across move + swap")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 30, RunUnit.LOCATION_BOARD)
	var b: RunUnit = s.create_unit(&"warrior", 80, RunUnit.LOCATION_BOARD)
	# Move A to bench.
	s.move_unit(a.instance_id, RunUnit.LOCATION_BENCH)
	# HP values follow the instance, not the location or the slot.
	_assert(s.get_unit("unit_000001").max_hp == 30,
		"unit_000001 max_hp still 30 after move to bench")
	_assert(s.get_unit("unit_000002").max_hp == 80,
		"unit_000002 max_hp still 80 (it never moved)")
	# Bring A back to board.
	s.move_unit(a.instance_id, RunUnit.LOCATION_BOARD, 0)
	_assert(s.get_unit("unit_000001").max_hp == 30,
		"unit_000001 max_hp still 30 after move back to board")
	_assert(s.get_unit("unit_000002").max_hp == 80,
		"unit_000002 max_hp still 80 (b never moved)")
	# Now also test current_hp, which is the canonical sentinel
	# right after create_unit. Both should still be -1.
	_assert(s.get_unit("unit_000001").current_hp == -1,
		"unit_000001 current_hp is still sentinel -1")
	_assert(s.get_unit("unit_000002").current_hp == -1,
		"unit_000002 current_hp is still sentinel -1")
	# Swap A and B (both on board).
	s.swap_units(a.instance_id, b.instance_id)
	_assert(s.get_unit("unit_000001").max_hp == 30,
		"unit_000001 max_hp still 30 after swap")
	_assert(s.get_unit("unit_000002").max_hp == 80,
		"unit_000002 max_hp still 80 after swap")





func _test_two_potions_get_distinct_ids() -> void:
	# Same definition id, two distinct identities. Mirrors the
	# warrior-instance test for items.
	print("[identity] two potions get distinct ids")
	var s = RunDomainState.new()
	var a: RunItem = s.create_item(&"potion")
	var b: RunItem = s.create_item(&"potion")
	_assert(a.instance_id == "item_000001", "first potion id")
	_assert(b.instance_id == "item_000002", "second potion id")
	_assert(a.definition_id == &"potion" and b.definition_id == &"potion",
		"both have definition_id = potion")
	_assert(a != b, "two distinct RunItem instances")


func _test_create_item_starts_in_inventory() -> void:
	# A newly created item is in inventory; owner_unit_id == "".
	print("[create] new item is in inventory")
	var s = RunDomainState.new()
	var it: RunItem = s.create_item(&"sword")
	_assert(it.owner_unit_id == "", "owner_unit_id starts as empty")
	var inv: Array[RunItem] = s.get_inventory_items()
	_assert(inv.size() == 1 and inv[0] == it,
		"get_inventory_items contains the new item")


func _test_equip_item_sets_both_sides_of_link() -> void:
	# After equip, item.owner_unit_id and unit.equipped_item_ids
	# both point at each other.
	print("[equip] both sides of the equipment link are set")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var sword: RunItem = s.create_item(&"sword")
	_assert(s.equip_item(sword.instance_id, a.instance_id), "equip ok")
	_assert(sword.owner_unit_id == a.instance_id,
		"sword.owner_unit_id == a.instance_id")
	_assert(a.equipped_item_ids.size() == 1
			and a.equipped_item_ids[0] == sword.instance_id,
		"a.equipped_item_ids contains sword")
	# Equipped items view.
	var equipped: Array[RunItem] = s.get_equipped_items(a.instance_id)
	_assert(equipped.size() == 1 and equipped[0] == sword,
		"get_equipped_items returns [sword]")
	# Inventory no longer contains the item.
	var inv: Array[RunItem] = s.get_inventory_items()
	_assert(inv.is_empty(), "inventory is empty after equip")


func _test_unequip_item_clears_both_sides_of_link() -> void:
	# After unequip, both sides are cleared.
	print("[unequip] both sides of the link are cleared")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var potion: RunItem = s.create_item(&"potion")
	s.equip_item(potion.instance_id, a.instance_id)
	_assert(s.unequip_item(potion.instance_id), "unequip ok")
	_assert(potion.owner_unit_id == "",
		"potion.owner_unit_id cleared")
	_assert(a.equipped_item_ids.is_empty(),
		"a.equipped_item_ids no longer contains potion")
	# Now back in inventory.
	var inv: Array[RunItem] = s.get_inventory_items()
	_assert(inv.size() == 1 and inv[0] == potion,
		"potion is back in inventory")


func _test_two_identical_units_with_two_identical_items() -> void:
	# Two warriors (same definition) with two potions (same
	# definition). Each item's identity is its instance id, not
	# its definition. Cross-equipping must not confuse them.
	print("[two-of-each] identical units and items stay independent")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var b: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var pa: RunItem = s.create_item(&"potion")
	var pb: RunItem = s.create_item(&"potion")
	s.equip_item(pa.instance_id, a.instance_id)
	s.equip_item(pb.instance_id, b.instance_id)
	_assert(pa.owner_unit_id == a.instance_id, "pa -> a")
	_assert(pb.owner_unit_id == b.instance_id, "pb -> b")
	_assert(a.equipped_item_ids[0] == pa.instance_id, "a holds pa")
	_assert(b.equipped_item_ids[0] == pb.instance_id, "b holds pb")
	# Swap ownership atomically.
	s.equip_item(pa.instance_id, b.instance_id)
	_assert(pa.owner_unit_id == b.instance_id, "pa now -> b")
	_assert(pb.owner_unit_id == b.instance_id, "pb still -> b")
	_assert(not a.equipped_item_ids.has(pa.instance_id),
		"a no longer lists pa")
	_assert(b.equipped_item_ids.has(pa.instance_id),
		"b lists pa")
	_assert(b.equipped_item_ids.has(pb.instance_id),
		"b still lists pb")


func _test_equip_re_equip_moves_link_atomically() -> void:
	# Re-equip from A to B must, in a single call, leave both A
	# and B consistent with item.owner_unit_id == B.instance_id
	# and item.instance_id in B.equipped_item_ids.
	print("[re-equip] moves the link atomically across two units")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var b: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var ring: RunItem = s.create_item(&"ring")
	s.equip_item(ring.instance_id, a.instance_id)
	# Snapshot pre-reequip.
	_assert(ring.owner_unit_id == a.instance_id,
		"pre: ring on a")
	_assert(a.equipped_item_ids.has(ring.instance_id),
		"pre: a has ring")
	_assert(not b.equipped_item_ids.has(ring.instance_id),
		"pre: b has no ring")
	s.equip_item(ring.instance_id, b.instance_id)
	_assert(ring.owner_unit_id == b.instance_id,
		"post: ring on b")
	_assert(not a.equipped_item_ids.has(ring.instance_id),
		"post: a no longer has ring")
	_assert(b.equipped_item_ids.has(ring.instance_id),
		"post: b has ring")
	# A's other state (definition, hp) untouched.
	_assert(a.definition_id == &"warrior", "a definition_id unchanged")
	_assert(a.max_hp == 100, "a max_hp unchanged")


func _test_multiple_items_on_one_unit() -> void:
	# One unit can hold multiple items. The domain does not
	# introduce a one-item restriction.
	print("[multi] one unit can hold several items")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var it1: RunItem = s.create_item(&"sword")
	var it2: RunItem = s.create_item(&"shield")
	var it3: RunItem = s.create_item(&"ring")
	s.equip_item(it1.instance_id, a.instance_id)
	s.equip_item(it2.instance_id, a.instance_id)
	s.equip_item(it3.instance_id, a.instance_id)
	_assert(a.equipped_item_ids.size() == 3,
		"a holds 3 items")
	# Ordering follows items[] insertion order.
	_assert(a.equipped_item_ids[0] == it1.instance_id, "first = sword")
	_assert(a.equipped_item_ids[1] == it2.instance_id, "second = shield")
	_assert(a.equipped_item_ids[2] == it3.instance_id, "third = ring")
	_assert(s.get_equipped_items(a.instance_id).size() == 3,
		"get_equipped_items returns 3")


func _test_move_equipped_unit_to_bench_keeps_ownership() -> void:
	# The CRITICAL Phase 1 acceptance test. When an equipped unit
	# moves board -> bench, the item's owner_unit_id stays bound
	# to that unit's instance id. A unit that happens to occupy
	# the old board order must NOT inherit the item.
	print("[bench-move] equipment stays with the unit, not the position")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var b: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var ring: RunItem = s.create_item(&"ring")
	s.equip_item(ring.instance_id, a.instance_id)
	# Move a (order 0) to bench; b shifts up to order 0.
	_assert(s.move_unit(a.instance_id, RunUnit.LOCATION_BENCH), "move a to bench")
	# Item still owned by a.
	_assert(ring.owner_unit_id == a.instance_id,
		"ring still owned by a after bench move")
	_assert(a.equipped_item_ids.has(ring.instance_id),
		"a still lists ring in equipped_item_ids")
	# b occupies order 0 on the board but does NOT have the ring.
	_assert(b.location == RunUnit.LOCATION_BOARD and b.order == 0,
		"b now at board order 0")
	_assert(not b.equipped_item_ids.has(ring.instance_id),
		"b does NOT inherit ring from position")
	# equipped_items view: a still has it, b has nothing.
	_assert(s.get_equipped_items(a.instance_id).size() == 1,
		"a has 1 equipped item")
	_assert(s.get_equipped_items(b.instance_id).is_empty(),
		"b has 0 equipped items")


func _test_equip_directly_onto_bench_unit_is_rejected() -> void:
	# Phase 1 keeps the legacy gameplay rule: equipping is
	# board-only. A bench unit cannot accept a new item.
	print("[reject] bench unit cannot be equipped directly")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BENCH)
	var potion: RunItem = s.create_item(&"potion")
	_assert(not s.equip_item(potion.instance_id, a.instance_id),
		"equip onto bench unit returns false")
	_assert(potion.owner_unit_id == "",
		"item owner_unit_id unchanged (still empty)")
	_assert(a.equipped_item_ids.is_empty(),
		"unit equipped_item_ids unchanged (still empty)")
	_assert(s.get_inventory_items().size() == 1,
		"item still in inventory")


func _test_remove_equipped_item_clears_owner_link() -> void:
	# remove_item on an equipped item also drops the owner link.
	print("[remove] removing an equipped item clears the owner link")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var potion: RunItem = s.create_item(&"potion")
	s.equip_item(potion.instance_id, a.instance_id)
	_assert(s.remove_item(potion.instance_id), "remove ok")
	_assert(s.get_item(potion.instance_id) == null,
		"item is gone")
	_assert(not a.equipped_item_ids.has(potion.instance_id),
		"owner link cleared")
	_assert(s.get_equipped_items(a.instance_id).is_empty(),
		"a has 0 equipped items")
	# Sequence counter does NOT decrement.
	_assert(s.next_item_instance_seq == 2,
		"counter is still 2 (no decrement)")


func _test_equip_unknown_id_is_no_op() -> void:
	# equip_item with an unknown item id or unknown unit id does
	# not mutate state and returns false.
	print("[no-op] equip with unknown id is no-op")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var potion: RunItem = s.create_item(&"potion")
	# Snapshot.
	var pre_seq: int = s.next_item_instance_seq
	_assert(not s.equip_item("item_999999", a.instance_id),
		"unknown item id -> false")
	_assert(not s.equip_item(potion.instance_id, "unit_999999"),
		"unknown unit id -> false")
	_assert(potion.owner_unit_id == "", "potion owner still empty")
	_assert(a.equipped_item_ids.is_empty(), "a still has no items")
	_assert(s.next_item_instance_seq == pre_seq, "counter unchanged")


func _test_remove_unknown_id_is_no_op() -> void:
	print("[no-op] remove with unknown id is no-op")
	var s = RunDomainState.new()
	var a: RunUnit = s.create_unit(&"warrior", 100, RunUnit.LOCATION_BOARD)
	var potion: RunItem = s.create_item(&"potion")
	s.equip_item(potion.instance_id, a.instance_id)
	var pre_items: int = s.items.size()
	var pre_seq: int = s.next_item_instance_seq
	_assert(not s.remove_item("item_999999"), "unknown id -> false")
	_assert(s.items.size() == pre_items, "items count unchanged")
	_assert(potion.owner_unit_id == a.instance_id,
		"potion still owned by a")
	_assert(s.next_item_instance_seq == pre_seq,
		"sequence counter unchanged")
	_assert(a.equipped_item_ids.has(potion.instance_id),
		"a still lists potion")


func _test_remove_then_counter_continues() -> void:
	# Removing item_000001 does NOT make the allocator reuse
	# that id. Next allocation continues from next_item_instance_seq.
	print("[no reuse] counter continues after remove")
	var s = RunDomainState.new()
	var a: RunItem = s.create_item(&"potion")
	var b: RunItem = s.create_item(&"potion")
	s.remove_item(a.instance_id)
	var next: RunItem = s.create_item(&"potion")
	_assert(next.instance_id == "item_000003",
		"next allocation is item_000003 (a is not reused)")
	quit(0)


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  [OK]   %s" % label)
	else:
		_failed += 1
		print("  [FAIL] %s" % label)


func _test_new_state_defaults() -> void:
	print("[defaults] new state matches spec")
	var s = RunDomainState.new()
	_assert(s.seed == 0, "seed == 0")
	_assert(s.round_index == 1, "round_index == 1")
	_assert(s.gold == 10, "gold == 10")
	_assert(s.xp == 0, "xp == 0")
	_assert(s.level == 1, "level == 1")
	_assert(s.lives == 1, "lives == 1")
	_assert(s.wins == 0, "wins == 0")
	_assert(s.losses == 0, "losses == 0")
	_assert(s.units_killed == 0, "units_killed == 0")
	_assert(s.current_encounter_id == -1,
		"current_encounter_id == -1 (map not started)")
	_assert(s.just_visited_merchant == false,
		"just_visited_merchant == false")
	_assert(typeof(s.meta_modifiers) == TYPE_DICTIONARY,
		"meta_modifiers is Dictionary")


func _test_counters_start_at_one() -> void:
	print("[counters] sequence counters start at first unused")
	var s = RunDomainState.new()
	_assert(s.next_unit_instance_seq == 1,
		"next_unit_instance_seq == 1 (first unused)")
	_assert(s.next_item_instance_seq == 1,
		"next_item_instance_seq == 1 (first unused)")


func _test_units_accept_run_unit() -> void:
	print("[units] Array[RunUnit] accepts and preserves RunUnit instances")
	var s = RunDomainState.new()
	var u: RunUnit = RUN_UNIT_PRELOAD.new()
	u.instance_id = "unit_000001"
	u.definition_id = &"warrior"
	s.units.append(u)
	_assert(s.units.size() == 1, "one unit appended")
	var back: RunUnit = s.units[0]
	_assert(back != null and back.instance_id == "unit_000001",
		"appended unit is the same RunUnit (instance_id roundtrips)")


func _test_items_accept_run_item() -> void:
	print("[items] Array[RunItem] accepts and preserves RunItem instances")
	var s = RunDomainState.new()
	var it: RunItem = RUN_ITEM_PRELOAD.new()
	it.instance_id = "item_000001"
	it.definition_id = &"sword"
	s.items.append(it)
	_assert(s.items.size() == 1, "one item appended")
	var back: RunItem = s.items[0]
	_assert(back != null and back.instance_id == "item_000001",
		"appended item is the same RunItem (instance_id roundtrips)")


func _test_two_instances_do_not_share_state() -> void:
	# This is the contract that protects us from the "shared mutable
	# default" footgun. If `units = []` is declared at class scope
	# without a per-instance _init allocation, all instances share
	# the same Array and one run's roster would leak into another.
	print("[isolation] two instances have independent collections")
	var a = RunDomainState.new()
	var b = RunDomainState.new()
	# Independence is proved by the mutation tests below. GDScript
	# Array / Dictionary `!=` is element-wise (compares contents),
	# so two empty Arrays compare equal regardless of identity.
	# We do not assert pointer equality here; mutation is the proof.
	# Mutate one side; the other must not change.
	var u: RunUnit = RUN_UNIT_PRELOAD.new()
	u.instance_id = "unit_000001"
	a.units.append(u)
	a.meta_modifiers["bonus"] = 5
	a.encounter_visited_ids.append(7)
	# Mutation tests are the authoritative isolation proof. GDScript
	# Array / Dictionary `!=` is element-wise and `is_same` is not
	# callable on typed Array, so a direct pointer test is unreliable.
	# We prove independence by mutating one instance and verifying the
	# other is unaffected.
	_assert(b.units.size() == 0, "b.units untouched after a.units.append")
	_assert(b.items.size() == 0, "b.items untouched")
	_assert(not b.meta_modifiers.has("bonus"),
		"b.meta_modifiers untouched after a.meta_modifiers assignment")
	_assert(b.encounter_visited_ids.size() == 0,
		"b.encounter_visited_ids untouched after a.append")
	# Conversely: mutating b must not leak into a.
	var it: RunItem = RUN_ITEM_PRELOAD.new()
	it.instance_id = "item_000099"
	it.definition_id = &"shield"
	b.items.append(it)
	_assert(a.items.size() == 0, "a.items untouched after b.items.append")