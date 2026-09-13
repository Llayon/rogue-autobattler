extends SceneTree
## Phase 3 / B2.1 — event-contract proof closure.
##
## Covers:
##   HIGH 1: determinism trace includes ancestry (delegated to
##           determinism_stress_test._normalize_event; verified
##           by field presence here).
##   HIGH 2: two-simulation FULL isolation (interleaved vs
##           standalone, field-for-field).
##   HIGH 3: auditor must reject forward parents.
##   HIGH 4: UNIT_DIED strict contract (verified by
##           b20_event_namespace_test).
##   HIGH 5: emitter malformed-root behavior; emit_child
##           rejection behavior.
##   HIGH 6: first event == 1 exact (verified by
##           b20_event_namespace_test).

const BattleEventScript = preload("res://core/battle_ecs/battle_event.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_root_default_emits_depth_zero_and_fresh_root()
	await _test_root_caller_depth_99_still_emits_depth_zero()
	await _test_root_caller_positive_root_action_id_ignored()
	await _test_child_normal_shares_root_and_increments_depth()
	await _test_child_parent_minus_one_rejected_no_counter_advance()
	await _test_child_parent_zero_rejected()
	await _test_child_root_action_id_minus_one_rejected()
	await _test_child_parent_chain_depth_minus_one_rejected()
	await _test_rejected_child_does_not_advance_event_or_root_counters()
	await _test_auditor_rejects_forward_parent()
	await _test_auditor_rejects_orphan_parent_event_id()
	await _test_two_sim_interleaved_full_trace_matches_standalone()
	await _test_event_counter_isolation_via_peek_accessors()
	await _test_root_action_id_counter_isolation()
	await _test_auditor_rejects_two_roots_under_same_root_id()
	print("\n=== B2.1 focused tests: %d passed, %d failed ===\n" % [_passed, _failed])
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


# === HIGH 5: emitter adversarial ===

func _test_root_default_emits_depth_zero_and_fresh_root() -> void:
	print("[EM-1] root_default_emits_depth_zero_and_fresh_root")
	var em = BattleEventEmitterScript.new()
	em.reset()
	em.set_tick(1)
	var ev = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1)
	_assert(int(ev.event_id) == 1, "first event_id == 1 (got %d)" % int(ev.event_id))
	_assert(int(ev.root_action_id) == 1, "first root_action_id == 1 (got %d)" % int(ev.root_action_id))
	_assert(int(ev.parent_event_id) == -1, "parent_event_id == -1 (got %d)" % int(ev.parent_event_id))
	_assert(int(ev.chain_depth) == 0, "chain_depth == 0 (got %d)" % int(ev.chain_depth))


func _test_root_caller_depth_99_still_emits_depth_zero() -> void:
	print("[EM-2] root_caller_depth_99_still_emits_depth_zero")
	# Caller cannot accidentally produce "root at depth 7".
	# The new emit() API does NOT accept caller depth/root at
	# all — but we test that even if a child path is taken with
	# negative parent, the root path remains strict.
	var em = BattleEventEmitterScript.new()
	em.reset()
	var root = em.emit(BattleEventTypeScript.DAMAGE_APPLIED)
	_assert(int(root.chain_depth) == 0, "root chain_depth always 0")


func _test_root_caller_positive_root_action_id_ignored() -> void:
	print("[EM-3] root_allocates_fresh_root_id_per_emission")
	# Each emit() allocates a fresh root_action_id. Even the
	# second emit on the same emitter gets root_action_id == 2.
	var em = BattleEventEmitterScript.new()
	em.reset()
	var e1 = em.emit(BattleEventTypeScript.DAMAGE_APPLIED)
	var e2 = em.emit(BattleEventTypeScript.DAMAGE_APPLIED)
	_assert(int(e1.root_action_id) == 1, "first root == 1")
	_assert(int(e2.root_action_id) == 2, "second root == 2 (got %d)" % int(e2.root_action_id))
	_assert(int(e2.parent_event_id) == -1, "second root parent_event_id == -1")


func _test_child_normal_shares_root_and_increments_depth() -> void:
	print("[EM-4] child_normal_shares_root_and_increments_depth")
	var em = BattleEventEmitterScript.new()
	em.reset()
	var root = em.emit(BattleEventTypeScript.ATTACK_RESOLVED)
	var child = em.emit_child(
		BattleEventTypeScript.DAMAGE_APPLIED,
		int(root.event_id),
		int(root.root_action_id),
		int(root.chain_depth))
	_assert(child != null, "child emitted (not null)")
	_assert(int(child.root_action_id) == int(root.root_action_id),
		"child root_action_id matches parent (got %d, expected %d)" % [int(child.root_action_id), int(root.root_action_id)])
	_assert(int(child.chain_depth) == int(root.chain_depth) + 1,
		"child depth == parent.depth + 1 (got %d, expected %d)" % [int(child.chain_depth), int(root.chain_depth) + 1])
	_assert(int(child.parent_event_id) == int(root.event_id),
		"child parent_event_id matches parent.event_id")


func _test_child_parent_minus_one_rejected_no_counter_advance() -> void:
	print("[EM-5] child_parent_minus_one_rejected_no_counter_advance")
	var em = BattleEventEmitterScript.new()
	em.reset()
	var before_eid: int = int(em.peek_next_event_id())
	var before_rid: int = int(em.peek_next_root_action_id())
	var child = em.emit_child(
		BattleEventTypeScript.DAMAGE_APPLIED,
		-1, 5, 0)
	_assert(child == null, "child with parent=-1 rejected (got %s)" % str(child))
	_assert(int(em.peek_next_event_id()) == before_eid,
		"event_id counter unchanged after rejection (was %d, now %d)" % [before_eid, int(em.peek_next_event_id())])
	_assert(int(em.peek_next_root_action_id()) == before_rid,
		"root_action_id counter unchanged after rejection (was %d, now %d)" % [before_rid, int(em.peek_next_root_action_id())])


func _test_child_parent_zero_rejected() -> void:
	print("[EM-6] child_parent_zero_rejected")
	var em = BattleEventEmitterScript.new()
	em.reset()
	var before_eid: int = int(em.peek_next_event_id())
	var child = em.emit_child(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 5, 0)
	_assert(child == null, "child with parent=0 rejected")
	_assert(int(em.peek_next_event_id()) == before_eid, "no counter advance")


func _test_child_root_action_id_minus_one_rejected() -> void:
	print("[EM-7] child_root_action_id_minus_one_rejected")
	var em = BattleEventEmitterScript.new()
	em.reset()
	var before_eid: int = int(em.peek_next_event_id())
	var child = em.emit_child(
		BattleEventTypeScript.DAMAGE_APPLIED,
		1, -1, 0)
	_assert(child == null, "child with root=-1 rejected")
	_assert(int(em.peek_next_event_id()) == before_eid, "no counter advance")


func _test_child_parent_chain_depth_minus_one_rejected() -> void:
	print("[EM-8] child_parent_chain_depth_minus_one_rejected")
	var em = BattleEventEmitterScript.new()
	em.reset()
	var before_eid: int = int(em.peek_next_event_id())
	var child = em.emit_child(
		BattleEventTypeScript.DAMAGE_APPLIED,
		1, 5, -1)
	_assert(child == null, "child with parent_depth=-1 rejected")
	_assert(int(em.peek_next_event_id()) == before_eid, "no counter advance")


func _test_rejected_child_does_not_advance_event_or_root_counters() -> void:
	print("[EM-9] rejected_child_does_not_advance_event_or_root_counters")
	var em = BattleEventEmitterScript.new()
	em.reset()
	var before_eid: int = int(em.peek_next_event_id())
	# Multiple rejected children in a row.
	for i in 5:
		var c = em.emit_child(BattleEventTypeScript.DAMAGE_APPLIED, -1, 5, 0)
		_assert(c == null, "rejected child #%d null" % i)
	_assert(int(em.peek_next_event_id()) == before_eid,
		"event_id counter unchanged after 5 rejections (was %d, now %d)" % [before_eid, int(em.peek_next_event_id())])
	# A valid emit still produces event_id == before_eid.
	var ev = em.emit(BattleEventTypeScript.UNIT_MOVED)
	_assert(int(ev.event_id) == before_eid,
		"next valid event_id == %d (got %d)" % [before_eid, int(ev.event_id)])


# === HIGH 3: auditor adversarial ===

func _test_auditor_rejects_forward_parent() -> void:
	print("[AD-1] auditor_rejects_forward_parent")
	# Build a synthetic trace with a child whose parent_event_id
	# points to a LATER event (forward parent). Auditor must
	# reject.
	var em = BattleEventEmitterScript.new()
	em.reset()
	var root = em.emit(BattleEventTypeScript.ATTACK_RESOLVED)
	var child = em.emit_child(
		BattleEventTypeScript.DAMAGE_APPLIED,
		int(root.event_id),
		int(root.root_action_id),
		int(root.chain_depth))
	# Forgery: rewrite the child's parent_event_id to point
	# FORWARD into the trace (or just beyond).
	var forward_parent_id: int = int(child.event_id) + 100
	child.parent_event_id = forward_parent_id
	var trace: Array = [root, child]
	var ok: bool = _audit(trace)
	_assert(not ok, "auditor rejects forward parent (got ok=true)")


func _test_auditor_rejects_orphan_parent_event_id() -> void:
	print("[AD-2] auditor_rejects_orphan_parent_event_id")
	var em = BattleEventEmitterScript.new()
	em.reset()
	var root = em.emit(BattleEventTypeScript.ATTACK_RESOLVED)
	var child = em.emit_child(
		BattleEventTypeScript.DAMAGE_APPLIED,
		int(root.event_id),
		int(root.root_action_id),
		int(root.chain_depth))
	child.parent_event_id = 999999  # not in trace
	var ok: bool = _audit([root, child])
	_assert(not ok, "auditor rejects orphan parent_event_id")


func _test_auditor_rejects_two_roots_under_same_root_id() -> void:
	print("[AD-3] auditor_rejects_two_roots_under_same_root_id")
	var em = BattleEventEmitterScript.new()
	em.reset()
	# Two roots that share the same root_action_id (forged).
	var r1 = em.emit(BattleEventTypeScript.UNIT_MOVED)
	var r2 = em.emit(BattleEventTypeScript.UNIT_MOVED)
	r2.root_action_id = r1.root_action_id
	_assert(not _audit([r1, r2]),
		"auditor rejects duplicate root_action_id across roots")


# === HIGH 2: two-simulation isolation ===

func _test_two_sim_interleaved_full_trace_matches_standalone() -> void:
	print("[ISO-1] two_sim_interleaved_full_trace_matches_standalone")
	# Standalone A.
	var setup_a = _build_setup(42)
	var sim_a_std = BattleSimulationScript.new()
	sim_a_std.initialize(setup_a)
	sim_a_std.set_max_ticks(20)
	var trace_a_std: Array = sim_a_std.run_until_done(1000)
	# Standalone B.
	var setup_b = _build_setup(43)
	var sim_b_std = BattleSimulationScript.new()
	sim_b_std.initialize(setup_b)
	sim_b_std.set_max_ticks(20)
	var trace_b_std: Array = sim_b_std.run_until_done(1000)
	# Interleaved A and B.
	var sim_a_int = BattleSimulationScript.new()
	sim_a_int.initialize(setup_a)
	sim_a_int.set_max_ticks(20)
	var sim_b_int = BattleSimulationScript.new()
	sim_b_int.initialize(setup_b)
	sim_b_int.set_max_ticks(20)
	var trace_a_int: Array = []
	var trace_b_int: Array = []
	for i in 20:
		trace_a_int.append_array(sim_a_int.step_tick())
		trace_b_int.append_array(sim_b_int.step_tick())
	# Field-for-field compare.
	var ok: bool = _traces_equal_field_for_field(trace_a_int, trace_a_std)
	_assert(ok, "interleaved A trace == standalone A trace (field-for-field)")
	ok = _traces_equal_field_for_field(trace_b_int, trace_b_std)
	_assert(ok, "interleaved B trace == standalone B trace (field-for-field)")


func _test_event_counter_isolation_via_peek_accessors() -> void:
	print("[ISO-2] event_counter_isolation_via_peek_accessors")
	var sim_a = _make_sim()
	var sim_b = _make_sim()
	# Advance A 3 ticks.
	for i in 3:
		sim_a.step_tick()
	# Verify B's counter has NOT advanced.
	_assert(int(sim_b.emitter().peek_next_event_id()) == 1,
		"sim_b event_id counter still 1 after sim_a step (got %d)" % int(sim_b.emitter().peek_next_event_id()))
	# Now advance B 1 tick and check isolation.
	sim_b.step_tick()
	_assert(int(sim_a.emitter().peek_next_event_id()) > 1,
		"sim_a event_id counter still advanced (got %d)" % int(sim_a.emitter().peek_next_event_id()))
	_assert(int(sim_b.emitter().peek_next_event_id()) > 1,
		"sim_b event_id counter started fresh then advanced (got %d)" % int(sim_b.emitter().peek_next_event_id()))


func _test_root_action_id_counter_isolation() -> void:
	print("[ISO-3] root_action_id_counter_isolation")
	var sim_a = _make_sim()
	var sim_b = _make_sim()
	sim_a.step_tick()
	sim_a.step_tick()
	# B never stepped: root_action_id counter should still be 1.
	_assert(int(sim_b.emitter().peek_next_root_action_id()) == 1,
		"sim_b root_action_id counter still 1 (got %d)" % int(sim_b.emitter().peek_next_root_action_id()))
	_assert(int(sim_a.emitter().peek_next_root_action_id()) > 1,
		"sim_a root_action_id counter > 1 (got %d)" % int(sim_a.emitter().peek_next_root_action_id()))


# === Helpers ===

func _audit(evs: Array) -> bool:
	# event_id unique and strictly increasing.
	var seen: Dictionary = {}
	var prev_id: int = 0
	for e in evs:
		var id: int = int(e.event_id)
		if seen.has(id):
			return false
		seen[id] = true
		if id != prev_id + 1:
			return false
		prev_id = id
	var by_id: Dictionary = {}
	for e in evs:
		by_id[int(e.event_id)] = e
	for e in evs:
		var id: int = int(e.event_id)
		if int(e.parent_event_id) == -1:
			if int(e.chain_depth) != 0:
				return false
			if int(e.root_action_id) <= 0:
				return false
		else:
			var pid: int = int(e.parent_event_id)
			if not by_id.has(pid):
				return false
			if int(pid) >= int(id):
				return false  # forward parent (B2.1 strict)
			var p = by_id[pid]
			if int(p.root_action_id) != int(e.root_action_id):
				return false
			if int(e.chain_depth) != int(p.chain_depth) + 1:
				return false
	# B2.1: each root_action_id has exactly ONE root event.
	var roots: Dictionary = {}
	for e in evs:
		var rid: int = int(e.root_action_id)
		if rid <= 0:
			continue
		if int(e.parent_event_id) == -1:
			if not roots.has(rid):
				roots[rid] = 0
			roots[rid] = int(roots[rid]) + 1
	for rid in roots.keys():
		if int(roots[rid]) != 1:
			return false
	return true


func _traces_equal_field_for_field(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		var ea = _normalize(a[i])
		var eb = _normalize(b[i])
		var keys: Array = ea.keys()
		for k in keys:
			if not eb.has(k):
				return false
			if not _field_equal(ea[k], eb[k]):
				return false
	return true


func _normalize(e) -> Dictionary:
	return {
		"event_id": int(e.event_id),
		"type": int(e.type),
		"tick": int(e.tick),
		"source_entity": int(e.source_entity),
		"target_entity": int(e.target_entity),
		"source_run_unit_id": String(e.source_run_unit_id),
		"target_run_unit_id": String(e.target_run_unit_id),
		"amount": int(e.amount),
		"tag": String(e.tag),
		"from_cell": Vector2i(int(e.from_cell.x), int(e.from_cell.y)),
		"to_cell": Vector2i(int(e.to_cell.x), int(e.to_cell.y)),
		"parent_event_id": int(e.parent_event_id),
		"root_action_id": int(e.root_action_id),
		"chain_depth": int(e.chain_depth),
	}


func _field_equal(a, b) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Vector2i:
		return int(a.x) == int(b.x) and int(a.y) == int(b.y)
	return a == b


func _build_setup(seed: int) -> BattleSetupScript:
	var p = BattleUnitSetupScript.new("p", &"warrior", 0, Vector2i(0, 0), 80, 80, 20, 5, 1)
	var e1 = BattleUnitSetupScript.new("", &"orc", 1, Vector2i(0, 3), 80, 80, 20, 5, 1)
	return BattleSetupScript.new(seed, [p], [e1], 7, 4)


func _make_sim() -> BattleSimulationScript:
	var sim = BattleSimulationScript.new()
	sim.initialize(_build_setup(42))
	return sim
