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