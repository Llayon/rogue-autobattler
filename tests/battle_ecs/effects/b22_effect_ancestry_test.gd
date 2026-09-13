extends SceneTree
## Phase 3 / B2.2 — effect ancestry boundary + result event
## completeness.
##
## Covers:
##   HIGH 1: EffectRequest.validate_ancestry() explicit
##           semantics.
##   HIGH 2: validate BEFORE mutation; bad ancestry is rejected
##           before HP / StatusContainer / world changes.
##   HIGH 3: EffectResult.events contains EVERY event emitted.
##   HIGH 4: 20-run determinism compares all 14 normalized
##           fields (covered by determinism_stress_test;
##           smoke-tested here).

const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
const EffectResultScript = preload("res://core/battle_ecs/effects/effect_result.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const ContentDBScript = preload("res://core/utils/content_db.gd")
const StatusContainerScript = preload("res://core/battle_ecs/status/status_container.gd")
const StatusInstanceScript = preload("res://core/battle_ecs/status/status_instance.gd")
const DamageEffectScript = preload("res://core/battle_ecs/effects/damage_effect.gd")
const HealEffectScript = preload("res://core/battle_ecs/effects/heal_effect.gd")
const ApplyStatusEffectScript = preload("res://core/battle_ecs/effects/apply_status_effect.gd")
const RemoveStatusEffectScript = preload("res://core/battle_ecs/effects/remove_status_effect.gd")
const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	# === HIGH 1: ancestry kinds ===
	await _test_validate_ancestry_root()
	await _test_validate_ancestry_child()
	await _test_validate_ancestry_mixed_rejected()
	await _test_validate_ancestry_zero_rejected()
	await _test_validate_ancestry_root_with_chain_depth_1_rejected()
	await _test_validate_ancestry_child_with_chain_depth_0_rejected()
	# === HIGH 2: validate before mutation, direct child depth ===
	await _test_damage_validate_before_mutation_root_mismatch()
	await _test_damage_validate_before_mutation_partial_child()
	await _test_damage_validate_before_mutation_negative_chain_depth()
	await _test_damage_validate_before_mutation_zero_field()
	await _test_heal_validate_before_mutation()
	await _test_apply_status_validate_before_mutation()
	await _test_remove_status_validate_before_mutation()
	await _test_direct_child_effect_event_chain_depth_exact()
	await _test_nested_child_effect_event_chain_depth_exact()
	# === HIGH 2: malformed matrix per effect (factor common) ===
	await _test_malformed_matrix_all_four_effects_no_mutation()
	# === HIGH 3: result.events completeness ===
	await _test_damage_non_lethal_returns_one_event()
	await _test_damage_lethal_returns_two_events_in_order()
	await _test_result_sink_parity()
	await _test_heal_event_completeness()
	await _test_apply_remove_event_completeness()
	# === HIGH 4: 14-field normalization contract (smoke) ===
	await _test_event_object_exposes_normalized_properties()
	print("\n=== B2.2 focused tests: %d passed, %d failed ===\n" % [_passed, _failed])
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


# === HIGH 1 ===

func _test_validate_ancestry_root() -> void:
	print("[AV-1] validate_ancestry_root")
	var r = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 10, -1, -1, 0)
	var res: Dictionary = r.validate_ancestry()
	_assert(bool(res.get("ok", false)), "ok=true")
	_assert(int(res.get("kind", -1)) == int(EffectRequestScript.ANCESTRY_ROOT),
		"kind=ROOT (got %s)" % str(res.get("kind", "")))


func _test_validate_ancestry_child() -> void:
	print("[AV-2] validate_ancestry_child")
	var r = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 10, 5, 7, 2)
	var res: Dictionary = r.validate_ancestry()
	_assert(bool(res.get("ok", false)), "ok=true")
	_assert(int(res.get("kind", -1)) == int(EffectRequestScript.ANCESTRY_CHILD),
		"kind=CHILD (got %s)" % str(res.get("kind", "")))


func _test_validate_ancestry_mixed_rejected() -> void:
	print("[AV-3] validate_ancestry_mixed_rejected")
	# root=5 parent=-1: malformed
	var r1 = EffectRequestScript.new(0, 0, 1, 0, 5, -1, 0)
	var res1: Dictionary = r1.validate_ancestry()
	_assert(not bool(res1.get("ok", false)), "root>0 parent=-1 rejected")
	_assert(int(res1.get("kind", -1)) == int(EffectRequestScript.ANCESTRY_INVALID),
		"kind=INVALID")
	# root=-1 parent=5: malformed
	var r2 = EffectRequestScript.new(0, 0, 1, 0, -1, 5, 0)
	var res2: Dictionary = r2.validate_ancestry()
	_assert(not bool(res2.get("ok", false)), "root=-1 parent>0 rejected")


func _test_validate_ancestry_zero_rejected() -> void:
	print("[AV-4] validate_ancestry_zero_rejected")
	# root=0 OR parent=0 is never allowed (sentinel collision guard)
	var r1 = EffectRequestScript.new(0, 0, 1, 0, 0, -1, 0)
	var res1: Dictionary = r1.validate_ancestry()
	_assert(not bool(res1.get("ok", false)), "root=0 rejected")
	var r2 = EffectRequestScript.new(0, 0, 1, 0, -1, 0, 0)
	var res2: Dictionary = r2.validate_ancestry()
	_assert(not bool(res2.get("ok", false)), "parent=0 rejected")


func _test_validate_ancestry_root_with_chain_depth_1_rejected() -> void:
	print("[AV-5] validate_ancestry_root_with_chain_depth_1_rejected")
	# Root shape but chain_depth != 0 -> invalid.
	var r = EffectRequestScript.new(0, 0, 1, 0, -1, -1, 1)
	var res: Dictionary = r.validate_ancestry()
	_assert(not bool(res.get("ok", false)), "root with depth=1 rejected")


func _test_validate_ancestry_child_with_chain_depth_0_rejected() -> void:
	print("[AV-6] validate_ancestry_child_with_chain_depth_0_rejected")
	# Child shape but chain_depth < 1 -> invalid.
	var r = EffectRequestScript.new(0, 0, 1, 0, 5, 7, 0)
	var res: Dictionary = r.validate_ancestry()
	_assert(not bool(res.get("ok", false)), "child with depth=0 rejected")


# === HIGH 2 ===

func _test_damage_validate_before_mutation_root_mismatch() -> void:
	print("[DM-1] damage_validate_before_mutation_partial_child_root_-1")
	# root=-1 parent=5 chain_depth=1: MALFORMED (root=-1 parent>0).
	var arr: Array = _make_world_and_ctx(20)
	var w: BattleWorldScript = arr[0]
	var ctx = arr[1]
	var hp_before: int = int(w.current_hp_of(1))
	var eid_before: int = int(arr[3].peek_next_event_id())
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 10, -1, 5, 1)
	var result = DamageEffectScript.execute(ctx, req)
	_assert(not result.success, "malformed ancestry rejected (success=false)")
	_assert(int(w.current_hp_of(1)) == hp_before, "HP unchanged after rejection")
	_assert(int(arr[3].peek_next_event_id()) == eid_before,
		"emitter counter unchanged after rejection")


func _test_damage_validate_before_mutation_partial_child() -> void:
	print("[DM-2] damage_validate_before_mutation_root_5_parent_-1")
	var arr: Array = _make_world_and_ctx(20)
	var w: BattleWorldScript = arr[0]
	var ctx = arr[1]
	var hp_before: int = int(w.current_hp_of(1))
	var eid_before: int = int(arr[3].peek_next_event_id())
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 10, 5, -1, 0)
	var result = DamageEffectScript.execute(ctx, req)
	_assert(not result.success, "root>0 parent=-1 rejected")
	_assert(int(w.current_hp_of(1)) == hp_before, "HP unchanged")


func _test_damage_validate_before_mutation_negative_chain_depth() -> void:
	print("[DM-3] damage_validate_before_mutation_negative_chain_depth")
	var arr: Array = _make_world_and_ctx(20)
	var w: BattleWorldScript = arr[0]
	var ctx = arr[1]
	var hp_before: int = int(w.current_hp_of(1))
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 10, 5, 7, -1)
	var result = DamageEffectScript.execute(ctx, req)
	_assert(not result.success, "child with depth=-1 rejected")
	_assert(int(w.current_hp_of(1)) == hp_before, "HP unchanged")


func _test_damage_validate_before_mutation_zero_field() -> void:
	print("[DM-4] damage_validate_before_mutation_zero_field")
	var arr: Array = _make_world_and_ctx(20)
	var w: BattleWorldScript = arr[0]
	var ctx = arr[1]
	var hp_before: int = int(w.current_hp_of(1))
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 10, 0, 7, 1)
	var result = DamageEffectScript.execute(ctx, req)
	_assert(not result.success, "root=0 rejected")


func _test_heal_validate_before_mutation() -> void:
	print("[HL-2] heal_validate_before_mutation")
	var arr: Array = _make_world_and_ctx(80)
	var w: BattleWorldScript = arr[0]
	var ctx = arr[1]
	# Apply damage so HP is below max.
	w.apply_damage(0, 50)
	var hp_before: int = int(w.current_hp_of(0))
	var req = EffectRequestScript.new(
		EffectKindScript.HEAL, 0, 0, 100, -1, 5, 1)  # malformed
	var result = HealEffectScript.execute(ctx, req)
	_assert(not result.success, "heal malformed ancestry rejected")
	_assert(int(w.current_hp_of(0)) == hp_before, "HP unchanged after malformed heal")


func _test_apply_status_validate_before_mutation() -> void:
	print("[AS-2] apply_status_validate_before_mutation")
	ContentDBScript.load_all()
	var arr: Array = _make_world_and_ctx(80)
	var w: BattleWorldScript = arr[0]
	var ctx = arr[1]
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, 5, -1, 0)  # malformed
	req.definition_id = &"attack_up"
	var result = ApplyStatusEffectScript.execute(ctx, req)
	_assert(not result.success, "apply malformed ancestry rejected")
	_assert(w.get_status_container(0) == null,
		"no container created for malformed apply")


func _test_remove_status_validate_before_mutation() -> void:
	print("[RS-1] remove_status_validate_before_mutation")
	ContentDBScript.load_all()
	var arr: Array = _make_world_and_ctx(80)
	var w: BattleWorldScript = arr[0]
	var ctx = arr[1]
	# First apply attack_up with valid ancestry.
	var req_apply = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req_apply.definition_id = &"attack_up"
	ApplyStatusEffectScript.execute(ctx, req_apply)
	var c = w.get_status_container(0)
	_assert(c != null, "container exists after valid apply")
	# Now try to remove with malformed ancestry.
	var req_remove = EffectRequestScript.new(
		EffectKindScript.REMOVE_STATUS, 0, 0, 0, 5, -1, 0)
	req_remove.definition_id = &"attack_up"
	var result = RemoveStatusEffectScript.execute(ctx, req_remove)
	_assert(not result.success, "remove malformed ancestry rejected")
	_assert(c.has_status(&"attack_up"), "status still present after malformed remove")


func _test_direct_child_effect_event_chain_depth_exact() -> void:
	print("[DEPTH-1] direct_child_effect_event_chain_depth_exact")
	# ATTACK_RESOLVED root at event_id=1 root_action_id=1 depth=0
	# DAMAGE_APPLIED child request: root=1 parent=1 depth=1
	# Expected emitted event: chain_depth == 1 (NOT 2).
	var arr: Array = _make_world_and_ctx(80)
	var w: BattleWorldScript = arr[0]
	var ctx = arr[1]
	var em: BattleEventEmitterScript = arr[3]
	var root = em.emit(BattleEventTypeScript.ATTACK_RESOLVED)
	_assert(int(root.chain_depth) == 0, "root depth 0")
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 10,
		int(root.root_action_id), int(root.event_id), 1)
	var result = DamageEffectScript.execute(ctx, req)
	_assert(result.success, "damage succeeds")
	var dmg_ev = result.events[0]
	_assert(int(dmg_ev.chain_depth) == 1,
		"child event chain_depth == 1 (req.chain_depth), got %d" % int(dmg_ev.chain_depth))
	_assert(int(dmg_ev.parent_event_id) == int(root.event_id),
		"child parent_event_id == root.event_id")
	_assert(int(dmg_ev.root_action_id) == int(root.root_action_id),
		"child shares root_action_id with parent")


func _test_nested_child_effect_event_chain_depth_exact() -> void:
	print("[DEPTH-2] nested_child_effect_event_chain_depth_exact")
	# B2.3 corrected test: build a real chain root -> child ->
	# grandchild (depth 0 -> 1 -> 2). Then construct the next
	# child EffectRequest via child_from_parent(grandchild).
	# The factory derives chain_depth = grandchild.depth + 1 = 3.
	# Caller does NOT pick chain_depth manually.
	var arr: Array = _make_world_and_ctx(80)
	var w: BattleWorldScript = arr[0]
	var ctx = arr[1]
	var em: BattleEventEmitterScript = arr[3]
	var root = em.emit(BattleEventTypeScript.ATTACK_RESOLVED)
	var r2 = em.emit_child(BattleEventTypeScript.DAMAGE_APPLIED,
		int(root.event_id), int(root.root_action_id), int(root.chain_depth))
	var r3 = em.emit_child(BattleEventTypeScript.UNIT_DIED,
		int(r2.event_id), int(r2.root_action_id), int(r2.chain_depth))
	_assert(int(r3.chain_depth) == 2, "grandchild chain_depth == 2")
	# Use the canonical CHILD factory — no caller arithmetic.
	var req = EffectRequestScript.child_from_parent(
		EffectKindScript.DAMAGE,
		r3,
		0, 1, 10)
	_assert(req != null, "child_from_parent returned a request")
	# Factory must have derived exactly: parent_event_id =
	# grandchild.event_id, root_action_id = grandchild.root,
	# chain_depth = grandchild.depth + 1 = 3.
	_assert(int(req.parent_event_id) == int(r3.event_id),
		"req.parent_event_id == grandchild.event_id")
	_assert(int(req.root_action_id) == int(r3.root_action_id),
		"req.root_action_id == grandchild.root_action_id")
	_assert(int(req.chain_depth) == 3,
		"req.chain_depth == grandchild.depth + 1 (got %d)" % int(req.chain_depth))
	var result = DamageEffectScript.execute(ctx, req)
	_assert(result.success, "damage succeeds")
	var dmg_ev = result.events[0]
	_assert(int(dmg_ev.chain_depth) == 3,
		"emitted child event chain_depth == 3 (req.chain_depth), got %d" % int(dmg_ev.chain_depth))
	_assert(int(dmg_ev.parent_event_id) == int(r3.event_id),
		"emitted event parent_event_id == grandchild.event_id")
	_assert(int(dmg_ev.root_action_id) == int(r3.root_action_id),
		"emitted event shares root_action_id with grandchild")


# === HIGH 2: malformed matrix per effect ===

func _test_malformed_matrix_all_four_effects_no_mutation() -> void:
	print("[MAT-1] malformed_matrix_all_four_effects_no_mutation")
	# For each effect kind, test representative malformed combos:
	# A: root=5 parent=-1 depth=0
	# B: root=-1 parent=5 depth=1
	# C: root=5 parent=5 depth=0
	# D: root=5 parent=5 depth=-1
	ContentDBScript.load_all()
	var arr: Array = _make_world_and_ctx(80)
	var w: BattleWorldScript = arr[0]
	var ctx = arr[1]
	# Pre-apply attack_up on entity 0 with valid ancestry so
	# remove_status has something to remove.
	var req_apply = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req_apply.definition_id = &"attack_up"
	ApplyStatusEffectScript.execute(ctx, req_apply)
	var hp_before: int = int(w.current_hp_of(1))
	var c0_before = w.get_status_container(0)
	var eid_before: int = int(arr[3].peek_next_event_id())
	var matrix: Array = [
		{"label": "A root=5 parent=-1 depth=0",
		 "root": 5, "parent": -1, "depth": 0},
		{"label": "B root=-1 parent=5 depth=1",
		 "root": -1, "parent": 5, "depth": 1},
		{"label": "C root=5 parent=5 depth=0",
		 "root": 5, "parent": 5, "depth": 0},
		{"label": "D root=5 parent=5 depth=-1",
		 "root": 5, "parent": 5, "depth": -1},
	]
	for entry in matrix:
		# Damage
		var rd = EffectRequestScript.new(EffectKindScript.DAMAGE, 0, 1, 10,
			int(entry.root), int(entry.parent), int(entry.depth))
		var rd_res = DamageEffectScript.execute(ctx, rd)
		_assert(not rd_res.success,
			"damage[%s] rejected (got success)" % entry.label)
		# Heal (would mutate HP at room>0)
		w.apply_damage(0, 10)  # ensure room
		var rh = EffectRequestScript.new(EffectKindScript.HEAL, 0, 0, 5,
			int(entry.root), int(entry.parent), int(entry.depth))
		var rh_res = HealEffectScript.execute(ctx, rh)
		_assert(not rh_res.success,
			"heal[%s] rejected" % entry.label)
		# Apply status
		var ra = EffectRequestScript.new(EffectKindScript.APPLY_STATUS, 0, 0, 0,
			int(entry.root), int(entry.parent), int(entry.depth))
		ra.definition_id = &"attack_up"
		var ra_res = ApplyStatusEffectScript.execute(ctx, ra)
		_assert(not ra_res.success,
			"apply[%s] rejected" % entry.label)
		# Remove status
		var rr = EffectRequestScript.new(EffectKindScript.REMOVE_STATUS, 0, 0, 0,
			int(entry.root), int(entry.parent), int(entry.depth))
		rr.definition_id = &"attack_up"
		var rr_res = RemoveStatusEffectScript.execute(ctx, rr)
		_assert(not rr_res.success,
			"remove[%s] rejected" % entry.label)
	_assert(int(w.current_hp_of(1)) == hp_before,
		"entity 1 HP unchanged across all malformed attempts")
	_assert(w.get_status_container(0) == c0_before,
		"entity 0 container reference unchanged")
	_assert(int(arr[3].peek_next_event_id()) == eid_before,
		"emitter event_id counter unchanged across all malformed attempts")


# === HIGH 3 ===

func _test_damage_non_lethal_returns_one_event() -> void:
	print("[EV-1] damage_non_lethal_returns_one_event")
	var arr: Array = _make_world_and_ctx(80)
	var w: BattleWorldScript = arr[0]
	var ctx = arr[1]
	# Damage 10 (non-lethal).
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 10, -1, -1, 0)
	var result = DamageEffectScript.execute(ctx, req)
	_assert(result.success, "damage succeeds")
	_assert(result.events.size() == 1,
		"non-lethal returns exactly 1 event (got %d)" % result.events.size())
	_assert(int(result.events[0].type) == BattleEventTypeScript.DAMAGE_APPLIED,
		"event is DAMAGE_APPLIED")


func _test_damage_lethal_returns_two_events_in_order() -> void:
	print("[EV-2] damage_lethal_returns_two_events_in_order")
	var arr: Array = _make_world_and_ctx(80)
	var w: BattleWorldScript = arr[0]
	var ctx = arr[1]
	# Lethal damage: enemy has 80 HP, deal 1000.
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 1000, -1, -1, 0)
	var result = DamageEffectScript.execute(ctx, req)
	_assert(result.success, "lethal damage succeeds")
	_assert(result.events.size() == 2,
		"lethal returns exactly 2 events (got %d)" % result.events.size())
	_assert(int(result.events[0].type) == BattleEventTypeScript.DAMAGE_APPLIED,
		"events[0] == DAMAGE_APPLIED")
	_assert(int(result.events[1].type) == BattleEventTypeScript.UNIT_DIED,
		"events[1] == UNIT_DIED")
	_assert(result.events[1].parent_event_id == result.events[0].event_id,
		"UNIT_DIED.parent_event_id == DAMAGE_APPLIED.event_id")
	_assert(result.events[1].chain_depth == result.events[0].chain_depth + 1,
		"UNIT_DIED.chain_depth == DAMAGE_APPLIED.chain_depth + 1")


func _test_result_sink_parity() -> void:
	print("[EV-3] result_sink_parity")
	# sink and result.events must contain the same event objects
	# in the same order.
	var arr: Array = _make_world_and_ctx(80)
	var w: BattleWorldScript = arr[0]
	var ctx = arr[1]
	var sink: Array = arr[2]
	var sink_before: int = sink.size()
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 1000, -1, -1, 0)
	var result = DamageEffectScript.execute(ctx, req)
	_assert(result.success, "lethal damage succeeds")
	var sink_slice: Array = sink.slice(sink_before)
	_assert(sink_slice.size() == result.events.size(),
		"sink slice size == result.events size")
	for i in result.events.size():
		_assert(sink_slice[i] == result.events[i],
			"sink_slice[%d] is same object as result.events[%d]" % [i, i])


func _test_heal_event_completeness() -> void:
	print("[EV-4] heal_event_completeness")
	var arr: Array = _make_world_and_ctx(80)
	var w: BattleWorldScript = arr[0]
	var ctx = arr[1]
	w.apply_damage(0, 50)
	var req = EffectRequestScript.new(
		EffectKindScript.HEAL, 0, 0, 100, -1, -1, 0)
	var result = HealEffectScript.execute(ctx, req)
	_assert(result.success, "heal succeeds")
	_assert(result.events.size() == 1, "heal returns 1 event")
	_assert(int(result.events[0].type) == BattleEventTypeScript.HEAL_APPLIED,
		"event is HEAL_APPLIED")


func _test_apply_remove_event_completeness() -> void:
	print("[EV-5] apply_remove_event_completeness")
	ContentDBScript.load_all()
	var arr: Array = _make_world_and_ctx(80)
	var w: BattleWorldScript = arr[0]
	var ctx = arr[1]
	var req_a = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req_a.definition_id = &"attack_up"
	var res_a = ApplyStatusEffectScript.execute(ctx, req_a)
	_assert(res_a.success, "apply succeeds")
	_assert(res_a.events.size() == 1, "apply returns 1 event")
	_assert(int(res_a.events[0].type) == BattleEventTypeScript.STATUS_APPLIED,
		"apply event is STATUS_APPLIED")
	var req_r = EffectRequestScript.new(
		EffectKindScript.REMOVE_STATUS, 0, 0, 0, -1, -1, 0)
	req_r.definition_id = &"attack_up"
	var res_r = RemoveStatusEffectScript.execute(ctx, req_r)
	_assert(res_r.success, "remove succeeds")
	_assert(res_r.events.size() == 1, "remove returns 1 event")
	_assert(int(res_r.events[0].type) == BattleEventTypeScript.STATUS_REMOVED,
		"remove event is STATUS_REMOVED")


# === HIGH 4 ===

func _test_event_object_exposes_normalized_properties() -> void:
	print("[NORM-1] event_object_exposes_normalized_properties")
	# B2.3: this test verifies that BattleEvent objects expose
	# the properties the determinism stress test expects to read.
	# It does NOT make claims about which property values are
	# semantically valid — those vary per event type.
	var sim = _make_sim()
	sim.set_max_ticks(20)
	var evs: Array = sim.run_until_done(1000)
	_assert(evs.size() > 0, "trace non-empty")
	for e in evs:
		for f in ["event_id", "type", "tick", "source_entity", "target_entity",
				"source_run_unit_id", "target_run_unit_id", "amount", "tag",
				"from_cell", "to_cell", "parent_event_id", "root_action_id",
				"chain_depth"]:
			_assert(e.get(f) != null,
				"property '%s' present on event %d" % [f, int(e.event_id)])


# === Helpers ===

func _make_world_and_ctx(hp: int) -> Array:
	var B = preload("res://core/battle_ecs/battle_unit_setup.gd")
	var S = preload("res://core/battle_ecs/battle_setup.gd")
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), hp, hp, 20, 5, 5)
	var e = B.new("", &"orc", 1, Vector2i(0, 0), hp, hp, 20, 5, 5)
	var s = S.new(42, [p], [e], 7, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	var emitter = BattleEventEmitterScript.new()
	emitter.reset()
	var sink: Array = []
	var ctx = EffectContextScript.new(w, rng, emitter, sink)
	return [w, ctx, sink, emitter]


func _make_sim() -> BattleSimulationScript:
	# Same setup as _make_world_and_ctx but exposed for
	# run_until_done. Returns a fully initialized BattleSimulation.
	var B = preload("res://core/battle_ecs/battle_unit_setup.gd")
	var S = preload("res://core/battle_ecs/battle_setup.gd")
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), 80, 80, 20, 5, 5)
	var e = B.new("", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var s = S.new(42, [p], [e], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(s)
	return sim
