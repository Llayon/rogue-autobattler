extends SceneTree
## Phase 3 / B1.1 — focused tests for duration validation,
## stack invariants, strict container owner, StringName identity
## audits, and rounding contract.

const StatusContainerScript = preload("res://core/battle_ecs/status/status_container.gd")
const StatusInstanceScript = preload("res://core/battle_ecs/status/status_instance.gd")
const StatusDefResolverScript = preload("res://core/battle_ecs/status/status_def_resolver.gd")
const ContentDBScript = preload("res://core/utils/content_db.gd")
const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const StatQueryScript = preload("res://core/battle_ecs/status/stat_query.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	# === BLOCKER 1: Duration validation ===
	await _test_duration_5p0_is_timed_5_ticks()
	await _test_duration_1p0_is_timed_1_tick()
	await _test_duration_5p5_is_invalid_fractional()
	await _test_duration_1p25_is_invalid_fractional()
	await _test_duration_0p0_is_instant_not_indefinite()
	await _test_duration_neg1p0_is_invalid_negative()
	await _test_duration_nan_is_invalid()
	await _test_duration_inf_is_invalid()
	await _test_duration_result_is_dictionary_with_required_keys()
	# === HIGH 2: Stack invariant at container boundary ===
	await _test_container_first_insert_clamps_stacks_to_max_stacks()
	await _test_container_first_insert_clamps_stacks_to_one_when_above_one()
	await _test_container_rejects_zero_stacks()
	await _test_container_rejects_negative_stacks()
	await _test_container_reapply_unique_clamps_stacks_to_one()
	await _test_container_reapply_stackable_increments_then_clamps()
	await _test_apply_status_rejects_zero_stacks()
	await _test_apply_status_rejects_negative_stacks()
	await _test_apply_status_unknown_id_does_not_create_container()
	# === HIGH 2 production-path: stacks=999 attack_up ===
	await _test_apply_real_attack_up_with_payload_stacks_999_caps_at_one()
	await _test_apply_real_attack_up_with_payload_stacks_999_effective_attack_is_30()
	# === HIGH 2 production-path: invalid duration cannot mutate ===
	await _test_apply_real_attack_up_succeeds_with_5_ticks_duration()
	# === HIGH 3: StringName identity ===
	await _test_stringname_identity_audit_attack_up_vs_stun()
	await _test_status_container_stringname_distinct_invariant()
	# === MEDIUM 5: Strict container owner ===
	await _test_strict_owner_rejects_owner_minus_one()
	await _test_strict_owner_rejects_owner_other_entity()
	await _test_strict_owner_accepts_matching_owner()
	# === MEDIUM 4: Rounding contract ===
	await _test_rounding_half_away_from_zero_positive()
	# (negative rounding test removed per spec — not redesigning
	# combat stat lower bounds in this repair)
	print("\n=== B1.1 focused tests: %d passed, %d failed ===\n" % [_passed, _failed])
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


# === BLOCKER 1: Duration validation ===

func _test_duration_5p0_is_timed_5_ticks() -> void:
	print("[du-1] duration_5p0_is_timed_5_ticks")
	var res: Dictionary = StatusDefResolverScript.convert_duration(5.0)
	_assert(bool(res.get("ok", false)) == true, "ok=true")
	_assert(int(res.get("kind", -1)) == int(StatusDefResolverScript.KIND_TIMED),
		"kind=KIND_TIMED (got %s)" % str(res.get("kind", "")))
	_assert(int(res.get("ticks", -1)) == 5, "ticks=5 (got %d)" % int(res.get("ticks", -1)))


func _test_duration_1p0_is_timed_1_tick() -> void:
	print("[du-2] duration_1p0_is_timed_1_tick")
	var res: Dictionary = StatusDefResolverScript.convert_duration(1.0)
	_assert(bool(res.get("ok", false)) == true, "ok=true")
	_assert(int(res.get("ticks", -1)) == 1, "ticks=1 (got %d)" % int(res.get("ticks", -1)))


func _test_duration_5p5_is_invalid_fractional() -> void:
	print("[du-3] duration_5p5_is_invalid_fractional")
	var res: Dictionary = StatusDefResolverScript.convert_duration(5.5)
	_assert(bool(res.get("ok", false)) == false, "ok=false")
	_assert(int(res.get("kind", -1)) == int(StatusDefResolverScript.KIND_INVALID),
		"kind=KIND_INVALID (got %s)" % str(res.get("kind", "")))
	_assert(String(res.get("reason", "")).find("fractional") >= 0,
		"reason mentions fractional (got '%s')" % str(res.get("reason", "")))


func _test_duration_1p25_is_invalid_fractional() -> void:
	print("[du-4] duration_1p25_is_invalid_fractional")
	var res: Dictionary = StatusDefResolverScript.convert_duration(1.25)
	_assert(bool(res.get("ok", false)) == false, "ok=false")
	_assert(int(res.get("kind", -1)) == int(StatusDefResolverScript.KIND_INVALID),
		"kind=KIND_INVALID")


func _test_duration_0p0_is_instant_not_indefinite() -> void:
	print("[du-5] duration_0p0_is_instant_not_indefinite")
	# Canonical StatusDef: duration=0 means INSTANT.
	# Phase-3 has no persistent runtime for instant statuses.
	# Result: ok=false, kind=KIND_INSTANT, NOT indefinite.
	var res: Dictionary = StatusDefResolverScript.convert_duration(0.0)
	_assert(bool(res.get("ok", false)) == false, "ok=false")
	_assert(int(res.get("kind", -1)) == int(StatusDefResolverScript.KIND_INSTANT),
		"kind=KIND_INSTANT (got %s)" % str(res.get("kind", "")))
	_assert(int(res.get("kind", -1)) != -1,
		"kind is NOT the indefinite sentinel (got kind=%s)" % str(res.get("kind", "")))
	_assert(String(res.get("reason", "")).find("INSTANT") >= 0 or
		String(res.get("reason", "")).find("instant") >= 0,
		"reason mentions INSTANT (got '%s')" % str(res.get("reason", "")))


func _test_duration_neg1p0_is_invalid_negative() -> void:
	print("[du-6] duration_neg1p0_is_invalid_negative")
	var res: Dictionary = StatusDefResolverScript.convert_duration(-1.0)
	_assert(bool(res.get("ok", false)) == false, "ok=false")
	_assert(int(res.get("kind", -1)) == int(StatusDefResolverScript.KIND_INVALID),
		"kind=KIND_INVALID")
	_assert(String(res.get("reason", "")).find("negative") >= 0,
		"reason mentions negative (got '%s')" % str(res.get("reason", "")))


func _test_duration_nan_is_invalid() -> void:
	print("[du-7] duration_nan_is_invalid")
	var res: Dictionary = StatusDefResolverScript.convert_duration(NAN)
	_assert(bool(res.get("ok", false)) == false, "ok=false")
	_assert(int(res.get("kind", -1)) == int(StatusDefResolverScript.KIND_INVALID),
		"kind=KIND_INVALID (NaN)")


func _test_duration_inf_is_invalid() -> void:
	print("[du-8] duration_inf_is_invalid")
	var res_pos: Dictionary = StatusDefResolverScript.convert_duration(INF)
	_assert(bool(res_pos.get("ok", false)) == false, "ok=false (+INF)")
	var res_neg: Dictionary = StatusDefResolverScript.convert_duration(-INF)
	_assert(bool(res_neg.get("ok", false)) == false, "ok=false (-INF)")


func _test_duration_result_is_dictionary_with_required_keys() -> void:
	print("[du-9] duration_result_is_dictionary_with_required_keys")
	var res: Dictionary = StatusDefResolverScript.convert_duration(5.0)
	_assert(res.has("ok"), "result has 'ok' key")
	_assert(res.has("kind"), "result has 'kind' key")
	_assert(res.has("ticks"), "result has 'ticks' key")
	_assert(res.has("reason"), "result has 'reason' key")


# === HIGH 2: Stack invariant at container boundary ===

func _test_container_first_insert_clamps_stacks_to_max_stacks() -> void:
	print("[st-1] container_first_insert_clamps_stacks_to_max_stacks")
	# max_stacks=3 + requested stacks=999 + policy="stackable" ->
	# stored stacks == 3.
	var c = StatusContainerScript.new(0)
	c.add(StatusInstanceScript.new(&"burn", 0, 0, 999, 5, 0), "stackable", 3)
	_assert(int(c.get_status(&"burn").stacks) == 3,
		"first insert clamped to max_stacks=3 (got %d)" % int(c.get_status(&"burn").stacks))


func _test_container_first_insert_clamps_stacks_to_one_when_above_one() -> void:
	print("[st-2] container_first_insert_clamps_stacks_to_one_when_above_one")
	# max_stacks=1 + requested stacks=999 + policy="unique" ->
	# stored stacks == 1.
	var c = StatusContainerScript.new(0)
	c.add(StatusInstanceScript.new(&"burn", 0, 0, 999, 5, 0), "unique", 1)
	_assert(int(c.get_status(&"burn").stacks) == 1,
		"unique policy with max_stacks=1 caps at 1 (got %d)" % int(c.get_status(&"burn").stacks))


func _test_container_rejects_zero_stacks() -> void:
	print("[st-3] container_rejects_zero_stacks")
	var c = StatusContainerScript.new(0)
	var accepted = c.add(StatusInstanceScript.new(&"burn", 0, 0, 0, 5, 0), "stackable", 3)
	_assert(accepted == null, "stacks=0 rejected (got %s)" % str(accepted))
	_assert(c.size() == 0, "container size=0 after rejection")


func _test_container_rejects_negative_stacks() -> void:
	print("[st-4] container_rejects_negative_stacks")
	var c = StatusContainerScript.new(0)
	var accepted = c.add(StatusInstanceScript.new(&"burn", 0, 0, -5, 5, 0), "stackable", 3)
	_assert(accepted == null, "stacks=-5 rejected (got %s)" % str(accepted))
	_assert(c.size() == 0, "container size=0 after rejection")


func _test_container_reapply_unique_clamps_stacks_to_one() -> void:
	print("[st-5] container_reapply_unique_clamps_stacks_to_one")
	# Existing stacks=1, reapply with stacks=99 + unique policy
	# -> stacks still 1.
	var c = StatusContainerScript.new(0)
	c.add(StatusInstanceScript.new(&"burn", 0, 0, 1, 5, 0), "unique", 1)
	c.add(StatusInstanceScript.new(&"burn", 0, 0, 99, 5, 0), "unique", 1)
	_assert(int(c.get_status(&"burn").stacks) == 1,
		"unique reapply clamps to 1 (got %d)" % int(c.get_status(&"burn").stacks))


func _test_container_reapply_stackable_increments_then_clamps() -> void:
	print("[st-6] container_reapply_stackable_increments_then_clamps")
	# Existing stacks=2, reapply stacks=2, max_stacks=3 -> still 3.
	var c = StatusContainerScript.new(0)
	c.add(StatusInstanceScript.new(&"burn", 0, 0, 2, 5, 0), "stackable", 3)
	c.add(StatusInstanceScript.new(&"burn", 0, 0, 2, 5, 0), "stackable", 3)
	_assert(int(c.get_status(&"burn").stacks) == 3,
		"stackable reapply caps at 3 (got %d)" % int(c.get_status(&"burn").stacks))


# === HIGH 2: ApplyStatusEffect stacks <= 0 rejection ===

func _make_world_and_ctx() -> Array:
	var B = preload("res://core/battle_ecs/battle_unit_setup.gd")
	var S = preload("res://core/battle_ecs/battle_setup.gd")
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), 80, 80, 20, 5, 5)
	var e = B.new("", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var s = S.new(42, [p], [e], 7, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	var emitter = BattleEventEmitterScript.new()
	emitter.reset()
	var sink: Array = []
	var ctx = EffectContextScript.new(w, rng, emitter, sink)
	return [w, ctx, sink]


func _apply_attack_up_with_payload(world, ctx, stacks_in_payload: int) -> Array:
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"attack_up"
	req.payload["stacks"] = stacks_in_payload
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	return [result, world]


func _test_apply_status_rejects_zero_stacks() -> void:
	print("[st-7] apply_status_rejects_zero_stacks")
	ContentDBScript.load_all()
	var arr: Array = _make_world_and_ctx()
	var world: BattleWorldScript = arr[0]
	var ctx = arr[1]
	var result = _apply_attack_up_with_payload(world, ctx, 0)[0]
	_assert(not result.success, "stacks=0 -> failure")
	_assert(world.get_status_container(0) == null,
		"no container created for stacks=0")


func _test_apply_status_rejects_negative_stacks() -> void:
	print("[st-8] apply_status_rejects_negative_stacks")
	ContentDBScript.load_all()
	var arr: Array = _make_world_and_ctx()
	var world: BattleWorldScript = arr[0]
	var ctx = arr[1]
	var result = _apply_attack_up_with_payload(world, ctx, -5)[0]
	_assert(not result.success, "stacks=-5 -> failure")
	_assert(world.get_status_container(0) == null,
		"no container created for stacks=-5")


func _test_apply_status_unknown_id_does_not_create_container() -> void:
	print("[st-9] apply_status_unknown_id_does_not_create_container")
	var arr: Array = _make_world_and_ctx()
	var world: BattleWorldScript = arr[0]
	var ctx = arr[1]
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"not_a_real_status_zzz"
	EffectExecutorScript.new().execute(ctx, req)
	_assert(world.get_status_container(0) == null,
		"unknown status_id: no container created")


# === HIGH 2 production-path: real attack_up + payload stacks=999 ===

func _test_apply_real_attack_up_with_payload_stacks_999_caps_at_one() -> void:
	print("[prod-1] apply_real_attack_up_with_payload_stacks_999_caps_at_one")
	ContentDBScript.load_all()
	var arr: Array = _make_world_and_ctx()
	var ctx = arr[1]
	var w = arr[0]
	var pair = _apply_attack_up_with_payload(w, ctx, 999)
	var result = pair[0]
	_assert(result.success, "apply succeeds (reason='%s')" % result.reason)
	var c = w.get_status_container(0)
	_assert(c != null, "container created")
	_assert(int(c.get_status(&"attack_up").stacks) == 1,
		"production max_stacks=1 caps payload stacks=999 to 1 (got %d)" % int(c.get_status(&"attack_up").stacks))


func _test_apply_real_attack_up_with_payload_stacks_999_effective_attack_is_30() -> void:
	print("[prod-2] attack_up_999_effective_attack_is_30")
	ContentDBScript.load_all()
	var arr: Array = _make_world_and_ctx()
	var ctx = arr[1]
	var w = arr[0]
	_apply_attack_up_with_payload(w, ctx, 999)
	var sq = StatQueryScript.new(w)
	_assert(sq.effective_attack(0) == 30,
		"effective_attack(20 base +50%% with stacks=1) == 30 (got %d)" % sq.effective_attack(0))
	_assert(w.attack_of(0) == 20,
		"base attack unchanged (got %d)" % w.attack_of(0))


func _test_apply_real_attack_up_succeeds_with_5_ticks_duration() -> void:
	print("[prod-3] attack_up_duration_5_ticks_in_resolved_status")
	ContentDBScript.load_all()
	var arr: Array = _make_world_and_ctx()
	var ctx = arr[1]
	var w = arr[0]
	_apply_attack_up_with_payload(w, ctx, 1)
	var c = w.get_status_container(0)
	var inst = c.get_status(&"attack_up")
	_assert(int(inst.remaining) == 5,
		"remaining=5 from real StatusDef.duration 5.0 (got %d)" % int(inst.remaining))


# === HIGH 3: StringName identity audit ===

func _test_stringname_identity_audit_attack_up_vs_stun() -> void:
	print("[id-1] stringname_identity_audit_attack_up_vs_stun")
	# Direct StringName equality is the only correct identity check.
	var a: StringName = &"attack_up"
	var b: StringName = &"stun"
	_assert(a != b, "attack_up != stun")
	_assert(a == &"attack_up", "attack_up == attack_up")
	# Confirm int(StringName) collapses (documented engine quirk).
	_assert(int(a) == int(b),
		"int(StringName) collapses to 0 for both (proves int-cast is invalid for identity)")


func _test_status_container_stringname_distinct_invariant() -> void:
	print("[id-2] status_container_stringname_distinct_invariant")
	# tick() must preserve StringName identity. Two distinct
	# statuses must remain distinct after expiry.
	var c = StatusContainerScript.new(0)
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 1, 5))
	c.add(StatusInstanceScript.new(&"stun", 0, 0, 1, 1, 0))
	var expired: Array = c.tick(1)
	_assert(expired.size() == 2, "both expired")
	_assert(expired[0].status_id != expired[1].status_id,
		"status_id distinct via direct StringName comparison")
	_assert(expired[0].status_id == &"attack_up",
		"first expired == attack_up")
	_assert(expired[1].status_id == &"stun",
		"second expired == stun")


# === MEDIUM 5: Strict container owner ===

func _test_strict_owner_rejects_owner_minus_one() -> void:
	print("[own-1] strict_owner_rejects_owner_minus_one")
	var arr: Array = _make_world_and_ctx()
	var w: BattleWorldScript = arr[0]
	# Construct a container with owner_entity_id == -1 (unset).
	var c = StatusContainerScript.new(-1)
	var accepted: bool = w.set_status_container(0, c)
	_assert(not accepted, "owner=-1 rejected (got true)")
	_assert(w.get_status_container(0) == null,
		"world has no container for entity 0 after rejection")


func _test_strict_owner_rejects_owner_other_entity() -> void:
	print("[own-2] strict_owner_rejects_owner_other_entity")
	var arr: Array = _make_world_and_ctx()
	var w: BattleWorldScript = arr[0]
	# Container claims owner=1 but we attach to entity 0.
	var c = StatusContainerScript.new(1)
	var accepted: bool = w.set_status_container(0, c)
	_assert(not accepted, "owner=1 vs entity=0 rejected (got true)")
	_assert(w.get_status_container(0) == null,
		"world has no container after rejection")


func _test_strict_owner_accepts_matching_owner() -> void:
	print("[own-3] strict_owner_accepts_matching_owner")
	var arr: Array = _make_world_and_ctx()
	var w: BattleWorldScript = arr[0]
	var c = StatusContainerScript.new(0)
	var accepted: bool = w.set_status_container(0, c)
	_assert(accepted, "matching owner accepted")
	_assert(w.get_status_container(0) != null,
		"world has container after acceptance")


# === MEDIUM 4: Rounding contract ===

func _test_rounding_half_away_from_zero_positive() -> void:
	print("[rd-1] rounding_half_away_from_zero_positive")
	# Direct test of the rounding semantics documented in
	# stat_query.gd. We use the public effective_attack() entry
	# point: base=21 +50% -> 21*1.5 = 31.5 -> 32.
	ContentDBScript.load_all()
	var arr: Array = _make_world_and_ctx()
	var ctx = arr[1]
	var w = arr[0]
	# Apply attack_up via production path.
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"attack_up"
	EffectExecutorScript.new().execute(ctx, req)
	# Verify effective_attack for base=20 -> 30.
	var sq = StatQueryScript.new(w)
	_assert(sq.effective_attack(0) == 30,
		"base 20 +50%% -> 30 (got %d)" % sq.effective_attack(0))
	# Now test base=21 by recreating with a different base attack.
	# Use a fresh world with base=21 entity 0.
	var B = preload("res://core/battle_ecs/battle_unit_setup.gd")
	var S = preload("res://core/battle_ecs/battle_setup.gd")
	var p2 = B.new("p", &"warrior", 0, Vector2i(0, 1), 80, 80, 21, 5, 5)
	var e2 = B.new("", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var s2 = S.new(42, [p2], [e2], 7, 4)
	var w2 = BattleWorldScript.new(7, 4)
	w2.spawn_from_setup(s2)
	var rng2 = DeterministicRngScript.new(0)
	var emitter2 = BattleEventEmitterScript.new()
	emitter2.reset()
	var sink2: Array = []
	var ctx2 = EffectContextScript.new(w2, rng2, emitter2, sink2)
	var req2 = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req2.definition_id = &"attack_up"
	EffectExecutorScript.new().execute(ctx2, req2)
	var sq2 = StatQueryScript.new(w2)
	_assert(sq2.effective_attack(0) == 32,
		"base 21 +50%% rounds to 32 half-away-from-zero (got %d)" % sq2.effective_attack(0))
	# base=23 -> 23*1.5 = 34.5 -> 35
	var p3 = B.new("p", &"warrior", 0, Vector2i(0, 1), 80, 80, 23, 5, 5)
	var s3 = S.new(42, [p3], [e2], 7, 4)
	var w3 = BattleWorldScript.new(7, 4)
	w3.spawn_from_setup(s3)
	var rng3 = DeterministicRngScript.new(0)
	var emitter3 = BattleEventEmitterScript.new()
	emitter3.reset()
	var ctx3 = EffectContextScript.new(w3, rng3, emitter3, Array())
	var req3 = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req3.definition_id = &"attack_up"
	EffectExecutorScript.new().execute(ctx3, req3)
	var sq3 = StatQueryScript.new(w3)
	_assert(sq3.effective_attack(0) == 35,
		"base 23 +50%% -> 35 (round-half-away-from-zero, got %d)" % sq3.effective_attack(0))
