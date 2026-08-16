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
	print("\n=== run domain state: %d passed, %d failed ===\n" % [_passed, _failed])
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