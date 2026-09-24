extends SceneTree
## B6.1 Task 2 RED — perform_attack_effect contract.
##
## Drives PerformAttackEffect.execute(ctx, req) directly via
## EffectExecutor against minimal BattleWorld fixtures. Covers:
##   - root attack exact trace (non-lethal)
##   - root attack exact trace (lethal + UNIT_DIED)
##   - full validation matrix (each branch must produce:
##     success=false, no world mutation, no HP change,
##     no events, emitter counters unchanged)

const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const BattleEventEmitterScript = preload(
	"res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleWorldScript = preload(
	"res://core/battle_ecs/world/battle_world.gd")
const BattleSetupScript = preload(
	"res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload(
	"res://core/battle_ecs/battle_unit_setup.gd")
const DeterministicRngScript = preload(
	"res://core/rng/deterministic_rng.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")
const EffectResultScript = preload(
	"res://core/battle_ecs/effects/effect_result.gd")
const EffectExecutorScript = preload(
	"res://core/battle_ecs/effects/effect_executor.gd")
const EffectContextScript = preload(
	"res://core/battle_ecs/effects/effect_context.gd")
const PerformAttackEffectScript = preload(
	"res://core/battle_ecs/effects/perform_attack_effect.gd")
const StatQueryScript = preload(
	"res://core/battle_ecs/status/stat_query.gd")
const StatusInstanceScript = preload(
	"res://core/battle_ecs/status/status_instance.gd")
const ContentDBScript = preload(
	"res://core/utils/content_db.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	await _test_root_attack_exact_trace()
	await _test_lethal_root_exact_trace()
	await _test_full_validation_matrix()
	# B6.1.1 added coverage.
	await _test_effect_executor_routing_root()
	await _test_amount_nonzero_rejected()
	await _test_sink_result_parity_root_and_lethal()
	await _test_child_attack_with_real_parent_event()
	await _test_effect_executor_null_request_rejected()
	await _test_root_attack_identity_invariant()
	print("\n=== B6.1 perform_attack contract (RED): %d pass / %d fail ===\n" % [_passed, _failed])
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


# ============================================================
# Fixture: minimal live player+enemy. Reused per test.
# ============================================================

class _Fixture:
	var world: RefCounted
	var emitter: RefCounted
	var rng: RefCounted
	var event_id_before: int
	var root_id_before: int

	func reset_counters() -> void:
		event_id_before = int(emitter.peek_next_event_id())
		root_id_before = int(emitter.peek_next_root_action_id())


func _make_fixture(p_p_hp: int = 100, p_e_hp: int = 100,
		p_p_atk: int = 50, p_p_range: int = 1,
		p_e_atk: int = 0) -> _Fixture:
	var w = BattleWorldScript.new(7, 4)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var p0 = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0),
		p_p_hp, p_p_hp, p_p_atk, 5, p_p_range)
	var e0 = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1),
		p_e_hp, p_e_hp, p_e_atk, 5, 1)
	var s = BattleSetupScript.new(42, [p0], [e0], 7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	var fx = _Fixture.new()
	fx.world = w
	fx.emitter = em
	fx.rng = rng
	fx.reset_counters()
	return fx


# ============================================================
# Attack helpers
# ============================================================

func _root_attack(fx: _Fixture) -> RefCounted:
	var req = EffectRequestScript.root(
		EffectKindScript.PERFORM_ATTACK, 0, 1, 0)
	return _run(fx, req)


func _child_attack(fx: _Fixture, parent) -> RefCounted:
	# Build a template by emitting/stealing the attacker +
	# target swap, but for the simplest case just build a
	# child template manually with parent_event_id from `parent`.
	var req = EffectRequestScript.child_from_template(
		EffectRequestScript.root(
			EffectKindScript.PERFORM_ATTACK, 1, 0, 0),
		parent)
	return _run(fx, req)


func _run(fx: _Fixture, req) -> RefCounted:
	var sink: Array = []
	var ctx = EffectContextScript.new(
		fx.world, fx.rng, fx.emitter, sink)
	return PerformAttackEffectScript.execute(ctx, req)


# ============================================================
# ROOT NON-LETHAL
# ============================================================

func _test_root_attack_exact_trace() -> void:
	print("[B61-ROOT] root_attack_exact_trace")
	var fx = _make_fixture(100, 100, 50, 5, 0)
	var hp_before: int = int(fx.world.current_hp_of(1))
	var result = _root_attack(fx)
	_assert(result != null, "result returned")
	_assert(result.success == true,
		"root attack succeeded")
	_assert(result.events.size() == 2,
		"root non-lethal events.size()==2 (got %d)" % result.events.size())
	# Event 0: ATTACK_RESOLVED with parent=-1, depth=0.
	var atk = result.events[0]
	_assert(int(atk.type) == BattleEventTypeScript.ATTACK_RESOLVED,
		"events[0].type == ATTACK_RESOLVED")
	_assert(int(atk.parent_event_id) == -1,
		"events[0].parent_event_id == -1 (root)")
	_assert(int(atk.chain_depth) == 0,
		"events[0].chain_depth == 0 (root)")
	_assert(int(atk.source_entity) == 0,
		"events[0].source_entity == player")
	_assert(int(atk.target_entity) == 1,
		"events[0].target_entity == enemy")
	# Damage from Balance.compute_damage(50, 5, false, 0.0, 1.0).
	# ATTACK_RESOLVED.amount = RAW damage; DAMAGE_APPLIED.amount = applied.
	# Raw_damage here at 50/5 def: Balance subtracts roughly defense,
	# leaving ~45 actual damage pre-cap.
	_assert(int(atk.amount) > 0,
		"events[0].amount (raw) > 0")
	_assert(int(atk.root_action_id) > 0,
		"events[0].root_action_id > 0")
	# Event 1: DAMAGE_APPLIED, child of atk, depth=1.
	var dmg = result.events[1]
	_assert(int(dmg.type) == BattleEventTypeScript.DAMAGE_APPLIED,
		"events[1].type == DAMAGE_APPLIED")
	_assert(int(dmg.parent_event_id) == int(atk.event_id),
		"events[1].parent_event_id == events[0].event_id")
	_assert(int(dmg.chain_depth) == 1,
		"events[1].chain_depth == 1")
	_assert(int(dmg.root_action_id) == int(atk.root_action_id),
		"events[1].root_action_id matches events[0]")
	_assert(int(dmg.amount) <= int(atk.amount),
		"DAMAGE_APPLIED.amount <= ATTACK_RESOLVED.amount (HP cap)")
	# Target HP decreased by dmg.amount.
	var hp_after: int = int(fx.world.current_hp_of(1))
	_assert(hp_after == hp_before - int(dmg.amount),
		"target HP decreased by dmg.amount")
	_assert(hp_after > 0, "target still alive (non-lethal)")
	# Sink length equals events size (single insertion path).
	# Event IDs unique.
	var seen: Dictionary = {}
	for e in result.events:
		if seen.has(int(e.event_id)):
			_assert(false, "event_id=%d duplicated" % int(e.event_id))
			return
		seen[int(e.event_id)] = true
	_assert(true, "all event_ids unique (%d)" % result.events.size())


# ============================================================
# ROOT LETHAL
# ============================================================

func _test_lethal_root_exact_trace() -> void:
	print("[B61-LDH] lethal_root_exact_trace")
	# Enemy has 5 HP so 50-atk vs 5-def kills it.
	var fx = _make_fixture(100, 5, 50, 5, 0)
	var result = _root_attack(fx)
	_assert(result != null, "result returned")
	_assert(result.success == true,
		"lethal root attack succeeded")
	_assert(result.events.size() == 3,
		"lethal events.size()==3 (got %d)" % result.events.size())
	var atk = result.events[0]
	var dmg = result.events[1]
	var died = result.events[2]
	_assert(int(died.type) == BattleEventTypeScript.UNIT_DIED,
		"events[2].type == UNIT_DIED")
	_assert(int(died.parent_event_id) == int(dmg.event_id),
		"UNIT_DIED.parent_event_id == DAMAGE_APPLIED.event_id")
	_assert(int(died.chain_depth) == 2,
		"UNIT_DIED.chain_depth == 2")
	_assert(int(died.root_action_id) == int(atk.root_action_id),
		"UNIT_DIED shares root_action_id")
	_assert(int(fx.world.current_hp_of(1)) <= 0,
		"target HP <= 0")
	_assert(fx.world.is_alive(1) == false,
		"target is_alive(1) == false")


# ============================================================
# VALIDATION MATRIX
# ============================================================

func _test_full_validation_matrix() -> void:
	print("[B61-VMAT] full_validation_matrix")
	# Build a base fixture with player + enemy, both alive.
	var fx = _make_fixture(100, 100, 50, 5, 0)
	# Expect: each rejection leaves the world untouched
	# (target HP unchanged, target still alive, no event
	# counter advancement).
	_run_expect_fail("malformed ancestry (root shape with chain_depth!=0)",
		fx, EffectRequestScript.new(
			EffectKindScript.PERFORM_ATTACK, 0, 1, 0,
			0, 0, 1))  # root_action_id=0 → INVALID
	_run_expect_fail("dead source",
		fx, _root_req_after_killing_source(fx))
	_run_expect_fail("dead target",
		fx, _root_req_for_dead_target(fx))
	_run_expect_fail("source == target",
		fx, EffectRequestScript.root(
			EffectKindScript.PERFORM_ATTACK, 0, 0, 0))
	# Build a fixture with TWO enemies and a third enemy for
	# "same team": place a teammate of the player so we can
	# request PerformAttack against him.
	var fx_same_team = _make_fixture_with_teammate()
	_run_expect_fail("same team",
		fx_same_team, EffectRequestScript.root(
			EffectKindScript.PERFORM_ATTACK, 0, 2, 0))
	# out-of-range: enemy 1 far from player at (6, 3) vs
	# player at (0,0). Range 5 → Manhattan or cell distance
	# > 5.
	_run_expect_fail("out of range",
		_make_fixture_with_distant_enemy(),
		EffectRequestScript.root(
			EffectKindScript.PERFORM_ATTACK, 0, 2, 0))
	# stunned source: real Stun applied to player 0.
	_run_expect_fail("stunned source",
		_make_stunned_fixture(),
		EffectRequestScript.root(
			EffectKindScript.PERFORM_ATTACK, 0, 1, 0))


func _run_expect_fail(label: String, fx: _Fixture, req) -> void:
	var hp_before: int = int(fx.world.current_hp_of(1))
	var alive_before: bool = bool(fx.world.is_alive(1))
	var emit_before: int = int(fx.emitter.peek_next_event_id())
	var root_before: int = int(fx.emitter.peek_next_root_action_id())
	var result = _run(fx, req)
	var hp_after: int = int(fx.world.current_hp_of(1))
	var alive_after: bool = bool(fx.world.is_alive(1))
	var emit_after: int = int(fx.emitter.peek_next_event_id())
	var root_after: int = int(fx.emitter.peek_next_root_action_id())
	_assert(result.success == false,
		"%s: result.success == false" % label)
	_assert(result.events.size() == 0,
		"%s: empty events (got %d)" % [label, result.events.size()])
	_assert(hp_after == hp_before,
		"%s: target HP unchanged" % label)
	_assert(alive_after == alive_before,
		"%s: alive unchanged" % label)
	_assert(emit_after == emit_before,
		"%s: emitter counter unchanged" % label)
	_assert(root_after == root_before,
		"%s: emitter root counter unchanged" % label)


func _root_req_after_killing_source(fx: _Fixture) -> RefCounted:
	# Kill source by setting HP to 0 (dead).
	fx.world.remove_entity(0)
	return EffectRequestScript.root(
		EffectKindScript.PERFORM_ATTACK, 0, 1, 0)


func _root_req_for_dead_target(fx: _Fixture) -> RefCounted:
	fx.world.remove_entity(1)
	return EffectRequestScript.root(
		EffectKindScript.PERFORM_ATTACK, 0, 1, 0)


func _make_fixture_with_distant_enemy() -> _Fixture:
	var w = BattleWorldScript.new(7, 4)
	var em = BattleEventEmitterScript.new()
	em.reset()
	# Player at (0,0); enemy entity 2 at (6,3) — far out of range 5.
	var p0 = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1)
	var e0 = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(3, 3), 100, 100, 20, 5, 1)
	var e1 = BattleUnitSetupScript.new(
		"e1", &"ogre", 2, Vector2i(6, 3), 100, 100, 20, 5, 1)
	var s = BattleSetupScript.new(42, [p0], [e0, e1], 7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	var fx = _Fixture.new()
	fx.world = w
	fx.emitter = em
	fx.rng = rng
	fx.reset_counters()
	return fx


func _make_stunned_fixture() -> _Fixture:
	var w = BattleWorldScript.new(7, 4)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var p0 = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1)
	var e0 = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1)
	var s = BattleSetupScript.new(42, [p0], [e0], 7, 4)
	w.spawn_from_setup(s)
	# Inject real Stun on player 0 via StatusContainer.
	# _init(p_status_id, p_source_entity, p_target_entity,
	#        p_stacks=1, p_duration=-1, p_magnitude=0)
	var container = w.create_status_container(0)
	var inst = StatusInstanceScript.new(
		&"stun", 0, 0, 1, 2, 0)
	container.add(inst, "unique", 1)
	var rng = DeterministicRngScript.new(0)
	var fx = _Fixture.new()
	fx.world = w
	fx.emitter = em
	fx.rng = rng
	fx.reset_counters()
	return fx


func _make_fixture_with_teammate() -> _Fixture:
	# Same-team test: player (id=0) attacks player 2 (teammate).
	var w = BattleWorldScript.new(7, 4)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var p0 = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1)
	var e0 = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 3), 100, 100, 20, 5, 1)
	var p1 = BattleUnitSetupScript.new(
		"p1", &"ally", 0, Vector2i(0, 1), 100, 100, 20, 5, 1)
	var s = BattleSetupScript.new(42, [p0, p1], [e0], 7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	var fx = _Fixture.new()
	fx.world = w
	fx.emitter = em
	fx.rng = rng
	fx.reset_counters()
	return fx
## Drive the EFFECT-EXECUTOR pipeline (not PerformAttack directly).
## Returns BOTH result AND sink so the test can assert event-identity
## parity between the two.
func _run_executor(fx, req) -> Dictionary:
	var sink: Array = []
	var ctx = EffectContextScript.new(fx.world, fx.rng, fx.emitter, sink)
	var result = EffectExecutorScript.new().execute(ctx, req)
	return {"result": result, "sink": sink}

func _arrays_share_object_events(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true

func source_run_unit_id_of_helper(p_id: int) -> String:
	return "p0" if p_id == 0 else "e0"

func _test_effect_executor_routing_root() -> void:
	print("[B611-EX] effect_executor_routing_root")
	var fx = _make_fixture(100, 100, 50, 5, 0)
	var req = EffectRequestScript.root(EffectKindScript.PERFORM_ATTACK, 0, 1, 0)
	var R = _run_executor(fx, req)
	var result: RefCounted = R["result"]
	_assert(result != null, "executor returned non-null result")
	_assert(result.success == true, "PERFORM_ATTACK via executor: success")
	_assert(result.events.size() == 2, "PERFORM_ATTACK via executor: 2 events (got %d) " % result.events.size())
	var atk = result.events[0]
	_assert(int(atk.type) == BattleEventTypeScript.ATTACK_RESOLVED, "executor dispatch reached PerformAttackEffect (ATTACK_RESOLVED)")

func _test_amount_nonzero_rejected() -> void:
	print("[B611-AMT] amount_nonzero_rejected")
	var fx = _make_fixture(100, 100, 50, 5, 0)
	var hp_before: int = int(fx.world.current_hp_of(1))
	var bad = EffectRequestScript.root(EffectKindScript.PERFORM_ATTACK, 0, 1, 999)
	var R = _run_executor(fx, bad)
	var result: RefCounted = R["result"]
	_assert(result != null, "result returned")
	_assert(result.success == false, "amount!=0 must be rejected (got success=true)")
	_assert(result.events.size() == 0, "amount!=0: events empty (got %d)" % result.events.size())
	_assert(int(fx.world.current_hp_of(1)) == hp_before, "amount!=0: target HP unchanged")
	var sink: Array = []
	var ctx = EffectContextScript.new(fx.world, fx.rng, fx.emitter, sink)
	var direct = PerformAttackEffectScript.execute(ctx, bad)
	_assert(direct.success == false, "amount!=0 direct effect call: success=false")
	_assert(direct.events.size() == 0, "amount!=0 direct effect: events empty")
	_assert(sink.size() == 0, "amount!=0: executor sink empty")

func _test_sink_result_parity_root_and_lethal() -> void:
	print("[B611-SINK] sink_result_parity_root_and_lethal")
	var fx1 = _make_fixture(100, 100, 50, 5, 0)
	var req1 = EffectRequestScript.root(EffectKindScript.PERFORM_ATTACK, 0, 1, 0)
	var R1 = _run_executor(fx1, req1)
	var result1: RefCounted = R1["result"]
	var sink1: Array = R1["sink"]
	_assert(result1.success == true, "non-lethal root: success")
	_assert(sink1.size() == result1.events.size(), "non-lethal: sink.size==result.events.size")
	_assert(_arrays_share_object_events(sink1, result1.events), "non-lethal sink[i]===result.events[i]")
	var seen: Dictionary = {}
	var dup: Array = []
	for e in result1.events:
		var id: int = int(e.event_id)
		if seen.has(id):
			dup.append(id)
		else:
			seen[id] = true
	_assert(dup.size() == 0, "non-lethal: event_ids unique")

	var fx2 = _make_fixture(100, 5, 50, 5, 0)
	var req2 = EffectRequestScript.root(EffectKindScript.PERFORM_ATTACK, 0, 1, 0)
	var R2 = _run_executor(fx2, req2)
	var result2: RefCounted = R2["result"]
	var sink2: Array = R2["sink"]
	_assert(result2.success == true, "lethal root: success")
	_assert(result2.events.size() == 3, "lethal: 3 events (got %d)" % result2.events.size())
	_assert(_arrays_share_object_events(sink2, result2.events), "lethal sink[i]===result.events[i]")
	var died_count: int = 0
	var died_last: bool = true
	for i in result2.events.size():
		if int(result2.events[i].type) == BattleEventTypeScript.UNIT_DIED:
			died_count += 1
			if i != result2.events.size() - 1:
				died_last = false
	_assert(died_count == 1, "lethal: UNIT_DIED == 1 (got %d)" % died_count)
	_assert(died_last, "lethal: UNIT_DIED is final event")

func _test_child_attack_with_real_parent_event() -> void:
	print("[B611-CHILD] child_attack_with_real_parent_event")
	var fx = _make_fixture(100, 100, 50, 5, 0)
	var parent_req = EffectRequestScript.root(EffectKindScript.PERFORM_ATTACK, 0, 1, 0)
	var R0 = _run_executor(fx, parent_req)
	var root_result: RefCounted = R0["result"]
	_assert(root_result.success == true, "parent root attack succeeded")
	var template = EffectRequestScript.root(EffectKindScript.PERFORM_ATTACK, 1, 0, 0)
	var P_event = root_result.events[1]
	var child_req = EffectRequestScript.child_from_template(template, P_event)
	_assert(child_req != null, "child_from_template non-null")
	_assert(int(child_req.parent_event_id) == int(P_event.event_id), "child parent_event_id matches DAMAGE_APPLIED")
	_assert(int(child_req.root_action_id) == int(P_event.root_action_id), "child root_action_id matches parent")
	_assert(int(child_req.chain_depth) == int(P_event.chain_depth) + 1, "child chain_depth == parent.chain_depth + 1")
	var sink: Array = []
	var ctx2 = EffectContextScript.new(fx.world, fx.rng, fx.emitter, sink)
	var result = EffectExecutorScript.new().execute(ctx2, child_req)
	_assert(result != null, "child executor result non-null")
	_assert(result.success == true, "child attack succeeded")
	_assert(result.events.size() == 2, "child: 2 events (got %d)" % result.events.size())
	var child_atk = result.events[0]
	var child_dmg = result.events[1]
	_assert(int(child_atk.type) == BattleEventTypeScript.ATTACK_RESOLVED, "child events[0] is ATTACK_RESOLVED")
	_assert(int(child_atk.parent_event_id) == int(P_event.event_id), "child ATTACK_RESOLVED.parent_event_id == P.event_id")
	_assert(int(child_atk.root_action_id) == int(P_event.root_action_id), "child ATTACK_RESOLVED shares root_action_id with P")
	_assert(int(child_atk.chain_depth) == int(P_event.chain_depth) + 1, "child ATTACK_RESOLVED.chain_depth == P.chain_depth+1")
	_assert(int(child_dmg.parent_event_id) == int(child_atk.event_id), "child DAMAGE_APPLIED.parent_event_id == child attack.event_id")
	_assert(int(child_dmg.root_action_id) == int(P_event.root_action_id), "child DAMAGE_APPLIED shares root_action_id with P")
	_assert(int(child_dmg.chain_depth) == int(child_atk.chain_depth) + 1, "child DAMAGE_APPLIED.depth == child attack.depth+1")
	_assert(_arrays_share_object_events(sink, result.events), "child sink[i]===result.events[i]")

func _test_effect_executor_null_request_rejected() -> void:
	print("[B611-NULL] effect_executor_null_request_rejected")
	var fx = _make_fixture(100, 100, 50, 5, 0)
	var R = _run_executor(fx, null)
	var result: RefCounted = R["result"]
	var sink: Array = R["sink"]
	_assert(result != null, "executor null: result non-null")
	_assert(result.success == false, "executor null: success=false")
	_assert(result.events.size() == 0, "executor null: events empty")
	_assert(sink.size() == 0, "executor null: sink empty (no advance)")

func _test_root_attack_identity_invariant() -> void:
	print("[B611-ID] root_attack_identity_invariant")
	var fx = _make_fixture(100, 100, 50, 5, 0)
	var R = _run_executor(fx, EffectRequestScript.root(EffectKindScript.PERFORM_ATTACK, 0, 1, 0))
	var result: RefCounted = R["result"]
	for e in result.events:
		var src_id: int = int(e.source_entity)
		var tgt_id: int = int(e.target_entity)
		var src_expected: String = "p0" if src_id == 0 else "e0"
		var tgt_expected: String = "p0" if tgt_id == 0 else "e0"
		_assert(String(e.source_run_unit_id) == src_expected, "event id=%d source_run_unit_id matches entity %d (got '%s')" % [int(e.event_id), src_id, String(e.source_run_unit_id)])
		_assert(String(e.target_run_unit_id) == tgt_expected, "event id=%d target_run_unit_id matches entity %d (got '%s')" % [int(e.event_id), tgt_id, String(e.target_run_unit_id)])
		_assert(String(e.source_run_unit_id) == source_run_unit_id_of_helper(src_id), "source_run_unit_id_of invariant on event id=%d" % int(e.event_id))
		_assert(String(e.target_run_unit_id) == source_run_unit_id_of_helper(tgt_id), "target_run_unit_id_of is thin alias on event id=%d" % int(e.event_id))
