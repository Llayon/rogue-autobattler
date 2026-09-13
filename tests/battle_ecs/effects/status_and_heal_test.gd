extends SceneTree
## Phase 3 / Gauntlets 3-6 — Heal effect, StatusInstance /
## StatusContainer, ApplyStatus / RemoveStatus effects, and
## stat query / modifier layer.
##
## B0.1/B1 update: all status APIs now require an explicit owner
## entity. StatusContainer.new(owner_entity_id). Methods are
## owner-scoped (no more entity_id parameter on each call).
## StatusDefResolver is the canonical content lookup path.

const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
const StatusInstanceScript = preload("res://core/battle_ecs/status/status_instance.gd")
const StatusContainerScript = preload("res://core/battle_ecs/status/status_container.gd")
const StatQueryScript = preload("res://core/battle_ecs/status/stat_query.gd")
const HealEffectScript = preload("res://core/battle_ecs/effects/heal_effect.gd")
const ApplyStatusEffectScript = preload("res://core/battle_ecs/effects/apply_status_effect.gd")
const RemoveStatusEffectScript = preload("res://core/battle_ecs/effects/remove_status_effect.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const ContentDBScript = preload("res://core/utils/content_db.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	# StatusContainer (B0.1 owner-scoped API)
	await _test_status_instance_basic_construction()
	await _test_status_container_add_one()
	await _test_status_container_remove_existing()
	await _test_status_container_remove_missing_no_op()
	await _test_status_container_duplicate_apply_unique_policy()
	await _test_status_container_duplicate_apply_stackable_increments()
	await _test_container_owner_scoped_rejects_other_entity()
	await _test_status_container_iteration_order_deterministic()
	await _test_status_container_cleanup_on_remove_entity()
	await _test_status_container_no_shared_status_between_entities()
	await _test_container_stringname_identity_preserved_through_expiry()
	# StatQuery
	await _test_stat_query_returns_base_when_no_statuses()
	await _test_stat_query_sums_attack_modifier_from_statusdef()
	await _test_stat_query_does_not_mutate_base_stat()
	# Heal effect
	await _test_heal_partial()
	await _test_heal_overheal_caps_at_max()
	await _test_heal_full_health_no_change()
	await _test_heal_dead_target_returns_failure_no_resurrection()
	await _test_heal_invalid_target_returns_failure()
	await _test_heal_emits_heal_event_with_actual_amount()
	# ApplyStatus / RemoveStatus effects
	await _test_apply_status_to_live_target_emits_event()
	await _test_apply_status_to_dead_target_returns_failure()
	await _test_apply_status_unknown_id_returns_failure()
	await _test_remove_status_existing_emits_event()
	await _test_remove_status_missing_returns_failure_no_event()
	print("\n=== status heal apply-remove stat-query: %d passed, %d failed ===\n" % [_passed, _failed])
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


func _make_world() -> BattleWorldScript:
	var B = preload("res://core/battle_ecs/battle_unit_setup.gd")
	var S = preload("res://core/battle_ecs/battle_setup.gd")
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), 80, 80, 20, 5, 5)
	var e = B.new("", &"orc", 1, Vector2i(0, 0), 80, 80, 20, 5, 5)
	var s = S.new(42, [p], [e], 7, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(s)
	return w


func _make_ctx() -> Array:
	var world: BattleWorldScript = _make_world()
	var rng = DeterministicRngScript.new(0)
	var emitter = BattleEventEmitterScript.new()
	emitter.reset()
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	return [ctx, sink, rng, emitter]


# === StatusInstance ===

func _test_status_instance_basic_construction() -> void:
	print("[sc-1] status_instance_basic_construction")
	var st = StatusInstanceScript.new(&"attack_up", 0, 1, 2, 9999, 5)
	_assert(st.status_id == &"attack_up", "status_id stored")
	_assert(int(st.source_entity) == 0, "source_entity stored")
	_assert(int(st.target_entity) == 1, "target_entity stored")
	_assert(int(st.stacks) == 2, "stacks stored")
	_assert(int(st.duration) == 9999, "duration stored (9999 = indefinite)")
	_assert(int(st.magnitude) == 5, "magnitude stored")


# === StatusContainer (B0.1 owner-scoped) ===

func _test_status_container_add_one() -> void:
	print("[sc-2] status_container_add_one")
	var c = StatusContainerScript.new(0)
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5))
	_assert(c.has_status(&"attack_up"), "has_status after add")
	_assert(c.size() == 1, "size == 1 after add")


func _test_status_container_remove_existing() -> void:
	print("[sc-3] status_container_remove_existing")
	var c = StatusContainerScript.new(0)
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5))
	_assert(c.remove(&"attack_up"), "remove returns true")
	_assert(not c.has_status(&"attack_up"), "no longer has status")
	_assert(c.size() == 0, "size == 0 after remove")


func _test_status_container_remove_missing_no_op() -> void:
	print("[sc-4] status_container_remove_missing_no_op")
	var c = StatusContainerScript.new(0)
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5))
	_assert(not c.remove(&"shield"), "remove non-existent returns false")
	_assert(c.size() == 1, "size still 1")


func _test_status_container_duplicate_apply_unique_policy() -> void:
	print("[sc-5a] status_container_duplicate_apply_unique_policy")
	# B1: when stacking_policy="unique", reapply refreshes duration
	# but stacks remain at 1.
	var c = StatusContainerScript.new(0)
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 5, 5), "unique")
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 10, 5), "unique")
	_assert(c.size() == 1, "single instance (unique policy)")
	_assert(c.get_status(&"attack_up").stacks == 1,
		"stacks remain 1 under unique policy (got %d)" % c.get_status(&"attack_up").stacks)
	_assert(c.get_status(&"attack_up").remaining == 10,
		"duration refreshed to 10 (got %d)" % c.get_status(&"attack_up").remaining)


func _test_status_container_duplicate_apply_stackable_increments() -> void:
	print("[sc-5b] status_container_duplicate_apply_stackable_increments")
	var c = StatusContainerScript.new(0)
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 5, 5), "stackable", 99)
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 5, 5), "stackable", 99)
	_assert(c.size() == 1, "single instance per def_id")
	_assert(c.get_status(&"attack_up").stacks == 2,
		"stacks incremented to 2 (got %d)" % c.get_status(&"attack_up").stacks)


func _test_container_owner_scoped_rejects_other_entity() -> void:
	print("[sc-6] container_owner_scoped_rejects_other_entity")
	# B0.1: container belongs to entity 0. Adding a status with
	# target_entity=1 must be REJECTED.
	var c = StatusContainerScript.new(0)
	var accepted = c.add(StatusInstanceScript.new(&"attack_up", 0, 1, 1, 5, 5))
	_assert(accepted == null, "cross-entity add rejected (got %s)" % str(accepted))
	_assert(c.size() == 0, "container remains empty after rejection")


func _test_status_container_iteration_order_deterministic() -> void:
	print("[sc-7] status_container_iteration_order_deterministic")
	var c = StatusContainerScript.new(0)
	c.add(StatusInstanceScript.new(&"first", 0, 0, 1, 9999, 1))
	c.add(StatusInstanceScript.new(&"second", 0, 0, 1, 9999, 2))
	c.add(StatusInstanceScript.new(&"third", 0, 0, 1, 9999, 3))
	var ids: Array = c.status_ids()
	_assert(ids.size() == 3, "3 statuses")
	_assert(ids[0] == &"first", "first by insertion")
	_assert(ids[1] == &"second", "second by insertion")
	_assert(ids[2] == &"third", "third by insertion")


func _test_status_container_cleanup_on_remove_entity() -> void:
	print("[sc-8] status_container_cleanup_on_remove_entity")
	# A1+B0.1: both statuses belong to entity 0 (the entity being
	# removed). Entity 1 must remain untouched.
	var w = _make_world()
	var c = StatusContainerScript.new(0)
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5))
	c.add(StatusInstanceScript.new(&"shield", 0, 0, 1, 9999, 10))
	var ok: bool = w.set_status_container(0, c)
	_assert(ok, "set_status_container accepted owner=0 container on entity 0")
	_assert(c.size() == 2, "container has 2 statuses on entity 0")
	# Add a separate container for entity 1.
	var c1 = StatusContainerScript.new(1)
	c1.add(StatusInstanceScript.new(&"shield", 0, 1, 1, 9999, 10))
	var ok1: bool = w.set_status_container(1, c1)
	_assert(ok1, "set_status_container accepted owner=1 container on entity 1")
	w.remove_entity(0)
	_assert(w.get_status_container(0) == null,
		"status container cleared on entity 0 removal (world ownership)")
	_assert(w.get_status_container(1) != null,
		"entity 1's container unaffected by entity 0 removal")
	_assert(w.get_status_container(1).size() == 1,
		"entity 1's container still has 1 status")
	# External RefCounted reference held by the test (c) is NOT
	# required to self-clear; the contract is about world ownership.
	_assert(c.size() == 2,
		"external RefCounted still has its 2 statuses (world ownership != destruction)")


func _test_status_container_no_shared_status_between_entities() -> void:
	print("[sc-9] status_container_no_shared_status_between_entities")
	var w = _make_world()
	var ca = StatusContainerScript.new(0)
	var cb = StatusContainerScript.new(1)
	var inst_a = StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5)
	ca.add(inst_a)
	w.set_status_container(0, ca)
	w.set_status_container(1, cb)
	_assert(ca.has_status(&"attack_up"), "A has attack_up")
	_assert(not cb.has_status(&"attack_up"), "B does NOT have attack_up")
	# Mutate A's instance and verify B unaffected.
	inst_a.stacks = 99
	_assert(ca.get_status(&"attack_up").stacks == 99, "A's stacks mutated")
	_assert(cb.size() == 0, "B unchanged")


# === B0.1 — StringName identity preserved through expiry ===

func _test_container_stringname_identity_preserved_through_expiry() -> void:
	print("[id-1] container_stringname_identity_preserved_through_expiry [B0.1]")
	# Regression test: int(StringName) is broken in Godot 4.7.
	# tick() must return StatusInstances whose status_id remains
	# a StringName and remains distinct.
	var c = StatusContainerScript.new(0)
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 1, 5))
	c.add(StatusInstanceScript.new(&"stun", 0, 0, 1, 1, 0))
	var expired: Array = c.tick(1)
	_assert(expired.size() == 2, "both expired (got %d)" % expired.size())
	_assert(expired[0].status_id == &"attack_up",
		"first expired status_id == attack_up (got %s)" % str(expired[0].status_id))
	_assert(expired[1].status_id == &"stun",
		"second expired status_id == stun (got %s)" % str(expired[1].status_id))
	_assert(expired[0].status_id != expired[1].status_id,
		"status_id distinct (no int-casting corruption, got %s vs %s)" % [str(expired[0].status_id), str(expired[1].status_id)])
	# clear() must also preserve StringName.
	c.add(StatusInstanceScript.new(&"burn", 0, 0, 1, 5, 5))
	var removed: Array = c.clear()
	_assert(removed.size() == 1, "clear returns removed instances (got %d)" % removed.size())
	_assert(removed[0].status_id == &"burn",
		"cleared status_id == burn (got %s)" % str(removed[0].status_id))


# === StatQuery ===

func _test_stat_query_returns_base_when_no_statuses() -> void:
	print("[sq-1] stat_query_returns_base_when_no_statuses")
	var w = _make_world()
	var sq = StatQueryScript.new(w)
	_assert(sq.effective_attack(0) == 20,
		"effective_attack == 20 (got %d)" % sq.effective_attack(0))


func _test_stat_query_sums_attack_modifier_from_statusdef() -> void:
	print("[sq-2] stat_query_sums_attack_modifier_from_statusdef")
	# Real attack_up.tres: attack_modifier=0.5, is_percent_modifier=true
	# So effective_attack = round(20 * (1 + 0.5 * stacks)) + 0
	# stacks=1 -> 20 * 1.5 = 30.0 -> 30
	ContentDBScript.ensure_loaded()
	var w = _make_world()
	var sq = StatQueryScript.new(w)
	var c = StatusContainerScript.new(0)
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 5, 0), "unique", 1)
	w.set_status_container(0, c)
	_assert(sq.effective_attack(0) == 30,
		"effective_attack == 20 * 1.5 = 30 (got %d)" % sq.effective_attack(0))


func _test_stat_query_does_not_mutate_base_stat() -> void:
	print("[sq-3] stat_query_does_not_mutate_base_stat")
	ContentDBScript.ensure_loaded()
	var w = _make_world()
	var sq = StatQueryScript.new(w)
	var c = StatusContainerScript.new(0)
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 5, 0), "unique", 1)
	w.set_status_container(0, c)
	var base_before: int = w.attack_of(0)
	sq.effective_attack(0)
	var base_after: int = w.attack_of(0)
	_assert(base_after == base_before,
		"base attack stat unchanged (got %d expected %d)" % [base_after, base_before])


# === Heal effect ===

func _test_heal_partial() -> void:
	print("[hl-1] heal_partial")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	world.apply_damage(0, 30)
	_assert(world.current_hp_of(0) == 50, "HP reduced to 50")
	var req = EffectRequestScript.new(
		EffectKindScript.HEAL, 0, 0, 20, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(result.success, "heal succeeds")
	_assert(world.current_hp_of(0) == 70, "HP restored to 70 (got %d)" % world.current_hp_of(0))
	var saw_heal: bool = false
	for e in pair[1]:
		if int(e.type) == BattleEventTypeScript.HEAL_APPLIED:
			saw_heal = true
			break
	_assert(saw_heal, "HEAL_APPLIED BattleEvent emitted")


func _test_heal_overheal_caps_at_max() -> void:
	print("[hl-2] heal_overheal_caps_at_max")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	world.apply_damage(0, 70)
	var req = EffectRequestScript.new(
		EffectKindScript.HEAL, 0, 0, 1000, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, req)
	_assert(world.current_hp_of(0) == 80, "HP capped at max (got %d)" % world.current_hp_of(0))


func _test_heal_full_health_no_change() -> void:
	print("[hl-3] heal_full_health_no_change")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	var req = EffectRequestScript.new(
		EffectKindScript.HEAL, 0, 0, 20, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(result.success, "heal succeeds (no-op)")
	_assert(world.current_hp_of(0) == 80, "HP still 80")


func _test_heal_dead_target_returns_failure_no_resurrection() -> void:
	print("[hl-4] heal_dead_target_returns_failure_no_resurrection")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	world.apply_damage(0, 1000)
	var req = EffectRequestScript.new(
		EffectKindScript.HEAL, 0, 0, 100, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(not result.success, "heal on dead returns failure")
	_assert(world.current_hp_of(0) == 0, "dead target stays at 0 (no resurrection)")


func _test_heal_invalid_target_returns_failure() -> void:
	print("[hl-5] heal_invalid_target_returns_failure")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var req = EffectRequestScript.new(
		EffectKindScript.HEAL, 0, 999, 50, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(not result.success, "invalid target returns failure")


func _test_heal_emits_heal_event_with_actual_amount() -> void:
	print("[hl-6] heal_emits_heal_event_with_actual_amount")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	var sink: Array = pair[1]
	world.apply_damage(0, 50)
	var req = EffectRequestScript.new(
		EffectKindScript.HEAL, 0, 0, 100, -1, -1, 0)
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, req)
	var saw_heal: bool = false
	var saw_event_id: bool = false
	var saw_amount_match: bool = false
	for e in sink:
		if int(e.type) == BattleEventTypeScript.HEAL_APPLIED:
			saw_heal = true
			if int(e.event_id) >= 1:
				saw_event_id = true
			if int(e.amount) == 50:
				saw_amount_match = true
			break
	_assert(saw_heal, "HEAL_APPLIED BattleEvent emitted")
	_assert(saw_event_id, "HEAL_APPLIED event_id > 0")
	_assert(saw_amount_match, "HEAL_APPLIED amount = actual HP restored (50)")


# === ApplyStatus / RemoveStatus ===

func _test_apply_status_to_live_target_emits_event() -> void:
	print("[as-1] apply_status_to_live_target_emits_event")
	ContentDBScript.ensure_loaded()
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	var sink: Array = pair[1]
	# Real attack_up.tres must exist in content.
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0, -1, -1, 0)
	req.definition_id = &"attack_up"
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(result.success, "apply_status succeeds (got reason='%s')" % result.reason)
	var c = world.get_status_container(1)
	_assert(c != null, "status container created for target")
	_assert(c.has_status(&"attack_up"), "target has attack_up status")
	var saw_applied: bool = false
	for e in sink:
		if int(e.type) == BattleEventTypeScript.STATUS_APPLIED:
			saw_applied = true
			break
	_assert(saw_applied, "STATUS_APPLIED BattleEvent emitted")


func _test_apply_status_to_dead_target_returns_failure() -> void:
	print("[as-2] apply_status_to_dead_target_returns_failure")
	ContentDBScript.ensure_loaded()
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	world.apply_damage(0, 1000)  # kill player
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 1, 0, 0, -1, -1, 0)
	req.definition_id = &"attack_up"
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(not result.success, "apply to dead returns failure")
	var c = world.get_status_container(0)
	_assert(c == null or not c.has_status(&"attack_up"),
		"dead target has no attack_up")


func _test_apply_status_unknown_id_returns_failure() -> void:
	print("[as-2b] apply_status_unknown_id_returns_failure")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0, -1, -1, 0)
	req.definition_id = &"not_a_real_status_xyz"
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(not result.success, "unknown status_id returns failure")
	_assert("unknown" in result.reason, "failure reason mentions unknown (got '%s')" % result.reason)
	var c = world.get_status_container(1)
	_assert(c == null, "no container created for failed apply")


func _test_remove_status_existing_emits_event() -> void:
	print("[as-4] remove_status_existing_emits_event")
	ContentDBScript.ensure_loaded()
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	var sink: Array = pair[1]
	# Apply first.
	var apply_req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0, -1, -1, 0)
	apply_req.definition_id = &"attack_up"
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, apply_req)
	var sink_size_before: int = sink.size()
	# Remove.
	var rm_req = EffectRequestScript.new(
		EffectKindScript.REMOVE_STATUS, 0, 1, 0, -1, -1, 0)
	rm_req.definition_id = &"attack_up"
	var result = exec.execute(ctx, rm_req)
	_assert(result.success, "remove succeeds")
	var c = world.get_status_container(1)
	_assert(not c.has_status(&"attack_up"), "status removed")
	var saw_removed: bool = false
	for e in sink.slice(sink_size_before):
		if int(e.type) == BattleEventTypeScript.STATUS_REMOVED:
			saw_removed = true
			break
	_assert(saw_removed, "STATUS_REMOVED BattleEvent emitted")


func _test_remove_status_missing_returns_failure_no_event() -> void:
	print("[as-5] remove_status_missing_returns_failure_no_event")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var sink: Array = pair[1]
	var sink_size_before: int = sink.size()
	var rm_req = EffectRequestScript.new(
		EffectKindScript.REMOVE_STATUS, 0, 1, 0, -1, -1, 0)
	rm_req.definition_id = &"attack_up"
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, rm_req)
	_assert(not result.success, "remove missing returns failure")
	_assert(sink.size() == sink_size_before, "no event emitted for missing")
