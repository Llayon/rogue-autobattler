extends SceneTree

## Phase 1 / T3E contract tests for the legacy battle participant
## bridge.
##
## The bridge is a transient, battle-lifetime one-to-one map
## between Combatant references and RunUnit instance ids. Tests
## prove:
##   - basic forward / reverse lookup
##   - duplicate bindings are rejected (no silent overwrite)
##   - two warriors with the same definition do not get cross-wired
##   - runtime HP / position changes do not affect identity
##   - null / empty inputs are rejected
##   - clear() resets both sides atomically

const BRIDGE: GDScript = preload("res://core/battle/legacy_battle_participant_map.gd")


var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	_test_basic_binding()
	_test_two_warriors_same_definition()
	_test_duplicate_combatant_rejected()
	_test_duplicate_run_unit_id_rejected()
	_test_null_combatant_rejected()
	_test_empty_run_unit_id_rejected()
	_test_unknown_lookups_return_safe_defaults()
	_test_clear_resets_both_sides()
	_test_runtime_hp_changes_do_not_affect_identity()
	_test_position_changes_do_not_affect_identity()
	_test_size_tracks_bindings()
	print("\n=== legacy battle participant map: %d passed, %d failed ===\n" % [_passed, _failed])
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


## Tiny stand-in for a Combatant. We deliberately do NOT preload
## the real Combatant in this test: T3E must not couple to the
## legacy battle path; the bridge is keyed on Object identity,
## not on Combatant semantics.
class _FakeCombatant extends RefCounted:
	var combatant_id: String = ""
	var current_hp: int = 100
	var max_hp: int = 100
	var cell: int = 0


func _make_combatant(combatant_id: String, cell: int = 0) -> _FakeCombatant:
	var c = _FakeCombatant.new()
	c.combatant_id = combatant_id
	c.cell = cell
	return c


## 1. Basic binding: forward and reverse lookups both work.
func _test_basic_binding() -> void:
	print("[basic] forward and reverse lookup")
	var m = BRIDGE.new()
	var c: _FakeCombatant = _make_combatant("C1")
	_assert(m.bind(c, "unit_000001"), "bind C1 -> unit_000001")
	_assert(m.get_run_unit_id(c) == "unit_000001",
		"forward: get_run_unit_id(c) == unit_000001")
	_assert(m.get_combatant("unit_000001") == c,
		"reverse: get_combatant(unit_000001) == c")
	_assert(m.size() == 1, "size is 1 after one bind")


## 2. Two warriors with the same definition are mapped to two
## distinct instance ids. This is THE identity-preserving test.
func _test_two_warriors_same_definition() -> void:
	print("[identity] two warriors same def stay distinct in the map")
	var m = BRIDGE.new()
	var ca: _FakeCombatant = _make_combatant("C_warrior_a")
	var cb: _FakeCombatant = _make_combatant("C_warrior_b")
	_assert(m.bind(ca, "unit_000001"), "bind warrior_a -> unit_000001")
	_assert(m.bind(cb, "unit_000002"), "bind warrior_b -> unit_000002")
	_assert(m.get_run_unit_id(ca) == "unit_000001",
		"warrior_a maps to unit_000001")
	_assert(m.get_run_unit_id(cb) == "unit_000002",
		"warrior_b maps to unit_000002")
	_assert(m.get_combatant("unit_000001") == ca,
		"unit_000001 reverse -> warrior_a")
	_assert(m.get_combatant("unit_000002") == cb,
		"unit_000002 reverse -> warrior_b")
	# Cross-lookups return safe defaults.
	_assert(m.get_run_unit_id(_make_combatant("C_other")) == "",
		"unknown combatant returns empty")
	_assert(m.get_combatant("unit_999999") == null,
		"unknown run_unit returns null")


## 3. Duplicate Combatant (same Object re-bound to a different id)
## is rejected.
func _test_duplicate_combatant_rejected() -> void:
	print("[dup] same Combatant re-bound is rejected")
	var m = BRIDGE.new()
	var c: _FakeCombatant = _make_combatant("C1")
	_assert(m.bind(c, "unit_000001"), "first bind ok")
	_assert(not m.bind(c, "unit_000002"),
		"second bind with same Combatant rejected")
	_assert(m.get_last_error() == BRIDGE.ERR_ALREADY_BOUND_TO_SAME_COMBATANT,
		"last error = ERR_ALREADY_BOUND_TO_SAME_COMBATANT")
	# Original binding unchanged.
	_assert(m.get_run_unit_id(c) == "unit_000001",
		"first binding still points at unit_000001")


## 4. Duplicate RunUnit instance id (two different combatants
## trying to claim the same id) is rejected.
func _test_duplicate_run_unit_id_rejected() -> void:
	print("[dup] same RunUnit id re-bound is rejected")
	var m = BRIDGE.new()
	var ca: _FakeCombatant = _make_combatant("C1")
	var cb: _FakeCombatant = _make_combatant("C2")
	_assert(m.bind(ca, "unit_000001"), "first bind ok")
	_assert(not m.bind(cb, "unit_000001"),
		"second bind with same run_unit_id rejected")
	_assert(m.get_last_error() == BRIDGE.ERR_ALREADY_BOUND_TO_SAME_RUN_UNIT,
		"last error = ERR_ALREADY_BOUND_TO_SAME_RUN_UNIT")
	# Original binding unchanged.
	_assert(m.get_combatant("unit_000001") == ca,
		"unit_000001 still points at C1")


## 5. Null Combatant is rejected.
func _test_null_combatant_rejected() -> void:
	print("[null] null combatant rejected")
	var m = BRIDGE.new()
	_assert(not m.bind(null, "unit_000001"),
		"null combatant rejected")
	_assert(m.get_last_error() == BRIDGE.ERR_NULL_COMBATANT,
		"last error = ERR_NULL_COMBATANT")


## 6. Empty run_unit_instance_id is rejected.
func _test_empty_run_unit_id_rejected() -> void:
	print("[empty] empty run_unit_id rejected")
	var m = BRIDGE.new()
	var c: _FakeCombatant = _make_combatant("C1")
	_assert(not m.bind(c, ""),
		"empty run_unit_instance_id rejected")
	_assert(m.get_last_error() == BRIDGE.ERR_EMPTY_RUN_UNIT_INSTANCE_ID,
		"last error = ERR_EMPTY_RUN_UNIT_INSTANCE_ID")


## 7. Unknown lookups return safe defaults.
func _test_unknown_lookups_return_safe_defaults() -> void:
	print("[unknown] safe defaults")
	var m = BRIDGE.new()
	_assert(m.get_run_unit_id(_make_combatant("C_unknown")) == "",
		"unknown combatant -> empty string")
	_assert(m.get_combatant("unit_unknown") == null,
		"unknown run_unit_id -> null")
	_assert(not m.has_combatant(_make_combatant("C_unknown")),
		"has_combatant false for unknown")
	_assert(not m.has_run_unit("unit_unknown"),
		"has_run_unit false for unknown")
	_assert(m.get_run_unit_id(null) == "",
		"null combatant -> empty string")
	_assert(m.get_combatant("") == null,
		"empty run_unit_id -> null")


## 8. clear() resets both sides atomically.
func _test_clear_resets_both_sides() -> void:
	print("[clear] both sides disappear")
	var m = BRIDGE.new()
	var ca: _FakeCombatant = _make_combatant("C1")
	var cb: _FakeCombatant = _make_combatant("C2")
	m.bind(ca, "unit_000001")
	m.bind(cb, "unit_000002")
	_assert(m.size() == 2, "size is 2 before clear")
	m.clear()
	_assert(m.size() == 0, "size is 0 after clear")
	_assert(m.get_run_unit_id(ca) == "",
		"ca no longer mapped after clear")
	_assert(m.get_combatant("unit_000001") == null,
		"unit_000001 no longer mapped after clear")
	# last_error is reset.
	_assert(m.get_last_error() == BRIDGE.ERR_NONE,
		"last_error reset to ERR_NONE on clear")
	# The map is reusable after clear.
	_assert(m.bind(ca, "unit_000001"),
		"can bind again after clear")


## 9. Runtime HP changes do not affect identity.
func _test_runtime_hp_changes_do_not_affect_identity() -> void:
	print("[runtime] hp changes do not disturb the map")
	var m = BRIDGE.new()
	var ca: _FakeCombatant = _make_combatant("C1", 0)
	var cb: _FakeCombatant = _make_combatant("C2", 1)
	m.bind(ca, "unit_000001")
	m.bind(cb, "unit_000002")
	# Mutate HP mid-battle.
	ca.current_hp = 30
	cb.current_hp = 0
	cb.max_hp = 100
	_assert(m.get_run_unit_id(ca) == "unit_000001",
		"ca still maps to unit_000001 after HP change")
	_assert(m.get_run_unit_id(cb) == "unit_000002",
		"cb still maps to unit_000002 after HP change")
	_assert(m.size() == 2, "size unchanged after HP mutations")


## 10. Position / board-cell changes do not affect identity.
func _test_position_changes_do_not_affect_identity() -> void:
	print("[position] position changes do not disturb the map")
	var m = BRIDGE.new()
	var ca: _FakeCombatant = _make_combatant("C1", 0)
	var cb: _FakeCombatant = _make_combatant("C2", 1)
	m.bind(ca, "unit_000001")
	m.bind(cb, "unit_000002")
	# Swap positions mid-battle.
	ca.cell = 1
	cb.cell = 0
	_assert(m.get_run_unit_id(ca) == "unit_000001",
		"ca still maps to unit_000001 after cell swap")
	_assert(m.get_run_unit_id(cb) == "unit_000002",
		"cb still maps to unit_000002 after cell swap")
	_assert(m.get_combatant("unit_000001") == ca,
		"unit_000001 still points at ca after cell swap")
	_assert(m.get_combatant("unit_000002") == cb,
		"unit_000002 still points at cb after cell swap")


## 11. size() tracks the live binding count.
func _test_size_tracks_bindings() -> void:
	print("[size] size() is consistent across both sides")
	var m = BRIDGE.new()
	_assert(m.size() == 0, "size 0 on empty map")
	var c1: _FakeCombatant = _make_combatant("C1")
	var c2: _FakeCombatant = _make_combatant("C2")
	m.bind(c1, "unit_000001")
	_assert(m.size() == 1, "size 1 after one bind")
	m.bind(c2, "unit_000002")
	_assert(m.size() == 2, "size 2 after two binds")
	# A failed bind does NOT increase size.
	var c3: _FakeCombatant = _make_combatant("C3")
	_assert(not m.bind(c3, "unit_000001"),
		"duplicate id rejected")
	_assert(m.size() == 2,
		"failed bind does not change size")
	_assert(not m.bind(c3, ""), "empty id rejected")
	_assert(m.size() == 2, "failed empty-id bind does not change size")