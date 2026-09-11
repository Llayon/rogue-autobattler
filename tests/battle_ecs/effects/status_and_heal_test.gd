extends SceneTree
## Phase 3 / Gauntlets 3-6 — Heal effect, StatusInstance /
## StatusContainer, ApplyStatus / RemoveStatus effects, and
## stat query / modifier layer.
##
## Architectural rules:
##   - One StatusContainer per battle entity (in BattleWorld).
##   - StatusInstance = data carrier (def_id, source, stacks,
##     duration, optional magnitude, creation metadata).
##   - Status definitions live in content/status/*.tres; this
##     test only exercises runtime data semantics.
##   - Stat query layer computes effective stat = base + status
##     modifiers. Does NOT mutate stored base stats.
##   - Heal effect does NOT resurrect dead units.
##   - ApplyStatus / RemoveStatus mutate StatusContainer and
##     emit STATUS_APPLIED / STATUS_REMOVED events.

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

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	# StatusInstance + Container
	await _test_status_instance_basic_construction()
	await _test_status_container_add_one()
	await _test_status_container_remove_existing()
	await _test_status_container_remove_missing_no_op()
	await _test_status_container_duplicate_apply_increments_stack()
	await _test_status_container_independent_entities()
	await _test_status_container_iteration_order_deterministic()
	await _test_status_container_cleanup_on_remove_entity()
	await _test_status_container_no_shared_status_between_entities()
	# Stat query
	await _test_stat_query_returns_base_when_no_statuses()
	await _test_stat_query_sums_attack_up_modifier()
	await _test_stat_query_removal_restores_base()
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
	await _test_apply_status_duplicate_stacks_or_refreshes()
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
	# Returns [EffectContext, sink_array, rng, emitter].
	# The emitter is the central event allocator (A3 fix).
	var world: BattleWorldScript = _make_world()
	var rng = DeterministicRngScript.new(0)
	var emitter = BattleEventEmitterScript.new()
	emitter.reset()
	var sink: Array = []
	var ctx = EffectContextScript.new(world, rng, emitter, sink)
	return [ctx, sink, rng, emitter]


# === StatusInstance + StatusContainer ===

func _test_status_instance_basic_construction() -> void:
	print("[sc-1] status_instance_basic_construction")
	var st = StatusInstanceScript.new(&"attack_up", 0, 1, 2, 9999, 5)
	_assert(int(st.status_id) == int(&"attack_up"), "status_id stored")
	_assert(int(st.source_entity) == 0, "source_entity stored")
	_assert(int(st.target_entity) == 1, "target_entity stored")
	_assert(int(st.stacks) == 2, "stacks stored")
	_assert(int(st.duration) == 9999, "duration stored (9999 = indefinite)")
	_assert(int(st.magnitude) == 5, "magnitude stored")


func _test_status_container_add_one() -> void:
	print("[sc-2] status_container_add_one")
	var w = _make_world()
	var c = StatusContainerScript.new()
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5))
	_assert(c.has_status(0, &"attack_up"), "has_status after add")
	_assert(c.size(0) == 1, "size == 1 after add")


func _test_status_container_remove_existing() -> void:
	print("[sc-3] status_container_remove_existing")
	var c = StatusContainerScript.new()
	var inst = StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5)
	c.add(inst)
	_assert(c.remove(0, &"attack_up"), "remove returns true")
	_assert(not c.has_status(0, &"attack_up"), "no longer has status")
	_assert(c.size(0) == 0, "size == 0 after remove")


func _test_status_container_remove_missing_no_op() -> void:
	print("[sc-4] status_container_remove_missing_no_op")
	var c = StatusContainerScript.new()
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5))
	_assert(not c.remove(0, &"shield"), "remove non-existent returns false")
	_assert(c.size(0) == 1, "size still 1")


func _test_status_container_duplicate_apply_increments_stack() -> void:
	print("[sc-5] status_container_duplicate_apply_increments_stack")
	var c = StatusContainerScript.new()
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5))
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5))
	# Default policy: duplicate apply increments stacks of the
	# existing instance (single-instance-per-def model).
	_assert(c.size(0) == 1, "size == 1 (single instance per def)")
	_assert(c.get_status(0, &"attack_up").stacks == 2,
		"stacks incremented to 2 (got %d)" % c.get_status(0, &"attack_up").stacks)


func _test_status_container_independent_entities() -> void:
	print("[sc-6] status_container_independent_entities")
	var c = StatusContainerScript.new()
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5))
	c.add(StatusInstanceScript.new(&"shield", 1, 1, 1, 9999, 10))
	_assert(c.has_status(0, &"attack_up"), "entity 0 has attack_up")
	_assert(c.has_status(1, &"shield"), "entity 1 has shield")
	_assert(not c.has_status(0, &"shield"), "entity 0 does NOT have shield")
	_assert(not c.has_status(1, &"attack_up"), "entity 1 does NOT have attack_up")


func _test_status_container_iteration_order_deterministic() -> void:
	print("[sc-7] status_container_iteration_order_deterministic")
	# StatusContainer iteration order is by insertion sequence
	# (NOT Dictionary order). Critical for deterministic trigger
	# semantics.
	var c = StatusContainerScript.new()
	c.add(StatusInstanceScript.new(&"first", 0, 0, 1, 9999, 1))
	c.add(StatusInstanceScript.new(&"second", 0, 0, 1, 9999, 2))
	c.add(StatusInstanceScript.new(&"third", 0, 0, 1, 9999, 3))
	var ids: Array = c.status_ids_for(0)
	_assert(ids.size() == 3, "3 statuses")
	_assert(int(ids[0]) == int(&"first"), "first by insertion")
	_assert(int(ids[1]) == int(&"second"), "second by insertion")
	_assert(int(ids[2]) == int(&"third"), "third by insertion")


func _test_status_container_cleanup_on_remove_entity() -> void:
	print("[sc-8] status_container_cleanup_on_remove_entity")
	# A1 fix: both statuses belong to entity 0 (the entity being
	# removed). The previous fixture mistakenly created a status
	# for entity 1.
	var w = _make_world()
	var c = StatusContainerScript.new()
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5))
	c.add(StatusInstanceScript.new(&"shield", 0, 0, 1, 9999, 10))
	# Manually attach container to world via set_status_container.
	w.set_status_container(0, c)
	_assert(c.size(0) == 2, "container has 2 statuses on entity 0")
	# Sanity: a separate container for entity 1 has no statuses
	# and is unaffected by entity 0 removal.
	var c1 = StatusContainerScript.new()
	c1.add(StatusInstanceScript.new(&"shield", 0, 1, 1, 9999, 10))
	w.set_status_container(1, c1)
	_assert(c1.size(1) == 1, "entity 1 has 1 status")
	w.remove_entity(0)
	# After remove_entity, the world must drop entity 0's container.
	_assert(w.get_status_container(0) == null,
		"status container cleared on entity removal (world ownership)")
	# Entity 1's container must remain untouched.
	_assert(w.get_status_container(1) != null,
		"entity 1's container unaffected by entity 0 removal")
	_assert(w.get_status_container(1).size(1) == 1,
		"entity 1's container still has 1 status")
	# External reference held by the test (c) is NOT required to
	# self-clear; the contract is about WORLD ownership only.
	_assert(c.size(0) == 2,
		"external RefCounted still has its 2 statuses (world ownership != destruction)")


func _test_status_container_no_shared_status_between_entities() -> void:
	print("[sc-9] status_container_no_shared_status_between_entities")
	# Adding a status to entity A must NOT create a reference
	# visible from entity B. Each entity gets its own copy.
	var w = _make_world()
	var ca = StatusContainerScript.new()
	var cb = StatusContainerScript.new()
	var inst_a = StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5)
	ca.add(inst_a)
	w.set_status_container(0, ca)
	w.set_status_container(1, cb)
	_assert(ca.has_status(0, &"attack_up"), "A has attack_up")
	_assert(not cb.has_status(1, &"attack_up"), "B does NOT have attack_up")
	# Mutate A's instance and verify B unaffected.
	inst_a.stacks = 99
	_assert(ca.get_status(0, &"attack_up").stacks == 99,
		"A's stacks mutated")
	_assert(cb.size(1) == 0, "B unchanged")


# === Stat Query ===

func _test_stat_query_returns_base_when_no_statuses() -> void:
	print("[sq-1] stat_query_returns_base_when_no_statuses")
	var w = _make_world()
	var sq = StatQueryScript.new(w)
	# Player 0 has base attack=20.
	_assert(sq.effective_attack(0) == 20,
		"effective_attack == 20 (got %d)" % sq.effective_attack(0))


func _test_stat_query_sums_attack_up_modifier() -> void:
	print("[sq-2] stat_query_sums_attack_up_modifier")
	var w = _make_world()
	var sq = StatQueryScript.new(w)
	var c = StatusContainerScript.new()
	# AttackUp: magnitude=5 is added to base.
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5))
	w.set_status_container(0, c)
	_assert(sq.effective_attack(0) == 25,
		"effective_attack == 20 + 5 = 25 (got %d)" % sq.effective_attack(0))


func _test_stat_query_removal_restores_base() -> void:
	print("[sq-3] stat_query_removal_restores_base")
	var w = _make_world()
	var sq = StatQueryScript.new(w)
	var c = StatusContainerScript.new()
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5))
	w.set_status_container(0, c)
	_assert(sq.effective_attack(0) == 25, "attack_up applied")
	c.remove(0, &"attack_up")
	_assert(sq.effective_attack(0) == 20,
		"effective_attack restored to 20 (got %d)" % sq.effective_attack(0))


func _test_stat_query_does_not_mutate_base_stat() -> void:
	print("[sq-4] stat_query_does_not_mutate_base_stat")
	var w = _make_world()
	var sq = StatQueryScript.new(w)
	var c = StatusContainerScript.new()
	c.add(StatusInstanceScript.new(&"attack_up", 0, 0, 1, 9999, 5))
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
	var sink: Array = pair[1]
	# Damage player first so there's HP to heal.
	world.apply_damage(0, 30)
	_assert(world.current_hp_of(0) == 50, "HP reduced to 50 (got %d)" % world.current_hp_of(0))
	var req = EffectRequestScript.new(
		EffectKindScript.HEAL, 0, 0, 20, 1, -1, 0)
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(result.success, "heal succeeds")
	_assert(world.current_hp_of(0) == 70,
		"HP restored to 70 (got %d)" % world.current_hp_of(0))
	# HEAL_APPLIED BattleEvent emitted.
	var saw_heal: bool = false
	for e in sink:
		if int(e.type) == HealEffectScript.HEAL_APPLIED:
			saw_heal = true
			break
	_assert(saw_heal, "HEAL_APPLIED BattleEvent emitted")


func _test_heal_overheal_caps_at_max() -> void:
	print("[hl-2] heal_overheal_caps_at_max")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	# Damage to 10 HP (max is 80).
	world.apply_damage(0, 70)
	_assert(world.current_hp_of(0) == 10, "HP reduced to 10 (got %d)" % world.current_hp_of(0))
	var req = EffectRequestScript.new(
		EffectKindScript.HEAL, 0, 0, 1000, 1, -1, 0)
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, req)
	_assert(world.current_hp_of(0) == 80,
		"HP capped at max (got %d)" % world.current_hp_of(0))


func _test_heal_full_health_no_change() -> void:
	print("[hl-3] heal_full_health_no_change")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	# HP already at max.
	var req = EffectRequestScript.new(
		EffectKindScript.HEAL, 0, 0, 20, 1, -1, 0)
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
	_assert(not world.is_alive(0), "player is dead")
	var req = EffectRequestScript.new(
		EffectKindScript.HEAL, 0, 0, 100, 1, -1, 0)
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(not result.success, "heal on dead returns failure")
	_assert(world.current_hp_of(0) == 0, "dead target stays at 0 (no resurrection)")


func _test_heal_invalid_target_returns_failure() -> void:
	print("[hl-5] heal_invalid_target_returns_failure")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	# target 999 not allocated.
	var req = EffectRequestScript.new(
		EffectKindScript.HEAL, 0, 999, 50, 1, -1, 0)
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
	# Now HP=30, max=80. Heal 100: room = 80-30 = 50. Actual = 50.
	var req = EffectRequestScript.new(
		EffectKindScript.HEAL, 0, 0, 100, 1, -1, -1)
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, req)
	var saw_heal: bool = false
	var saw_event_id: bool = false
	var saw_amount_match: bool = false
	for e in sink:
		if int(e.type) == HealEffectScript.HEAL_APPLIED:
			saw_heal = true
			if int(e.event_id) >= 1:
				saw_event_id = true
			if int(e.amount) == 50:
				saw_amount_match = true
			break
	_assert(saw_heal, "HEAL_APPLIED BattleEvent emitted")
	_assert(saw_event_id, "HEAL_APPLIED event_id > 0")
	_assert(saw_amount_match, "HEAL_APPLIED amount = actual HP restored (50)")


# === ApplyStatus / RemoveStatus effects ===

func _test_apply_status_to_live_target_emits_event() -> void:
	print("[as-1] apply_status_to_live_target_emits_event")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	var sink: Array = pair[1]
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0, 5, -1, 0)
	req.definition_id = &"attack_up"
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(result.success, "apply_status succeeds")
	var c = world.get_status_container(1)
	_assert(c != null, "status container created for target")
	_assert(c.has_status(1, &"attack_up"), "target has attack_up status")
	# STATUS_APPLIED BattleEvent emitted.
	var saw_applied: bool = false
	for e in sink:
		if int(e.type) == ApplyStatusEffectScript.STATUS_APPLIED:
			saw_applied = true
			break
	_assert(saw_applied, "STATUS_APPLIED BattleEvent emitted")


func _test_apply_status_to_dead_target_returns_failure() -> void:
	print("[as-2] apply_status_to_dead_target_returns_failure")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	world.apply_damage(0, 1000)  # kill player
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 1, 0, 0, 5, -1, 0)
	req.definition_id = &"attack_up"
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, req)
	_assert(not result.success, "apply to dead returns failure")
	var c = world.get_status_container(0)
	_assert(c == null or not c.has_status(0, &"attack_up"),
		"dead target has no attack_up")


func _test_apply_status_duplicate_stacks_or_refreshes() -> void:
	print("[as-3] apply_status_duplicate_stacks_or_refreshes")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	for i in 2:
		var req = EffectRequestScript.new(
			EffectKindScript.APPLY_STATUS, 0, 1, 0, 5, -1, 0)
		req.definition_id = &"attack_up"
		var exec = EffectExecutorScript.new()
		exec.execute(ctx, req)
	var c = world.get_status_container(1)
	var inst = c.get_status(1, &"attack_up")
	_assert(c.size(1) == 1, "single instance per def_id (got %d)" % c.size(1))
	_assert(inst.stacks == 2, "duplicate apply increments stacks (got %d)" % inst.stacks)


func _test_remove_status_existing_emits_event() -> void:
	print("[as-4] remove_status_existing_emits_event")
	var pair: Array = _make_ctx()
	var ctx = pair[0]
	var world: BattleWorldScript = ctx.world()
	var sink: Array = pair[1]
	# Apply first.
	var apply_req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0, 5, -1, 0)
	apply_req.definition_id = &"attack_up"
	var exec = EffectExecutorScript.new()
	exec.execute(ctx, apply_req)
	var sink_size_before: int = sink.size()
	# Remove.
	var rm_req = EffectRequestScript.new(
		EffectKindScript.REMOVE_STATUS, 0, 1, 0, 5, -1, 0)
	rm_req.definition_id = &"attack_up"
	var result = exec.execute(ctx, rm_req)
	_assert(result.success, "remove succeeds")
	var c = world.get_status_container(1)
	_assert(not c.has_status(1, &"attack_up"), "status removed")
	var saw_removed: bool = false
	for e in sink.slice(sink_size_before):
		if int(e.type) == RemoveStatusEffectScript.STATUS_REMOVED:
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
		EffectKindScript.REMOVE_STATUS, 0, 1, 0, 5, -1, 0)
	rm_req.definition_id = &"attack_up"
	var exec = EffectExecutorScript.new()
	var result = exec.execute(ctx, rm_req)
	_assert(not result.success, "remove missing returns failure")
	_assert(sink.size() == sink_size_before, "no event emitted for missing")
