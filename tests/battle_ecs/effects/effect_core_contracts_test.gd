extends SceneTree
## Phase 3 / Gauntlet 1 — Effect core contracts.
##
## Rewritten in Stage A to use the central BattleEventEmitter.
## Every emitted event is a real BattleEvent object (not
## Dictionary). The shared emitter is the single event ID
## authority across all effects in a simulation.

const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectResultScript = preload("res://core/battle_ecs/effects/effect_result.gd")
const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const BattleEventScript = preload("res://core/battle_ecs/battle_event.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_effect_kind_constants_present()
	await _test_effect_request_carries_required_fields()
	await _test_effect_result_marks_success_or_failure()
	await _test_effect_context_provides_world_rng_emitter_and_sink()
	await _test_executor_routes_damage_request_through_damage_effect()
	await _test_executor_damage_against_live_target_deals_and_returns_events()
	await _test_executor_damage_against_dead_target_returns_failure_no_mutation()
	await _test_executor_damage_against_invalid_target_returns_failure()
	await _test_executor_does_not_use_global_rng()
	await _test_executor_does_not_require_rundomain()
	await _test_executor_damage_event_amount_matches_actual_hp_removed()
	await _test_executor_does_not_mutate_unrelated_state()
	await _test_executor_damage_emits_battleevent_with_real_event_id()
	await _test_executor_damage_does_not_emit_attack_resolved()
	await _test_executor_damage_lethal_emits_unit_died_as_child()
	await _test_emitter_first_event_id_starts_at_1()
	await _test_two_emitters_have_independent_namespaces()
	await _test_two_effects_share_one_emitter_sequence()
	print("\n=== effect core contracts: %d passed, %d failed ===\n" % [_passed, _failed])
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


func _make_world_two_units() -> BattleWorldScript:
	var B = preload("res://core/battle_ecs/battle_unit_setup.gd")
	var S = preload("res://core/battle_ecs/battle_setup.gd")
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), 80, 80, 20, 5, 5)
	var e = B.new("", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var s = S.new(42, [p], [e], 7, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(s)
	return w


func _make_ctx() -> Array:
	# Returns [EffectContext, sink, rng, emitter].
	var world: BattleWorldScript = _make_world_two_units()
	var rng = DeterministicRngScript.new(0)
	var emitter = BattleEventEmitterScript.new()
	emitter.reset()
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	return [ctx, sink, rng, emitter]


# === Existing effect core tests (refactored for emitter) ===

func _test_effect_kind_constants_present() -> void:
	print("[ec-1] effect_kind_constants_present")
	_assert(EffectKindScript != null, "EffectKind script loads")
	_assert(typeof(EffectKindScript.DAMAGE) == TYPE_INT, "DAMAGE is int constant")
	_assert(EffectKindScript.HEAL != EffectKindScript.DAMAGE, "HEAL distinct from DAMAGE")
	_assert(EffectKindScript.APPLY_STATUS != EffectKindScript.REMOVE_STATUS,
		"APPLY_STATUS distinct from REMOVE_STATUS")


func _test_effect_request_carries_required_fields() -> void:
	print("[ec-2] effect_request_carries_required_fields")
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 42, 100, -1, 0)
	_assert(int(req.kind) == int(EffectKindScript.DAMAGE), "kind field stored")
	_assert(int(req.source_entity) == 0, "source_entity stored")
	_assert(int(req.target_entity) == 1, "target_entity stored")
	_assert(int(req.root_action_id) == 100, "root_action_id stored")
	_assert(int(req.parent_event_id) == -1, "parent_event_id default -1 (sentinel)")
	_assert(int(req.chain_depth) == 0, "chain_depth default 0")


func _test_effect_result_marks_success_or_failure() -> void:
	print("[ec-3] effect_result_marks_success_or_failure")
	var ok = EffectResultScript.succeeded([], 0)
	var bad = EffectResultScript.failed("target dead", [], 0)
	_assert(ok.success == true, "succeeded() success=true")
	_assert(bad.success == false, "failed() success=false")
	_assert(bad.reason == "target dead", "failed() reason set")
	_assert(ok.continues_chain == false, "default continues_chain=false")
	ok.continues_chain = true
	_assert(ok.continues_chain == true, "continues_chain settable")


func _test_effect_context_provides_world_rng_emitter_and_sink() -> void:
	print("[ec-4] effect_context_provides_world_rng_emitter_and_sink")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var sink: Array = pair[1]
	var emitter = pair[3]
	_assert(ctx.world() != null, "ctx exposes world()")
	_assert(ctx.rng() != null, "ctx exposes rng()")
	_assert(ctx.emitter() != null, "ctx exposes emitter()")
	_assert(ctx.event_sink() != null, "ctx exposes event_sink()")
	# emitter is the central allocator
	var ev = ctx.emitter().emit(
		BattleEventTypeScript.UNIT_MOVED, 0, 0, "", "", 0, "",
		Vector2i(0, 0), Vector2i(0, 1))
	_assert(ev.event_id >= 1, "emitted event has event_id >= 1")
	ctx.emit_through_sink(ev)
	_assert(sink.size() == 1, "sink receives the event")
	_assert(sink[0].event_id == ev.event_id,
		"sink event is the same BattleEvent object")


func _test_executor_routes_damage_request_through_damage_effect() -> void:
	print("[ec-5] executor_routes_damage_request_through_damage_effect")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var sink: Array = pair[1]
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 100, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, req)
	_assert(sink.size() > 0, "executor emitted at least one event for DAMAGE request")


func _test_executor_damage_against_live_target_deals_and_returns_events() -> void:
	print("[ec-6] executor_damage_against_live_target_deals_and_returns_events")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	var sink: Array = pair[1]
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 200, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(result.success, "executor returns success")
	_assert(world.current_hp_of(1) < 80, "enemy HP reduced (got %d)" % world.current_hp_of(1))
	_assert(sink.size() >= 1, "at least one event emitted")


func _test_executor_damage_against_dead_target_returns_failure_no_mutation() -> void:
	print("[ec-7] executor_damage_against_dead_target_returns_failure_no_mutation")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	world.apply_damage(1, 1000)
	var hp_before_dead: int = world.current_hp_of(1)
	var sink_size_before: int = pair[1].size()
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 300, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(result.success == false, "damage on dead target returns failure")
	_assert(world.current_hp_of(1) == hp_before_dead,
		"dead target HP unchanged (got %d expected %d)" % [world.current_hp_of(1), hp_before_dead])
	# No DAMAGE_APPLIED event emitted for dead target.
	var saw_damage_applied: bool = false
	for e in pair[1].slice(sink_size_before):
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			saw_damage_applied = true
			break
	_assert(not saw_damage_applied, "no DAMAGE_APPLIED for dead target")


func _test_executor_damage_against_invalid_target_returns_failure() -> void:
	print("[ec-8] executor_damage_against_invalid_target_returns_failure")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 999, 400, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(result.success == false, "invalid target returns failure")
	_assert(result.reason.length() > 0, "failure has reason")


func _test_executor_does_not_use_global_rng() -> void:
	print("[ec-9] executor_does_not_use_global_rng")
	# Determinism check: same setup + same request across runs.
	var deltas: Array = []
	var ev_counts: Array = []
	for i in 10:
		var w = _make_world_two_units()
		var rng = DeterministicRngScript.new(123)
		var emitter = BattleEventEmitterScript.new()
		emitter.reset()
		var sink: Array = []
		var ctx = EffectContextScript.new(w, rng, emitter, sink)
		var req = EffectRequestScript.new(
			EffectKindScript.DAMAGE, 0, 1, 500 + i, -1, -1, 0)
		var exec = EffectExecutorScript.new()
		exec.execute(ctx, req)
		deltas.append(80 - w.current_hp_of(1))
		ev_counts.append(sink.size())
	var first: int = deltas[0]
	for d in deltas:
		if d != first:
			_assert(false, "delta differs across runs")
			return
	_assert(true, "damage is deterministic across 10 runs (delta=%d)" % first)


func _test_executor_does_not_require_rundomain() -> void:
	print("[ec-10] executor_does_not_require_rundomain")
	var w = _make_world_two_units()
	var rng = DeterministicRngScript.new(0)
	var emitter = BattleEventEmitterScript.new()
	emitter.reset()
	var sink: Array = []
	var ctx = EffectContextScript.new(w, rng, emitter, sink)
	_assert(ctx.world() != null, "context.world() works without RunDomain")
	_assert(ctx.rng() != null, "context.rng() works without RunDomain")


func _test_executor_damage_event_amount_matches_actual_hp_removed() -> void:
	print("[ec-11] executor_damage_event_amount_matches_actual_hp_removed")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	var sink: Array = pair[1]
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 1000, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, req)
	var hp_after: int = world.current_hp_of(1)
	var actual_removed: int = 80 - hp_after
	_assert(hp_after == 0, "overkill -> HP=0 (got %d)" % hp_after)
	_assert(actual_removed == 80, "actual HP removed = 80 (got %d)" % actual_removed)
	var saw_amount_match: bool = false
	for e in sink:
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			_assert(int(e.amount) == 80,
				"DAMAGE_APPLIED amount = actual HP removed (got %d expected 80)" % int(e.amount))
			saw_amount_match = true
			break
	_assert(saw_amount_match, "DAMAGE_APPLIED BattleEvent with correct amount")


func _test_executor_does_not_mutate_unrelated_state() -> void:
	print("[ec-12] executor_does_not_mutate_unrelated_state")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	var p_hp_before: int = world.current_hp_of(0)
	var p_pos_before: Vector2i = world.position_of(0)
	var p_atk_before: int = world.attack_of(0)
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 50, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, req)
	_assert(world.current_hp_of(0) == p_hp_before, "player HP unchanged")
	_assert(world.position_of(0) == p_pos_before, "player position unchanged")
	_assert(world.attack_of(0) == p_atk_before, "player attack unchanged")


# === NEW (A8) — DamageEffect MUST NOT emit ATTACK_RESOLVED ===

func _test_executor_damage_emits_battleevent_with_real_event_id() -> void:
	print("[ec-13] executor_damage_emits_battleevent_with_real_event_id [A8]")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var sink: Array = pair[1]
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 50, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, req)
	_assert(sink.size() >= 1, "at least one event emitted")
	var first = sink[0]
	_assert(int(first.event_id) >= 1,
		"event has real event_id (got %d)" % int(first.event_id))
	_assert(int(first.type) == BattleEventTypeScript.DAMAGE_APPLIED,
		"first event type = DAMAGE_APPLIED (got %d)" % int(first.type))
	_assert(int(first.source_entity) == 0, "source_entity matches")
	_assert(int(first.target_entity) == 1, "target_entity matches")


func _test_executor_damage_does_not_emit_attack_resolved() -> void:
	print("[ec-14] executor_damage_does_not_emit_attack_resolved [A8]")
	# Generic DamageEffect must NOT emit ATTACK_RESOLVED.
	# Poison / Burn / Thorns / environmental damage all flow
	# through DamageEffect and must not masquerade as attacks.
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var sink: Array = pair[1]
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 50, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, req)
	var saw_attack: bool = false
	for e in sink:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED:
			saw_attack = true
			break
	_assert(not saw_attack,
		"DamageEffect alone MUST NOT emit ATTACK_RESOLVED (got %d events)" % sink.size())


func _test_executor_damage_lethal_emits_unit_died_as_child() -> void:
	print("[ec-15] executor_damage_lethal_emits_unit_died_as_child [A9]")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var sink: Array = pair[1]
	# Lethal damage.
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 999, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, req)
	# Find DAMAGE_APPLIED and UNIT_DIED.
	var dmg_event = null
	var died_event = null
	for e in sink:
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED and dmg_event == null:
			dmg_event = e
		if int(e.type) == BattleEventTypeScript.UNIT_DIED and died_event == null:
			died_event = e
	_assert(dmg_event != null, "DAMAGE_APPLIED emitted")
	_assert(died_event != null, "UNIT_DIED emitted on lethal damage")
	_assert(int(died_event.parent_event_id) == int(dmg_event.event_id),
		"UNIT_DIED.parent_event_id = DAMAGE_APPLIED.event_id")
	_assert(int(died_event.root_action_id) == int(dmg_event.root_action_id),
		"UNIT_DIED.root_action_id matches DAMAGE_APPLIED")
	_assert(int(died_event.chain_depth) == int(dmg_event.chain_depth) + 1,
		"UNIT_DIED.chain_depth = parent + 1")


# === NEW — Emitter contract (A4, A17) ===

func _test_emitter_first_event_id_starts_at_1() -> void:
	print("[em-1] emitter_first_event_id_starts_at_1 [A4]")
	var emitter = BattleEventEmitterScript.new()
	emitter.reset()
	var e1 = emitter.emit(BattleEventTypeScript.UNIT_MOVED)
	var e2 = emitter.emit(BattleEventTypeScript.DAMAGE_APPLIED)
	_assert(int(e1.event_id) == 1, "first event_id == 1")
	_assert(int(e2.event_id) == 2, "second event_id == 2")


func _test_two_emitters_have_independent_namespaces() -> void:
	print("[em-2] two_emitters_have_independent_namespaces [A17]")
	var ea = BattleEventEmitterScript.new()
	ea.reset()
	var eb = BattleEventEmitterScript.new()
	eb.reset()
	var ea1 = ea.emit(BattleEventTypeScript.UNIT_MOVED)
	var eb1 = eb.emit(BattleEventTypeScript.UNIT_MOVED)
	_assert(int(ea1.event_id) == 1, "emitter A first id = 1")
	_assert(int(eb1.event_id) == 1, "emitter B first id = 1 (independent)")
	var ea2 = ea.emit(BattleEventTypeScript.UNIT_MOVED)
	_assert(int(ea2.event_id) == 2, "emitter A second id = 2")
	_assert(int(eb1.event_id) == 1, "emitter B still at id 1 after A advances")


func _test_two_effects_share_one_emitter_sequence() -> void:
	print("[em-3] two_effects_share_one_emitter_sequence [A4]")
	# Damage event id 1, Heal event id 2 — proves shared namespace.
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	# Damage target first, then heal: ensures heal actually fires.
	world.apply_damage(0, 50)
	var req_d = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 30, -1, -1, 0)
	var req_h = EffectRequestScript.new(
		EffectKindScript.HEAL, 1, 0, 20, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, req_d)
	exec.execute(ctx, req_h)
	var sink: Array = pair[1]
	_assert(sink.size() == 2, "two effects = two events (got %d)" % sink.size())
	_assert(int(sink[0].event_id) == 1, "first event id = 1 (got %d)" % int(sink[0].event_id))
	_assert(int(sink[1].event_id) == 2, "second event id = 2 (got %d)" % int(sink[1].event_id))
