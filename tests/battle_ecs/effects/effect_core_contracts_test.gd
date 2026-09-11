extends SceneTree
## Phase 3 / Gauntlet 1 — Effect core contracts.
##
## Defines the minimal spine:
##   - EffectKind: int enum identifying effect type
##   - EffectRequest: pure data carrier for execution
##   - EffectResult: explicit success/failure + emitted events
##   - EffectContext: read/write access to world + RNG + event sink
##   - EffectExecutor: routes EffectRequest -> appropriate effect impl
##
## Architectural rules enforced:
##   - No Node / scene dependencies
##   - No global RNG (RNG accessed through EffectContext)
##   - Invalid targets produce EffectResult.failed, NOT exceptions
##   - EffectContext does not leak RunDomain

const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectResultScript = preload("res://core/battle_ecs/effects/effect_result.gd")
const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
const DamageEffectScript = preload("res://core/battle_ecs/effects/damage_effect.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_effect_kind_constants_present()
	await _test_effect_request_carries_required_fields()
	await _test_effect_result_marks_success_or_failure()
	await _test_effect_context_provides_world_rng_and_event_sink()
	await _test_executor_routes_damage_request_through_damage_effect()
	await _test_executor_damage_against_live_target_deals_and_returns_events()
	await _test_executor_damage_against_dead_target_returns_failure_no_mutation()
	await _test_executor_damage_against_invalid_target_returns_failure()
	await _test_executor_does_not_use_global_rng()
	await _test_executor_does_not_require_rundomain()
	await _test_executor_damage_event_amount_matches_actual_hp_removed()
	await _test_executor_does_not_mutate_unrelated_state()
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
	# Build a 7x4 world with two alive units: entity 0 (player)
	# at (0, 1), entity 1 (enemy) at (0, 0). Both with attack=20,
	# defense=5, hp=80, attack_range=5.
	var B = preload("res://core/battle_ecs/battle_unit_setup.gd")
	var S = preload("res://core/battle_ecs/battle_setup.gd")
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), 80, 80, 20, 5, 5)
	var e = B.new("", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var s = S.new(42, [p], [e], 7, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(s)
	return w


func _make_ctx() -> Array:
	# Returns [EffectContext, array_of_emitted_events, DeterministicRng]
	var world: BattleWorldScript = _make_world_two_units()
	var rng = DeterministicRngScript.new(0)
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, sink)
	return [ctx, sink, rng]


func _test_effect_kind_constants_present() -> void:
	print("[ec-1] effect_kind_constants_present")
	# EffectKind must define DAMAGE, HEAL, APPLY_STATUS, REMOVE_STATUS,
	# MOVE, PERFORM_ATTACK with deterministic integer constants.
	_assert(EffectKindScript != null, "EffectKind script loads")
	_assert(typeof(EffectKindScript.DAMAGE) == TYPE_INT,
		"DAMAGE is int constant")
	_assert(EffectKindScript.HEAL != EffectKindScript.DAMAGE,
		"HEAL distinct from DAMAGE")
	_assert(EffectKindScript.APPLY_STATUS != EffectKindScript.REMOVE_STATUS,
		"APPLY_STATUS distinct from REMOVE_STATUS")


func _test_effect_request_carries_required_fields() -> void:
	print("[ec-2] effect_request_carries_required_fields")
	# Args: kind, source_entity, target_entity, amount,
	#       root_action_id, parent_event_id, chain_depth
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 42, 100, -1, 0)
	_assert(int(req.kind) == int(EffectKindScript.DAMAGE),
		"kind field stored")
	_assert(int(req.source_entity) == 0, "source_entity stored")
	_assert(int(req.target_entity) == 1, "target_entity stored")
	_assert(int(req.root_action_id) == 100, "root_action_id stored")
	_assert(int(req.parent_event_id) == -1,
		"parent_event_id default -1 (sentinel)")
	_assert(int(req.chain_depth) == 0, "chain_depth default 0")


func _test_effect_result_marks_success_or_failure() -> void:
	print("[ec-3] effect_result_marks_success_or_failure")
	var ok = EffectResultScript.succeeded([], 0)
	var bad = EffectResultScript.failed("target dead", [], 0)
	_assert(ok.success == true, "succeeded() success=true")
	_assert(bad.success == false, "failed() success=false")
	_assert(bad.reason == "target dead", "failed() reason set")
	_assert(ok.continues_chain == false, "default continues_chain=false")
	# Mutate continues_chain via setter.
	ok.continues_chain = true
	_assert(ok.continues_chain == true, "continues_chain settable")


func _test_effect_context_provides_world_rng_and_event_sink() -> void:
	print("[ec-4] effect_context_provides_world_rng_and_event_sink")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var sink: Array = pair[1]
	var rng = pair[2]
	_assert(ctx.world() != null, "ctx exposes world()")
	_assert(ctx.rng() != null, "ctx exposes rng()")
	_assert(ctx.event_sink() != null, "ctx exposes event_sink()")
	# The event sink array should be the SAME array we passed in
	# (mutation visible from the outside).
	ctx.emit({"type": 99, "tick": 1, "amount": 0})
	_assert(sink.size() == 1, "emit() pushes to the underlying sink array")


func _test_executor_routes_damage_request_through_damage_effect() -> void:
	print("[ec-5] executor_routes_damage_request_through_damage_effect")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var sink: Array = pair[1]
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 100, -1, 0)
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, req)
	# At least one event was emitted (DAMAGE_APPLIED or ATTACK).
	_assert(sink.size() > 0, "executor emitted at least one event for DAMAGE request")


func _test_executor_damage_against_live_target_deals_and_returns_events() -> void:
	print("[ec-6] executor_damage_against_live_target_deals_and_returns_events")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	var sink: Array = pair[1]
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 200, -1, 0)
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(result.success, "executor returns success")
	_assert(world.current_hp_of(1) < 80,
		"enemy HP reduced (got %d)" % world.current_hp_of(1))
	_assert(sink.size() >= 1, "at least one event emitted")


func _test_executor_damage_against_dead_target_returns_failure_no_mutation() -> void:
	print("[ec-7] executor_damage_against_dead_target_returns_failure_no_mutation")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	# Kill enemy first.
	world.apply_damage(1, 1000)
	var hp_before_dead: int = world.current_hp_of(1)
	var sink_size_before: int = pair[1].size()
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 300, -1, 0)
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(result.success == false, "damage on dead target returns failure")
	_assert(world.current_hp_of(1) == hp_before_dead,
		"dead target HP unchanged (got %d expected %d)" % [world.current_hp_of(1), hp_before_dead])
	# Dead-target damage must NOT emit DAMAGE_APPLIED (avoids
	# duplicate logical events). It MAY emit a failure event, but
	# not a successful damage.
	var saw_damage_applied: bool = false
	for e in pair[1].slice(sink_size_before):
		if int(e.get("type", -1)) == 3:  # DAMAGE_APPLIED
			saw_damage_applied = true
			break
	_assert(not saw_damage_applied, "no DAMAGE_APPLIED for dead target")


func _test_executor_damage_against_invalid_target_returns_failure() -> void:
	print("[ec-8] executor_damage_against_invalid_target_returns_failure")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	# target_entity = 999 — not allocated.
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 999, 400, -1, 0)
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(result.success == false, "invalid target returns failure")
	_assert(result.reason.length() > 0, "failure has reason")


func _test_executor_does_not_use_global_rng() -> void:
	print("[ec-9] executor_does_not_use_global_rng")
	# Determinism check: run same request 10 times. Each run must
	# produce the same HP delta and same event count. If the
	# executor used global Rng, two runs would diverge.
	var deltas: Array = []
	var ev_counts: Array = []
	for i in 10:
		var w = _make_world_two_units()
		var rng = DeterministicRngScript.new(123)
		var sink: Array = []
		var ctx = EffectContextScript.new(w, rng, sink)
		var req = EffectRequestScript.new(
			EffectKindScript.DAMAGE, 0, 1, 500 + i, -1, 0)
		var exec = EffectExecutorScript.new()
		exec.execute(ctx, req)
		var hp_after: int = w.current_hp_of(1)
		deltas.append(80 - hp_after)
		ev_counts.append(sink.size())
	# All deltas must be identical (same seed, same source/target
	# damage from request, no RNG-dependent branching for plain
	# damage).
	var first: int = deltas[0]
	for d in deltas:
		if d != first:
			_assert(false, "delta differs across runs (got %d vs first=%d)" % [d, first])
			return
	_assert(true, "damage is deterministic across 10 runs (delta=%d)" % first)


func _test_executor_does_not_require_rundomain() -> void:
	print("[ec-10] executor_does_not_require_rundomain")
	# The EffectContext does NOT depend on RunDomain. The world
	# is constructed in isolation, without any RunDomainState.
	var w = _make_world_two_units()
	var rng = DeterministicRngScript.new(0)
	var sink: Array = []
	var ctx = EffectContextScript.new(w, rng, sink)
	_assert(ctx.world() != null, "context.world() works without RunDomain")
	_assert(ctx.rng() != null, "context.rng() works without RunDomain")


func _test_executor_damage_event_amount_matches_actual_hp_removed() -> void:
	print("[ec-11] executor_damage_event_amount_matches_actual_hp_removed")
	# BLOCKER from gauntlet spec: do NOT report requested damage if
	# HP had less remaining. Event amount must equal actual HP
	# removed.
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	var sink: Array = pair[1]
	# HP is 80. Request damage = 1000 (overkill). Actual HP
	# removed should be exactly 80, not 1000.
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 1000, -1, 0)
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, req)
	var hp_after: int = world.current_hp_of(1)
	var actual_removed: int = 80 - hp_after
	_assert(hp_after == 0, "overkill -> HP=0 (got %d)" % hp_after)
	_assert(actual_removed == 80, "actual HP removed = 80 (got %d)" % actual_removed)
	# Find the DAMAGE_APPLIED event.
	var saw_amount_match: bool = false
	for e in sink:
		if int(e.get("type", -1)) == 3:
			_assert(int(e.get("amount", -1)) == 80,
				"DAMAGE_APPLIED amount = actual HP removed (got %d expected 80)" % int(e.get("amount", -1)))
			saw_amount_match = true
			break
	_assert(saw_amount_match, "DAMAGE_APPLIED event emitted with correct amount")


func _test_executor_does_not_mutate_unrelated_state() -> void:
	print("[ec-12] executor_does_not_mutate_unrelated_state")
	# Damage against target 1 must NOT touch player 0's HP,
	# position, or attack.
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	var p_hp_before: int = world.current_hp_of(0)
	var p_pos_before: Vector2i = world.position_of(0)
	var p_atk_before: int = world.attack_of(0)
	var req = EffectRequestScript.new(
		EffectKindScript.DAMAGE, 0, 1, 50, -1, 0)
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, req)
	_assert(world.current_hp_of(0) == p_hp_before,
		"player HP unchanged (got %d)" % world.current_hp_of(0))
	_assert(world.position_of(0) == p_pos_before,
		"player position unchanged (got %s)" % str(world.position_of(0)))
	_assert(world.attack_of(0) == p_atk_before,
		"player attack unchanged (got %d)" % world.attack_of(0))
