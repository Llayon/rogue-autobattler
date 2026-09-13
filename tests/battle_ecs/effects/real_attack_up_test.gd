extends SceneTree
## Phase 3 / B1 — Real-content AttackUp integration test.
##
## Uses the ACTUAL content/effects/attack_up.tres (NOT a synthetic
## fake definition). Verifies:
##   - ApplyStatusEffect resolves the real StatusDef via ContentDB.
##   - duration conversion: StatusDef.duration (float) -> runtime
##     ticks (int).
##   - stackable=false + max_stacks=1: reapply keeps stacks=1,
##     refreshes duration.
##   - effective_attack uses StatusDef.attack_modifier + is_percent_modifier
##     with the B1 aggregation rule.
##   - Removes/expiry restores EXACTLY base attack.
##   - Base attack is NOT mutated.
##   - Two entities with separate statuses don't interfere.
##   - Unknown status_id fails safely.
##   - Multi-stack rounding example (odd base) is documented.

const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
const StatusContainerScript = preload("res://core/battle_ecs/status/status_container.gd")
const StatusInstanceScript = preload("res://core/battle_ecs/status/status_instance.gd")
const StatQueryScript = preload("res://core/battle_ecs/status/stat_query.gd")
const StatusDefResolverScript = preload("res://core/battle_ecs/status/status_def_resolver.gd")
const ContentDBScript = preload("res://core/utils/content_db.gd")
const StatusDefScript = preload("res://core/data/status_def.gd")
const BalanceScript = preload("res://core/balance.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	await _test_real_attack_up_definition_loadable()
	await _test_apply_status_resolves_real_attack_up()
	await _test_real_attack_up_increases_effective_attack()
	await _test_real_attack_up_does_not_mutate_base_attack()
	await _test_reapply_real_attack_up_keeps_stacks_one_refreshes_duration()
	await _test_remove_real_attack_up_restores_base_attack()
	await _test_expiry_restores_base_attack_and_preserves_stringname_identity()
	await _test_real_attack_up_two_entities_independent()
	await _test_real_attack_up_aggregation_rounding()
	await _test_real_attack_up_multi_stack_caps_at_max_stacks()
	await _test_apply_unknown_status_id_fails_safely()
	await _test_unknown_status_id_does_not_create_container()
	await _test_real_attack_up_status_instance_no_definition_copy()
	print("\n=== real attack_up integration: %d passed, %d failed ===\n" % [_passed, _failed])
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


# Helper: build a single-entity world with a chosen base attack.
func _make_world_with_base_attack(base_attack: int) -> BattleWorldScript:
	var B = preload("res://core/battle_ecs/battle_unit_setup.gd")
	var S = preload("res://core/battle_ecs/battle_setup.gd")
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), 100, 100,
		base_attack, 5, 5)
	var e = B.new("", &"orc", 1, Vector2i(0, 0), 100, 100, 20, 5, 5)
	var s = S.new(42, [p], [e], 7, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(s)
	return w


func _make_ctx(world: BattleWorldScript) -> Array:
	var rng = DeterministicRngScript.new(0)
	var emitter_script = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
	var emitter = emitter_script.new()
	emitter.reset()
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	return [ctx, sink, rng]


# === Real attack_up.tres loadability ===

func _test_real_attack_up_definition_loadable() -> void:
	print("[au-1] real_attack_up_definition_loadable")
	var def: Resource = StatusDefResolverScript.resolve(&"attack_up")
	_assert(def != null, "StatusDefResolver resolves real attack_up.tres")
	if def != null:
		_assert(def.id == &"attack_up",
			"loaded StatusDef.id == &\"attack_up\" (got %s)" % str(def.id))
		_assert(float(def.duration) == 5.0,
			"real duration == 5.0 (got %s)" % str(def.duration))
		_assert(float(def.attack_modifier) == 0.5,
			"real attack_modifier == 0.5 (got %s)" % str(def.attack_modifier))
		_assert(bool(def.is_percent_modifier) == true,
			"real is_percent_modifier == true")
		_assert(bool(def.stackable) == false,
			"real stackable == false")
		_assert(int(def.max_stacks) == 1,
			"real max_stacks == 1 (got %d)" % int(def.max_stacks))


# === Apply status resolves real attack_up ===

func _test_apply_status_resolves_real_attack_up() -> void:
	print("[au-2] apply_status_resolves_real_attack_up")
	var w = _make_world_with_base_attack(20)
	var ctx = _make_ctx(w)[0]
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"attack_up"
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(result.success, "apply attack_up succeeds (reason='%s')" % result.reason)
	var c = w.get_status_container(0)
	_assert(c != null, "status container created")
	var inst = c.get_status(&"attack_up")
	_assert(inst != null, "attack_up StatusInstance exists")
	_assert(int(inst.stacks) == 1, "stacks == 1 (got %d)" % int(inst.stacks))
	_assert(int(inst.remaining) == 5,
		"remaining == 5 ticks from real StatusDef.duration 5.0 (got %d)" % int(inst.remaining))


# === effective_attack ===

func _test_real_attack_up_increases_effective_attack() -> void:
	print("[au-3] real_attack_up_increases_effective_attack")
	# Real attack_up: attack_modifier=0.5, is_percent_modifier=true
	# base 20 -> 20 * 1.5 = 30
	var w = _make_world_with_base_attack(20)
	var ctx = _make_ctx(w)[0]
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"attack_up"
	EffectExecutorScript.new().execute(ctx, req)
	var sq = StatQueryScript.new(w)
	_assert(sq.effective_attack(0) == 30,
		"effective_attack(20 base +50%%): 20*1.5=30 (got %d)" % sq.effective_attack(0))


func _test_real_attack_up_does_not_mutate_base_attack() -> void:
	print("[au-4] real_attack_up_does_not_mutate_base_attack")
	var w = _make_world_with_base_attack(20)
	var ctx = _make_ctx(w)[0]
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"attack_up"
	EffectExecutorScript.new().execute(ctx, req)
	_assert(int(w.attack_of(0)) == 20,
		"base attack unchanged after apply (got %d)" % int(w.attack_of(0)))


# === Reapply / stacks / duration ===

func _test_reapply_real_attack_up_keeps_stacks_one_refreshes_duration() -> void:
	print("[au-5] reapply_real_attack_up_keeps_stacks_one_refreshes_duration")
	# stackable=false + max_stacks=1: reapply refreshes duration,
	# stacks remain 1.
	var w = _make_world_with_base_attack(20)
	var ctx = _make_ctx(w)[0]
	var exec = EffectExecutorScript.new()
	# First apply with non-default payload? No — we use real
	# StatusDef, so payload stacks=1 by default.
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"attack_up"
	exec.execute(ctx, req)
	# Tick down 3 ticks to consume 3 of 5.
	# Simulate ticks by directly calling container.tick()
	var c = w.get_status_container(0)
	c.tick(3)
	var remaining_after_3 = int(c.get_status(&"attack_up").remaining)
	_assert(remaining_after_3 == 2,
		"after 3 ticks remaining == 2 (got %d)" % remaining_after_3)
	# Reapply — should refresh remaining to 5 (real duration).
	var req2 = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req2.definition_id = &"attack_up"
	exec.execute(ctx, req2)
	var inst = c.get_status(&"attack_up")
	_assert(int(inst.stacks) == 1,
		"stacks remains 1 under non-stackable (got %d)" % int(inst.stacks))
	_assert(int(inst.remaining) == 5,
		"duration refreshed to 5 (got %d)" % int(inst.remaining))


func _test_remove_real_attack_up_restores_base_attack() -> void:
	print("[au-6] remove_real_attack_up_restores_base_attack")
	var w = _make_world_with_base_attack(20)
	var ctx = _make_ctx(w)[0]
	var exec = EffectExecutorScript.new()
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"attack_up"
	exec.execute(ctx, req)
	var rm_req = EffectRequestScript.new(
		EffectKindScript.REMOVE_STATUS, 0, 0, 0, -1, -1, 0)
	rm_req.definition_id = &"attack_up"
	exec.execute(ctx, rm_req)
	var sq = StatQueryScript.new(w)
	_assert(sq.effective_attack(0) == 20,
		"effective_attack restores to base 20 after remove (got %d)" % sq.effective_attack(0))
	_assert(int(w.attack_of(0)) == 20,
		"base attack still 20 (got %d)" % int(w.attack_of(0)))


func _test_expiry_restores_base_attack_and_preserves_stringname_identity() -> void:
	print("[au-7] expiry_restores_base_attack_and_preserves_stringname_identity")
	var w = _make_world_with_base_attack(20)
	var ctx = _make_ctx(w)[0]
	var exec = EffectExecutorScript.new()
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"attack_up"
	exec.execute(ctx, req)
	var c = w.get_status_container(0)
	c.tick(5)  # consume all 5 ticks
	_assert(not c.has_status(&"attack_up"), "status expired")
	var sq = StatQueryScript.new(w)
	_assert(sq.effective_attack(0) == 20,
		"effective_attack restores to base 20 after expiry (got %d)" % sq.effective_attack(0))


# === Multi-entity isolation ===

func _test_real_attack_up_two_entities_independent() -> void:
	print("[au-8] real_attack_up_two_entities_independent")
	var w = _make_world_with_base_attack(20)
	var ctx = _make_ctx(w)[0]
	var exec = EffectExecutorScript.new()
	# Apply to entity 0 only.
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"attack_up"
	exec.execute(ctx, req)
	var sq = StatQueryScript.new(w)
	_assert(sq.effective_attack(0) == 30,
		"entity 0 effective attack +50%% (got %d)" % sq.effective_attack(0))
	_assert(sq.effective_attack(1) == 20,
		"entity 1 unchanged at base 20 (got %d)" % sq.effective_attack(1))
	# Remove from entity 0.
	var rm_req = EffectRequestScript.new(
		EffectKindScript.REMOVE_STATUS, 0, 0, 0, -1, -1, 0)
	rm_req.definition_id = &"attack_up"
	exec.execute(ctx, rm_req)
	_assert(sq.effective_attack(0) == 20,
		"entity 0 base restored to 20")
	_assert(sq.effective_attack(1) == 20,
		"entity 1 still base 20 (no shared state)")


# === Aggregation rounding (deterministic) ===

func _test_real_attack_up_aggregation_rounding() -> void:
	print("[au-9] real_attack_up_aggregation_rounding")
	# Documented rule: round-half-up at the end (after combining
	# all modifiers).
	# base=21, +50% = 21 * 1.5 = 31.5 -> round = 32
	var w = _make_world_with_base_attack(21)
	var ctx = _make_ctx(w)[0]
	var exec = EffectExecutorScript.new()
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"attack_up"
	exec.execute(ctx, req)
	var sq = StatQueryScript.new(w)
	_assert(sq.effective_attack(0) == 32,
		"effective_attack(21 base +50%%): 21*1.5=31.5 round-half-up=32 (got %d)" % sq.effective_attack(0))
	# base=23, +50% = 23*1.5 = 34.5 -> round = 35
	w.remove_entity(0)
	var w2 = _make_world_with_base_attack(23)
	var ctx2 = _make_ctx(w2)[0]
	var req2 = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req2.definition_id = &"attack_up"
	EffectExecutorScript.new().execute(ctx2, req2)
	var sq2 = StatQueryScript.new(w2)
	_assert(sq2.effective_attack(0) == 35,
		"effective_attack(23 base +50%%): 23*1.5=34.5 round-half-up=35 (got %d)" % sq2.effective_attack(0))


# === Multi-stack policy (synthetic stackable test) ===

func _test_real_attack_up_multi_stack_caps_at_max_stacks() -> void:
	print("[au-10] real_attack_up_multi_stack_caps_at_max_stacks [production-path]")
	# Real attack_up is stackable=false max_stacks=1 (from real
	# attack_up.tres). Production ApplyStatusEffect must respect
	# the StatusDef's stackable/max_stacks policy.
	var w = _make_world_with_base_attack(20)
	var ctx = _make_ctx(w)[0]
	var exec = EffectExecutorScript.new()
	# First apply.
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"attack_up"
	exec.execute(ctx, req)
	# Second apply via production ApplyStatusEffect.
	var req2 = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req2.definition_id = &"attack_up"
	exec.execute(ctx, req2)
	var c = w.get_status_container(0)
	_assert(int(c.get_status(&"attack_up").stacks) == 1,
		"production max_stacks=1 caps second apply (got %d)" % int(c.get_status(&"attack_up").stacks))
	# Third apply: still 1.
	var req3 = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req3.definition_id = &"attack_up"
	exec.execute(ctx, req3)
	_assert(int(c.get_status(&"attack_up").stacks) == 1,
		"third apply still capped at 1 (got %d)" % int(c.get_status(&"attack_up").stacks))
	# NOTE: stackable=true production-path coverage is deferred
	# until a stackable real-content StatusDef exists. Container
	# unit tests in status_and_heal_test.gd already cover the
	# StatusContainer-level stackable=true policy.


# === Unknown status safety ===

func _test_apply_unknown_status_id_fails_safely() -> void:
	print("[au-11] apply_unknown_status_id_fails_safely")
	var w = _make_world_with_base_attack(20)
	var ctx = _make_ctx(w)[0]
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"totally_unknown_status_xyz"
	var result = EffectExecutorScript.new().execute(ctx, req)
	_assert(not result.success, "unknown status_id returns failure")
	_assert("unknown" in result.reason,
		"reason mentions unknown (got '%s')" % result.reason)


func _test_unknown_status_id_does_not_create_container() -> void:
	print("[au-12] unknown_status_id_does_not_create_container")
	var w = _make_world_with_base_attack(20)
	var ctx = _make_ctx(w)[0]
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"totally_unknown_status_xyz"
	EffectExecutorScript.new().execute(ctx, req)
	_assert(w.get_status_container(0) == null,
		"no container created for failed apply")


# === StatusInstance shape: no definition copy ===

func _test_real_attack_up_status_instance_no_definition_copy() -> void:
	print("[au-13] real_attack_up_status_instance_no_definition_copy")
	# StatusInstance must NOT copy StatusDef fields. It holds
	# runtime values only (status_id, source_entity, target_entity,
	# stacks, remaining, magnitude, payload).
	# Verify by constructing one and asserting it does NOT have
	# StatusDef fields like "attack_modifier" or "is_percent_modifier"
	# accessible as instance fields.
	var inst = StatusInstanceScript.new(&"attack_up", 0, 0, 1, 5, 0)
	_assert(not inst.has_method("get_attack_modifier"),
		"StatusInstance has no attack_modifier accessor (definition data)")
	_assert(not inst.has_method("get_is_percent_modifier"),
		"StatusInstance has no is_percent_modifier accessor")
	# StatusInstance exposes runtime fields: status_id, stacks,
	# remaining, magnitude.
	_assert(inst.get("attack_modifier") == null,
		"StatusInstance has no attack_modifier field")
	_assert(inst.get("is_percent_modifier") == null,
		"StatusInstance has no is_percent_modifier field")
