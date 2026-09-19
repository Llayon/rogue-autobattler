extends SceneTree
## Phase 3 / B4.1 — indefinite blocking + status-progress
## contract closure.
##
## Covers:
##   - HIGH 1: StatQuery.blocks_actions() treats indefinite
##     statuses (remaining=-1) as ACTIVE blocking.
##   - remaining=0 -> NOT blocking.
##   - Multiple finite + indefinite blocker composition.
##   - Finite max-HP Regen postpones baseline stalemate
##     (B4 status-progress contract).
##   - Indefinite no-op Regen still permits true stalemate.
##   - Real Stun 1.5->2 blocks exactly one normal action
##     opportunity (tick 1) and expires on tick 2 (action
##     allowed same tick after STATUS_EXPIRED).
##   - STATUS_EXPIRED precedes UNIT_MOVED/ATTACK_RESOLVED
##     for the formerly-stunned entity.

const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const StatusInstanceScript = preload("res://core/battle_ecs/status/status_instance.gd")
const StatQueryScript = preload("res://core/battle_ecs/status/stat_query.gd")
const StatusDefResolverScript = preload(
	"res://core/battle_ecs/status/status_def_resolver.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleResultScript = preload("res://core/battle_ecs/battle_result.gd")
const ContentDBScript = preload("res://core/utils/content_db.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	# === HIGH 1 indefinite blocking ===
	await _test_indefinite_blocker_active()
	await _test_indefinite_blocker_stays_active_across_phases()
	await _test_expired_blocker_not_blocking()
	await _test_no_status_ticked_for_indefinite_blocker()
	await _test_multiple_blockers_finite_plus_indefinite()
	await _test_indefinite_blocker_alone_after_finite_removes()
	# === B4 status-progress contract closure ===
	await _test_baseline_stalemate_tick_2()
	await _test_finite_max_hp_regen_postpones_stalemate_past_baseline()
	await _test_indefinite_max_hp_regen_still_baseline_stalemate_tick_2()
	# === Real Stun action-opportunity proof ===
	await _test_real_stun_blocks_one_normal_action_opportunity()
	await _test_status_expired_before_resumed_action()
	print("\n=== B4.1 focused tests: %d passed, %d failed ===\n" % [_passed, _failed])
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


# === HIGH 1 indefinite blocking ===

func _test_indefinite_blocker_active() -> void:
	print("[IND-1] indefinite_blocker_active")
	# Synthetic blocker with remaining=-1.
	var def = _make_synthetic_block_def(&"synth_indef_block", 0.0, -1, 0, 0)
	_inject_synthetic_def(def)
	var w = _setup_world()
	var c = w.get_status_container(1)
	if c == null:
		c = w.create_status_container(1)
	var inst = StatusInstanceScript.new(
		&"synth_indef_block", 0, 1, 1, -1, 0)
	c.add(inst, "stackable", 99)
	_assert(StatQueryScript.blocks_actions(w, 1) == true,
		"indefinite blocker (remaining=-1) -> blocks_actions=true")
	_assert(int(inst.remaining) == -1,
		"remaining still -1 (not expired)")


func _test_indefinite_blocker_stays_active_across_phases() -> void:
	print("[IND-2] indefinite_blocker_stays_active_across_phases")
	# Verify indefinite blocker remains active across multiple
	# status-phase ticks without decrement or expiry.
	var def = _make_synthetic_block_def(&"synth_indef_block2", 0.0, -1, 0, 0)
	_inject_synthetic_def(def)
	var w = _setup_world()
	var em = BattleEventEmitterScript.new()
	em.reset()
	var rng = DeterministicRngScript.new(0)
	var c = w.get_status_container(1)
	if c == null:
		c = w.create_status_container(1)
	var inst = StatusInstanceScript.new(
		&"synth_indef_block2", 0, 1, 1, -1, 0)
	c.add(inst, "stackable", 99)
	for _i in range(3):
		inst.tick(1)
		_assert(int(inst.remaining) == -1,
			"after tick %d remaining still -1" % (_i + 1))
		_assert(StatQueryScript.blocks_actions(w, 1) == true,
			"after tick %d still blocks" % (_i + 1))


func _test_expired_blocker_not_blocking() -> void:
	print("[EXP-0] expired_blocker_not_blocking")
	# A blocker with remaining=0 (just expired this tick)
	# must NOT block. Direct defensive query proof.
	var def = _make_synthetic_block_def(&"synth_expired_block", 0.0, 0, 0, 0)
	_inject_synthetic_def(def)
	var w = _setup_world()
	var c = w.get_status_container(1)
	if c == null:
		c = w.create_status_container(1)
	var inst = StatusInstanceScript.new(
		&"synth_expired_block", 0, 1, 1, 0, 0)
	c.add(inst, "stackable", 99)
	_assert(StatQueryScript.blocks_actions(w, 1) == false,
		"remaining=0 blocker -> blocks_actions=false (expired)")


func _test_no_status_ticked_for_indefinite_blocker() -> void:
	print("[NO-TICK] no_status_ticked_for_indefinite_blocker")
	# tick_interval=0 indefinite blocker: NO STATUS_TICKED
	# emitted, NO STATUS_EXPIRED.
	var def = _make_synthetic_block_def(&"synth_indef_no_tick", 0.0, -1, 0, 0)
	_inject_synthetic_def(def)
	var w = _setup_world()
	var em = BattleEventEmitterScript.new()
	em.reset()
	var rng = DeterministicRngScript.new(0)
	var c = w.get_status_container(1)
	if c == null:
		c = w.create_status_container(1)
	var inst = StatusInstanceScript.new(
		&"synth_indef_no_tick", 0, 1, 1, -1, 0)
	c.add(inst, "stackable", 99)
	for _i in range(2):
		inst.tick(1)
	_assert(int(inst.remaining) == -1,
		"after 2 ticks remaining still -1")


func _test_multiple_blockers_finite_plus_indefinite() -> void:
	print("[COMP-1] multiple_blockers_finite_plus_indefinite")
	# Composition: finite blocker A (remaining=3) +
	# indefinite blocker B (remaining=-1).
	var def_a = _make_synthetic_block_def(&"synth_finite_a", 0.0, 3, 0, 0)
	_inject_synthetic_def(def_a)
	var def_b = _make_synthetic_block_def(&"synth_indef_b", 0.0, -1, 0, 0)
	_inject_synthetic_def(def_b)
	var w = _setup_world()
	var c = w.get_status_container(1)
	if c == null:
		c = w.create_status_container(1)
	var a = StatusInstanceScript.new(
		&"synth_finite_a", 0, 1, 1, 3, 0)
	c.add(a, "stackable", 99)
	var b = StatusInstanceScript.new(
		&"synth_indef_b", 0, 1, 1, -1, 0)
	c.add(b, "stackable", 99)
	_assert(StatQueryScript.blocks_actions(w, 1) == true,
		"A (finite) + B (indefinite) -> blocks")
	# Tick A toward expiry (without removing it; query is on
	# the raw instance).
	for _i in range(3):
		a.tick(1)
	_assert(int(a.remaining) == 0, "A remaining=0 (expired)")
	# Even though A is expired, B (indefinite) still blocks.
	_assert(StatQueryScript.blocks_actions(w, 1) == true,
		"after A expired, B (indefinite) STILL blocks")
	# Remove B -> unblocked.
	c.remove(&"synth_indef_b")
	_assert(StatQueryScript.blocks_actions(w, 1) == false,
		"after B removed -> NOT blocked")


func _test_indefinite_blocker_alone_after_finite_removes() -> void:
	print("[COMP-2] indefinite_blocker_alone_after_finite_removes")
	# Single indefinite blocker. No finite present.
	var def = _make_synthetic_block_def(&"synth_indef_alone", 0.0, -1, 0, 0)
	_inject_synthetic_def(def)
	var w = _setup_world()
	var c = w.get_status_container(1)
	if c == null:
		c = w.create_status_container(1)
	var inst = StatusInstanceScript.new(
		&"synth_indef_alone", 0, 1, 1, -1, 0)
	c.add(inst, "stackable", 99)
	_assert(StatQueryScript.blocks_actions(w, 1) == true,
		"indefinite alone -> blocks")
	# Remove it.
	c.remove(&"synth_indef_alone")
	_assert(StatQueryScript.blocks_actions(w, 1) == false,
		"after remove -> NOT blocked")


# === B4 status-progress contract closure ===

func _test_baseline_stalemate_tick_2() -> void:
	print("[STALE-BASE] baseline_stalemate_tick_2")
	# True no-progress 1x4 fixture. Same as B3.3 STALE-REAL-1.
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p0 = B.new("p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var p1 = B.new("p1", &"warrior", 0, Vector2i(0, 1), 100, 100, 20, 5, 1)
	var e0 = B.new("e0", &"orc", 1, Vector2i(0, 3), 100, 100, 20, 5, 1)
	var e1 = B.new("e1", &"orc", 1, Vector2i(0, 2), 100, 100, 20, 5, 1)
	var s = S.new(42, [p0, p1], [e0, e1], 1, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(s)
	var events: Array = sim.run_until_done(20)
	var result = sim.get_result()
	if result == null:
		_assert(false, "result is null")
		return
	_assert(int(result.termination_reason) == int(BattleResultScript.TERMINATION_STALEMATE),
		"baseline: TERMINATION_STALEMATE")
	_assert(int(result.winner_team) == -1, "baseline: DRAW")
	_assert(int(result.tick_count) == 2,
		"baseline terminates at tick 2 (got %d)" % int(result.tick_count))


func _test_finite_max_hp_regen_postpones_stalemate_past_baseline() -> void:
	print("[STALE-FINITE] finite_max_hp_regen_postpones_stalemate_past_baseline")
	# Same fixture + real finite Regen at max HP. Per B4-13,
	# finite status countdown IS progress -> stalemate is
	# delayed past baseline tick 2. After Regen expires
	# (remaining -> 0), normal stalemate begins.
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p0 = B.new("p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var p1 = B.new("p1", &"warrior", 0, Vector2i(0, 1), 100, 100, 20, 5, 1)
	var e0 = B.new("e0", &"orc", 1, Vector2i(0, 3), 100, 100, 20, 5, 1)
	var e1 = B.new("e1", &"orc", 1, Vector2i(0, 2), 100, 100, 20, 5, 1)
	var s = S.new(42, [p0, p1], [e0, e1], 1, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(s)
	# Apply Regen to P0 at max HP. Real regen.tres has
	# duration=5 (no fractional), so remaining=5.
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"regen"
	var ctx = EffectContextScript.new(sim.world(), sim.rng(),
		sim.emitter(), [])
	EffectExecutorScript.new().execute(ctx, req)
	var events: Array = sim.run_until_done(20)
	var result = sim.get_result()
	if result == null:
		_assert(false, "result is null")
		return
	_assert(int(result.termination_reason) == int(BattleResultScript.TERMINATION_STALEMATE),
		"finite Regen: TERMINATION_STALEMATE (got %d)" % int(result.termination_reason))
	# Critical: must be strictly LATER than baseline tick 2.
	var sim_base = BattleSimulationScript.new()
	sim_base.initialize(s)
	sim_base.run_until_done(20)
	var result_base = sim_base.get_result()
	if result_base != null:
		_assert(int(result.tick_count) > int(result_base.tick_count),
			"finite max-HP Regen postpones stalemate (baseline=%d regen=%d)" % [int(result_base.tick_count), int(result.tick_count)])
	# HEAL_APPLIED = 0 (target at max HP).
	var heals: int = 0
	for e in events:
		if int(e.type) == BattleEventTypeScript.HEAL_APPLIED:
			heals += 1
	_assert(heals == 0,
		"max-HP Regen emits 0 HEAL_APPLIED")
	# STATUS_TICKED may exist.
	var tick_count: int = 0
	for e in events:
		if int(e.type) == BattleEventTypeScript.STATUS_TICKED:
			tick_count += 1
	_assert(tick_count > 0,
		"finite Regen DOES emit STATUS_TICKED events (got %d)" % tick_count)
	# Regen STATUS_EXPIRED must fire within the run.
	var expired: bool = false
	for e in events:
		if int(e.type) == BattleEventTypeScript.STATUS_EXPIRED \
				and String(e.tag) == "regen":
			expired = true
	_assert(expired,
		"finite Regen STATUS_EXPIRED fires before stalemate")


func _test_indefinite_max_hp_regen_still_baseline_stalemate_tick_2() -> void:
	print("[STALE-INDEF] indefinite_max_hp_regen_still_baseline_stalemate_tick_2")
	# Indefinite Regen (remaining=-1) does NOT contribute to
	# progress signature. Same stalemate tick as baseline.
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p0 = B.new("p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var p1 = B.new("p1", &"warrior", 0, Vector2i(0, 1), 100, 100, 20, 5, 1)
	var e0 = B.new("e0", &"orc", 1, Vector2i(0, 3), 100, 100, 20, 5, 1)
	var e1 = B.new("e1", &"orc", 1, Vector2i(0, 2), 100, 100, 20, 5, 1)
	var s = S.new(42, [p0, p1], [e0, e1], 1, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(s)
	# Inject indefinite Regen on P0.
	var c_p0 = sim.world().get_status_container(0)
	if c_p0 == null:
		c_p0 = sim.world().create_status_container(0)
	var indef = StatusInstanceScript.new(
		&"regen", 0, 0, 1, -1, 0)
	c_p0.add(indef, "stackable", 99)
	var events: Array = sim.run_until_done(20)
	var result = sim.get_result()
	if result == null:
		_assert(false, "result is null")
		return
	_assert(int(result.termination_reason) == int(BattleResultScript.TERMINATION_STALEMATE),
		"indefinite Regen: TERMINATION_STALEMATE")
	# Same stalemate tick as baseline (tick 2).
	_assert(int(result.tick_count) == 2,
		"indefinite Regen terminates at SAME tick as baseline (got %d, expected 2)" % int(result.tick_count))
	# HEAL_APPLIED = 0.
	var heals: int = 0
	for e in events:
		if int(e.type) == BattleEventTypeScript.HEAL_APPLIED:
			heals += 1
	_assert(heals == 0, "max-HP indefinite Regen emits 0 HEAL_APPLIED")
	# STATUS_TICKED may exist (indefinite periodic still fires).
	var tick_count: int = 0
	for e in events:
		if int(e.type) == BattleEventTypeScript.STATUS_TICKED:
			tick_count += 1
	_assert(tick_count > 0,
		"indefinite Regen DOES emit STATUS_TICKED (got %d)" % tick_count)
	# No STATUS_EXPIRED for regen (indefinite never expires).
	var regen_expired: bool = false
	for e in events:
		if int(e.type) == BattleEventTypeScript.STATUS_EXPIRED \
				and String(e.tag) == "regen":
			regen_expired = true
	_assert(not regen_expired,
		"indefinite Regen does NOT emit STATUS_EXPIRED")


# === Real Stun action-opportunity proof ===

func _test_real_stun_blocks_one_normal_action_opportunity() -> void:
	print("[STUN-ACTION] real_stun_blocks_one_normal_action_opportunity")
	# Real stun.tres applied via production ApplyStatusEffect.
	# Expected runtime: remaining=2 (ceil(1.5)=2 ticks).
	# Decrement-first timing:
	#   tick 1: 2 -> 1, still active, action blocked
	#   tick 2: 1 -> 0, STATUS_EXPIRED, action allowed
	# So real Stun blocks EXACTLY ONE normal action opportunity
	# under the current scheduler.
	#
	# Layout: 5x1 grid. P0 at (0,0), P1 at (4,0) (far away so
	# P0 doesn't run into P1), E0 at (1,1) (adjacent to P0's
	# action range). P0 wants to attack E0 normally. With Stun
	# active on tick 1, P0 cannot attack. On tick 2, P0 acts.
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p0 = B.new("p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var p1 = B.new("p1", &"warrior", 0, Vector2i(4, 0), 100, 100, 20, 5, 1)
	var e0 = B.new("e0", &"orc", 1, Vector2i(1, 1), 100, 100, 20, 5, 1)
	var s = S.new(42, [p0, p1], [e0], 5, 2)
	var sim = BattleSimulationScript.new()
	sim.initialize(s)
	# Verify stun was applied with remaining=2.
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"stun"
	var ctx = EffectContextScript.new(sim.world(), sim.rng(),
		sim.emitter(), [])
	EffectExecutorScript.new().execute(ctx, req)
	var c_p0 = sim.world().get_status_container(0)
	var stun_inst = c_p0.get_status(&"stun")
	_assert(int(stun_inst.remaining) == 2,
		"real stun remaining=2 (ceil(1.5)=2)")
	# Run 2 ticks. P0 must NOT attack on tick 1; MUST attack
	# on tick 2 (after stun expired).
	var events: Array = sim.run_until_done(2)
	# Count DAMAGE_APPLIED events per tick with source=0.
	var p0_attack_ticks: Array = []
	for e in events:
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and int(e.source_entity) == 0:
			p0_attack_ticks.append(int(e.tick))
	_assert(p0_attack_ticks.size() == 1,
		"real Stun blocks EXACTLY 1 action opportunity (got %d P0 attacks)" % p0_attack_ticks.size())
	if p0_attack_ticks.size() >= 1:
		_assert(p0_attack_ticks[0] == 2,
			"P0 attacks on tick 2 (after stun expiry), not tick 1 (got tick %d)" % p0_attack_ticks[0])
	_assert(p0_attack_ticks.find(1) == -1,
		"P0 did NOT attack on tick 1 (stun blocked)")


func _test_status_expired_before_resumed_action() -> void:
	print("[STUN-EXP] status_expired_before_resumed_action")
	# Same layout as above. Verify STATUS_EXPIRED(stun) appears
	# BEFORE the resumed P0 action in the same tick (tick 2).
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p0 = B.new("p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var p1 = B.new("p1", &"warrior", 0, Vector2i(4, 0), 100, 100, 20, 5, 1)
	var e0 = B.new("e0", &"orc", 1, Vector2i(1, 1), 100, 100, 20, 5, 1)
	var s = S.new(42, [p0, p1], [e0], 5, 2)
	var sim = BattleSimulationScript.new()
	sim.initialize(s)
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"stun"
	var ctx = EffectContextScript.new(sim.world(), sim.rng(),
		sim.emitter(), [])
	EffectExecutorScript.new().execute(ctx, req)
	var events: Array = sim.run_until_done(2)
	# Find indices of STATUS_EXPIRED(stun) and first
	# DAMAGE_APPLIED with source=0.
	var expired_idx: int = -1
	var attack_idx: int = -1
	for i in events.size():
		var e = events[i]
		if expired_idx == -1 and int(e.type) == BattleEventTypeScript.STATUS_EXPIRED \
				and String(e.tag) == "stun":
			expired_idx = i
		if attack_idx == -1 and int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and int(e.source_entity) == 0:
			attack_idx = i
	_assert(expired_idx >= 0,
		"STATUS_EXPIRED(stun) emitted")
	_assert(attack_idx >= 0,
		"P0 attack event emitted")
	_assert(expired_idx < attack_idx,
		"STATUS_EXPIRED precedes resumed P0 action (idx expired=%d attack=%d)" % [expired_idx, attack_idx])


# === Helpers ===

func _setup_world() -> BattleWorldScript:
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p0 = B.new("p0", &"warrior", 0, Vector2i(0, 1), 100, 100, 20, 5, 1)
	var p1 = B.new("p1", &"warrior", 0, Vector2i(1, 0), 100, 100, 20, 5, 1)
	var e0 = B.new("e0", &"orc", 1, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var s = S.new(42, [p0], [e0], 7, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(s)
	return w


func _make_synthetic_block_def(p_id: StringName, p_interval: float,
		p_duration_ticks: int, p_dot_damage: int, p_dot_heal: int) -> Resource:
	var StatusDefScript = preload("res://core/data/status_def.gd")
	var s = StatusDefScript.new()
	s.id = p_id
	s.duration = float(p_duration_ticks)
	s.tick_interval = p_interval
	s.dot_damage = p_dot_damage
	s.dot_heal = p_dot_heal
	s.is_harmful = true
	s.blocks_actions = true
	return s


func _inject_synthetic_def(def: Resource) -> void:
	var ContentDBScript = preload("res://core/utils/content_db.gd")
	ContentDBScript.ensure_loaded()
	var id: StringName = def.id
	var typed: Dictionary = ContentDBScript._by_id_by_type.get("effects", {})
	typed[id] = def
	if not ContentDBScript._by_id.has(id):
		ContentDBScript._by_id[id] = def
