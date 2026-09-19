extends SceneTree
## Phase 3 / B3.3 — periodic payload semantics + true stalemate proof.
##
## Covers:
##   - classify_periodic_payload() unit-level helper:
##     NONE / DAMAGE / HEAL / DUAL / INVALID.
##   - HIGH 1: is_harmful no longer drives DOT/HOT routing.
##   - Zero-payload periodic status: NO STATUS_TICKED, NO
##     DAMAGE_APPLIED, NO HEAL_APPLIED (duration still ticks).
##   - Zero-damage adversarial: a periodic definition with no
##     DOT payload CANNOT reach EffectKind.DAMAGE amount=0;
##     CANNOT fall through to Balance.compute_damage (attack
##     damage fallback is unreachable from periodic code).
##   - Dual-payload (DOT+HOT > 0): FEATURE DEFER (silent skip,
##     no STATUS_TICKED).
##   - MEDIUM 2: RNG null at processor boundary -> early-return
##     [] with no mutation.
##   - MEDIUM 3: TRUE no-progress stalemate — TERMINATION_STALEMATE
##     with TERMINATION_REASON=STALEMATE (not TICK_BUDGET).
##   - max-HP Regen does not postpone stalemate.

const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const StatusInstanceScript = preload("res://core/battle_ecs/status/status_instance.gd")
const PeriodicStatusProcessorScript = preload(
	"res://core/battle_ecs/status/periodic_status_processor.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleResultScript = preload("res://core/battle_ecs/battle_result.gd")
const ContentDBScript = preload("res://core/utils/content_db.gd")
const StatusDefResolverScript = preload(
	"res://core/battle_ecs/status/status_def_resolver.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	# === Periodic payload classification helper ===
	await _test_classify_periodic_payload_none()
	await _test_classify_periodic_payload_damage()
	await _test_classify_periodic_payload_heal()
	await _test_classify_periodic_payload_dual()
	await _test_classify_periodic_payload_invalid()
	# === HIGH 1: is_harmful no longer drives routing ===
	await _test_processor_source_text_contains_no_is_harmful_branch()
	await _test_real_burn_routes_via_dot_damage_not_is_harmful()
	await _test_real_regen_routes_via_dot_heal_not_is_harmful()
	# === Zero-payload / zero-damage / dual-payload contract ===
	await _test_zero_payload_status_no_periodic_fires()
	await _test_zero_damage_cannot_reach_damage_effect_with_amount_zero()
	await _test_dual_payload_skipped_silently_no_status_ticked()
	await _test_zero_payload_still_decrements_duration()
	# === MEDIUM 2: RNG null at boundary ===
	await _test_processor_with_null_rng_returns_empty_no_mutation()
	await _test_processor_with_null_emitter_returns_empty_no_mutation()
	# === MEDIUM 3: TRUE no-progress stalemate ===
	await _test_baseline_no_progress_stalemate_termination()
	await _test_max_hp_regen_does_not_postpone_true_stalemate()
	print("\n=== B3.3 focused tests: %d passed, %d failed ===\n" % [_passed, _failed])
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


# === Classification helper ===

func _test_classify_periodic_payload_none() -> void:
	print("[CLS-1] classify_periodic_payload_none")
	var k: int = PeriodicStatusProcessorScript.classify_periodic_payload(0, 0)
	_assert(k == PeriodicStatusProcessorScript.PERIODIC_NONE,
		"damage=0 heal=0 -> PERIODIC_NONE (got %d)" % k)


func _test_classify_periodic_payload_damage() -> void:
	print("[CLS-2] classify_periodic_payload_damage")
	var k: int = PeriodicStatusProcessorScript.classify_periodic_payload(5, 0)
	_assert(k == PeriodicStatusProcessorScript.PERIODIC_DAMAGE,
		"damage=5 heal=0 -> PERIODIC_DAMAGE (got %d)" % k)


func _test_classify_periodic_payload_heal() -> void:
	print("[CLS-3] classify_periodic_payload_heal")
	var k: int = PeriodicStatusProcessorScript.classify_periodic_payload(0, 5)
	_assert(k == PeriodicStatusProcessorScript.PERIODIC_HEAL,
		"damage=0 heal=5 -> PERIODIC_HEAL (got %d)" % k)


func _test_classify_periodic_payload_dual() -> void:
	print("[CLS-4] classify_periodic_payload_dual")
	var k: int = PeriodicStatusProcessorScript.classify_periodic_payload(5, 5)
	_assert(k == PeriodicStatusProcessorScript.PERIODIC_DUAL,
		"damage=5 heal=5 -> PERIODIC_DUAL (got %d)" % k)


func _test_classify_periodic_payload_invalid() -> void:
	print("[CLS-5] classify_periodic_payload_invalid")
	_assert(PeriodicStatusProcessorScript.classify_periodic_payload(-1, 0) ==
		PeriodicStatusProcessorScript.PERIODIC_INVALID, "damage=-1 heal=0 -> INVALID")
	_assert(PeriodicStatusProcessorScript.classify_periodic_payload(0, -1) ==
		PeriodicStatusProcessorScript.PERIODIC_INVALID, "damage=0 heal=-1 -> INVALID")
	_assert(PeriodicStatusProcessorScript.classify_periodic_payload(-1, -1) ==
		PeriodicStatusProcessorScript.PERIODIC_INVALID, "damage=-1 heal=-1 -> INVALID")


# === HIGH 1: is_harmful removed from routing ===

func _test_processor_source_text_contains_no_is_harmful_branch() -> void:
	print("[HIGH1-1] processor_source_text_contains_no_is_harmful_branch")
	# Read processor source. Confirm there is NO semantic
	# `if def.is_harmful:` branch driving DOT vs HOT routing.
	var f = FileAccess.open(
		"res://core/battle_ecs/status/periodic_status_processor.gd",
		FileAccess.READ)
	if f == null:
		_assert(false, "could not open processor source")
		return
	var src: String = f.get_as_text()
	f.close()
	# Search for "is_harmful" in the routing branch. The const
	# and any doc references are OK; the *branching* on
	# is_harmful must not exist.
	var has_branch: bool = src.contains("if def.is_harmful")
	_assert(not has_branch,
		"processor source has no `if def.is_harmful` semantic branch")


func _test_real_burn_routes_via_dot_damage_not_is_harmful() -> void:
	print("[HIGH1-2] real_burn_routes_via_dot_damage_not_is_harmful")
	# Real burn.tres: dot_damage=5, dot_heal=0, is_harmful
	# property is whatever the resource exposes (likely true).
	# Periodic routing must STILL produce DAMAGE because
	# dot_damage > 0.
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	var rng = w["rng"]
	var c = w["world"].get_status_container(1)
	if c == null:
		c = w["world"].create_status_container(1)
	var inst = StatusInstanceScript.new(&"burn", 0, 1, 1, 100, 0)
	c.add(inst, "stackable", 99)
	var evs = PeriodicStatusProcessorScript.process_tick(
		w["world"], rng, em)
	var dmg: Array = _events_of_type(evs, BattleEventTypeScript.DAMAGE_APPLIED)
	_assert(dmg.size() == 1,
		"real burn produces DAMAGE_APPLIED via dot_damage routing")
	var healed: Array = _events_of_type(evs, BattleEventTypeScript.HEAL_APPLIED)
	_assert(healed.size() == 0,
		"real burn does NOT produce HEAL_APPLIED (dot_heal == 0)")


func _test_real_regen_routes_via_dot_heal_not_is_harmful() -> void:
	print("[HIGH1-3] real_regen_routes_via_dot_heal_not_is_harmful")
	var w = _setup_world_with_low_hp(0, 1)
	var em: BattleEventEmitterScript = w["emitter"]
	var rng = w["rng"]
	var c = w["world"].get_status_container(0)
	if c == null:
		c = w["world"].create_status_container(0)
	var inst = StatusInstanceScript.new(&"regen", 1, 0, 1, 100, 0)
	c.add(inst, "stackable", 99)
	var evs = PeriodicStatusProcessorScript.process_tick(
		w["world"], rng, em)
	var healed: Array = _events_of_type(evs, BattleEventTypeScript.HEAL_APPLIED)
	_assert(healed.size() == 1,
		"real regen produces HEAL_APPLIED via dot_heal routing")
	var dmg: Array = _events_of_type(evs, BattleEventTypeScript.DAMAGE_APPLIED)
	_assert(dmg.size() == 0,
		"real regen does NOT produce DAMAGE_APPLIED (dot_damage == 0)")


# === Zero-payload contract ===

func _test_zero_payload_status_no_periodic_fires() -> void:
	print("[ZP-1] zero_payload_status_no_periodic_fires")
	# Use real attack_up.tres with interval=1.0 — but it has
	# tick_interval=0.0 default. We need a synthetic runtime
	# status with interval=1.0 and zero payload. Create a
	# StatusDef Resource directly with interval=1.0 and
	# dot_damage=0, dot_heal=0, then load it via Resource path
	# trick: instantiate, set fields, do NOT add to ContentDB.
	# The processor uses StatusDefResolver which looks up by id.
	# So: instead, monkey-patch _by_id_by_type to include a
	# synthetic def. We will use a runtime StatusInstance only
	# with the real StatusDef — and rely on the fact that
	# tick_interval=0 will skip. To test PERIODIC_NONE case we
	# need interval=1.0 and zero payload, which no real status
	# has.
	#
	# Workaround: register a synthetic def via ContentDB._by_id_by_type
	# then call process_tick. Use a temporary id not in real
	# content.
	#
	# Simpler approach: directly verify the routing decision
	# by examining emitted events. Seed a runtime StatusInstance
	# for a synthetic status_id that the resolver will fail on.
	# Result: def == null -> continue -> no events. That's
	# already tested. Instead test via the classifier: verify
	# that PERIODIC_NONE causes no STATUS_TICKED via the
	# public API contract.
	#
	# For a behavioral test: register a synthetic def with
	# interval=1.0 and zero payload via _by_id_by_type
	# injection. Test that no STATUS_TICKED fires.
	var synth_def = _make_synthetic_def(&"zero_payload_synth", 1.0, 5, 0, 0)
	_inject_synthetic_def(synth_def)
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	var rng = w["rng"]
	var c = w["world"].get_status_container(1)
	if c == null:
		c = w["world"].create_status_container(1)
	var inst = StatusInstanceScript.new(&"zero_payload_synth", 0, 1, 1, 5, 0)
	c.add(inst, "stackable", 99)
	var evs = PeriodicStatusProcessorScript.process_tick(
		w["world"], rng, em)
	_assert(_events_of_type(evs, BattleEventTypeScript.STATUS_TICKED).size() == 0,
		"zero-payload periodic: 0 STATUS_TICKED")
	_assert(_events_of_type(evs, BattleEventTypeScript.DAMAGE_APPLIED).size() == 0,
		"zero-payload periodic: 0 DAMAGE_APPLIED")
	_assert(_events_of_type(evs, BattleEventTypeScript.HEAL_APPLIED).size() == 0,
		"zero-payload periodic: 0 HEAL_APPLIED")
	# Duration still decrements.
	_assert(int(inst.remaining) == 4,
		"zero-payload duration still decrements (got %d)" % int(inst.remaining))


func _test_zero_payload_still_decrements_duration() -> void:
	print("[ZP-2] zero_payload_still_decrements_duration")
	var synth_def = _make_synthetic_def(&"zero_payload_decay", 1.0, 3, 0, 0)
	_inject_synthetic_def(synth_def)
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	var rng = w["rng"]
	var c = w["world"].get_status_container(1)
	if c == null:
		c = w["world"].create_status_container(1)
	var inst = StatusInstanceScript.new(&"zero_payload_decay", 0, 1, 1, 3, 0)
	c.add(inst, "stackable", 99)
	for i in range(3):
		PeriodicStatusProcessorScript.process_tick(w["world"], rng, em)
	_assert(int(inst.remaining) == 0,
		"after 3 ticks zero-payload remaining=0 (got %d)" % int(inst.remaining))
	_assert(c.has_status(&"zero_payload_decay") == false,
		"zero-payload expires after 3 ticks via STATUS_EXPIRED")


# === Zero-damage adversarial ===

func _test_zero_damage_cannot_reach_damage_effect_with_amount_zero() -> void:
	print("[ZD-1] zero_damage_cannot_reach_damage_effect_with_amount_zero")
	# Use a synthetic def with dot_damage=0, dot_heal=5
	# (PERIODIC_HEAL). Confirm the emitted periodic request is
	# routed as HEAL, NOT DAMAGE. This is the regression guard:
	# DamageEffect with amount=0 falls through to normal
	# attack damage (Balance.compute_damage), which would
	# silently reduce target HP even though DOT is zero.
	var synth_def = _make_synthetic_def(&"heal_only_synth", 1.0, 5, 0, 5)
	_inject_synthetic_def(synth_def)
	# Entity 1 starts at HP=99 (1 below max) so HEAL_APPLIED fires.
	var w = _setup_world_with_low_hp(1, 99)
	var em: BattleEventEmitterScript = w["emitter"]
	var rng = w["rng"]
	var c = w["world"].get_status_container(1)
	if c == null:
		c = w["world"].create_status_container(1)
	var inst = StatusInstanceScript.new(&"heal_only_synth", 0, 1, 1, 5, 0)
	c.add(inst, "stackable", 99)
	var hp_before: int = int(w["world"].current_hp_of(1))
	var evs = PeriodicStatusProcessorScript.process_tick(
		w["world"], rng, em)
	var hp_after: int = int(w["world"].current_hp_of(1))
	_assert(_events_of_type(evs, BattleEventTypeScript.DAMAGE_APPLIED).size() == 0,
		"heal-only periodic: 0 DAMAGE_APPLIED (no fallback to Balance.compute_damage)")
	_assert(_events_of_type(evs, BattleEventTypeScript.HEAL_APPLIED).size() == 1,
		"heal-only periodic: 1 HEAL_APPLIED")
	_assert(hp_after >= hp_before,
		"HP did not decrease (was %d, now %d)" % [hp_before, hp_after])


# === Dual payload ===

func _test_dual_payload_skipped_silently_no_status_ticked() -> void:
	print("[DUAL-1] dual_payload_skipped_silently_no_status_ticked")
	# Synthetic def with BOTH dot_damage > 0 and dot_heal > 0.
	# B3 does not support dual. Must skip silently.
	var synth_def = _make_synthetic_def(&"dual_synth", 1.0, 5, 3, 3)
	_inject_synthetic_def(synth_def)
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	var rng = w["rng"]
	var c = w["world"].get_status_container(1)
	if c == null:
		c = w["world"].create_status_container(1)
	var inst = StatusInstanceScript.new(&"dual_synth", 0, 1, 1, 5, 0)
	c.add(inst, "stackable", 99)
	var evs = PeriodicStatusProcessorScript.process_tick(
		w["world"], rng, em)
	_assert(_events_of_type(evs, BattleEventTypeScript.STATUS_TICKED).size() == 0,
		"dual payload: 0 STATUS_TICKED (FEATURE DEFER)")
	_assert(_events_of_type(evs, BattleEventTypeScript.DAMAGE_APPLIED).size() == 0,
		"dual payload: 0 DAMAGE_APPLIED")
	_assert(_events_of_type(evs, BattleEventTypeScript.HEAL_APPLIED).size() == 0,
		"dual payload: 0 HEAL_APPLIED")
	# Duration still decrements.
	_assert(int(inst.remaining) == 4,
		"dual payload duration still decrements (got %d)" % int(inst.remaining))


# === MEDIUM 2: RNG null boundary ===

func _test_processor_with_null_rng_returns_empty_no_mutation() -> void:
	print("[RNG-NULL] processor_with_null_rng_returns_empty_no_mutation")
	# Build a world with a real burn. Call process_tick with
	# rng=null. Expect: empty result, NO mutation of burn
	# (duration not decremented).
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	var c = w["world"].get_status_container(1)
	if c == null:
		c = w["world"].create_status_container(1)
	var inst = StatusInstanceScript.new(&"burn", 0, 1, 1, 3, 0)
	c.add(inst, "stackable", 99)
	var evs = PeriodicStatusProcessorScript.process_tick(
		w["world"], null, em)
	_assert(evs.size() == 0, "null rng -> empty event list")
	_assert(int(inst.remaining) == 3,
		"null rng: burn remaining UNCHANGED at 3 (no decrement; got %d)" % int(inst.remaining))
	_assert(c.has_status(&"burn"),
		"null rng: burn STILL in container (no expiry)")


func _test_processor_with_null_emitter_returns_empty_no_mutation() -> void:
	print("[EMITTER-NULL] processor_with_null_emitter_returns_empty_no_mutation")
	var w = _setup_world(100)
	var rng = w["rng"]
	var c = w["world"].get_status_container(1)
	if c == null:
		c = w["world"].create_status_container(1)
	var inst = StatusInstanceScript.new(&"burn", 0, 1, 1, 3, 0)
	c.add(inst, "stackable", 99)
	var evs = PeriodicStatusProcessorScript.process_tick(
		w["world"], rng, null)
	_assert(evs.size() == 0, "null emitter -> empty event list")
	_assert(int(inst.remaining) == 3,
		"null emitter: burn remaining UNCHANGED at 3 (got %d)" % int(inst.remaining))


# === MEDIUM 3: TRUE no-progress stalemate ===

func _test_baseline_no_progress_stalemate_termination() -> void:
	print("[STALE-REAL-1] baseline_no_progress_stalemate_termination")
	# True no-progress fixture: 1x4 grid (width=1, height=4).
	# Player spawn order: P0 at (0,0), P1 at (0,1).
	# Enemy spawn order: E0 at (0,3), E1 at (0,2).
	# Scheduler picks lowest-ID player (P0) and lowest-ID enemy
	# (E0). P0's nearest enemy is E1 at y=2 (dist 2), wants to
	# step y=1 (occupied by P1) -> can't move. E0's nearest
	# player is P1 at y=1 (dist 2), wants to step y=2
	# (occupied by E1) -> can't move. No progress for 2 ticks
	# -> TERMINATION_STALEMATE.
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p0 = B.new("p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var p1 = B.new("p1", &"warrior", 0, Vector2i(0, 1), 100, 100, 20, 5, 1)
	var e0 = B.new("e0", &"orc", 1, Vector2i(0, 3), 100, 100, 20, 5, 1)
	var e1 = B.new("e1", &"orc", 1, Vector2i(0, 2), 100, 100, 20, 5, 1)
	var s = S.new(42, [p0, p1], [e0, e1], 1, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(s)
	# Safety cap, but no set_max_ticks (per spec).
	var events = sim.run_until_done(20)
	var result = sim.get_result()
	if result == null:
		_assert(false, "result is null (simulation did not finish within 20 ticks)")
		return
	_assert(int(result.termination_reason) == int(BattleResultScript.TERMINATION_STALEMATE),
		"true stalemate: termination_reason=STALEMATE (got %d)" % int(result.termination_reason))
	_assert(int(result.winner_team) == -1,
		"true stalemate: winner_team=-1 (DRAW)")
	_assert(int(result.outcome) == int(BattleResultScript.OUTCOME_DRAW),
		"true stalemate: outcome=DRAW")
	# Sanity: no DAMAGE_APPLIED or UNIT_MOVED events.
	for e in events:
		_assert(int(e.type) != BattleEventTypeScript.DAMAGE_APPLIED,
			"no DAMAGE_APPLIED in true stalemate trace")
		_assert(int(e.type) != BattleEventTypeScript.UNIT_MOVED,
			"no UNIT_MOVED in true stalemate trace")


func _test_max_hp_regen_does_not_postpone_true_stalemate() -> void:
	print("[STALE-REAL-2] max_hp_regen_does_not_postpone_true_stalemate")
	# Same fixture, but apply real Regen to P1 at max HP.
	# Both units still can't move/attack -> true stalemate.
	# STATUS_TICKED must NOT count as progress, so the
	# termination reason + tick must match the baseline.
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p0 = B.new("p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var p1 = B.new("p1", &"warrior", 0, Vector2i(0, 1), 100, 100, 20, 5, 1)
	var e0 = B.new("e0", &"orc", 1, Vector2i(0, 3), 100, 100, 20, 5, 1)
	var e1 = B.new("e1", &"orc", 1, Vector2i(0, 2), 100, 100, 20, 5, 1)
	var s = S.new(42, [p0, p1], [e0, e1], 1, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(s)
	# Apply Regen to P1 at max HP via executor.
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 0, 0, -1, -1, 0)
	req.definition_id = &"regen"
	var ctx = EffectContextScript.new(sim.world(), sim.rng(),
		sim.emitter(), [])
	EffectExecutorScript.new().execute(ctx, req)
	var events = sim.run_until_done(20)
	var result = sim.get_result()
	if result == null:
		_assert(false, "result is null (simulation did not finish within 20 ticks)")
		return
	_assert(int(result.termination_reason) == int(BattleResultScript.TERMINATION_STALEMATE),
		"max-HP regen: termination_reason=STALEMATE (got %d)" % int(result.termination_reason))
	_assert(int(result.winner_team) == -1,
		"max-HP regen: winner_team=-1 (DRAW)")
	# STATUS_TICKED may exist but no HEAL_APPLIED (target is at
	# max HP, so actual heal = 0).
	var tick_count: int = 0
	var heal_count: int = 0
	for e in events:
		if int(e.type) == BattleEventTypeScript.STATUS_TICKED:
			tick_count += 1
		if int(e.type) == BattleEventTypeScript.HEAL_APPLIED:
			heal_count += 1
	_assert(tick_count > 0,
		"max-HP regen sim DOES emit STATUS_TICKED events")
	_assert(heal_count == 0,
		"max-HP regen emits 0 HEAL_APPLIED (HP already at max)")
	# Compare tick_count with baseline (both terminate at
	# STALEMATE so both should reach the same tick_count).
	var sim_base = BattleSimulationScript.new()
	sim_base.initialize(s)
	sim_base.run_until_done(20)
	var result_base = sim_base.get_result()
	if result_base != null:
		_assert(int(result_base.tick_count) == int(result.tick_count),
			"both sims terminate at same tick (baseline=%d regen=%d)" % [int(result_base.tick_count), int(result.tick_count)])


# === Helpers ===

func _setup_world(max_hp: int) -> Dictionary:
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), max_hp, max_hp, 20, 5, 1)
	var e1 = B.new("", &"orc", 1, Vector2i(0, 0), max_hp, max_hp, 20, 5, 1)
	var s = S.new(42, [p], [e1], 7, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(s)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var rng = DeterministicRngScript.new(0)
	return {"world": w, "emitter": em, "rng": rng}


func _setup_world_with_low_hp(entity_id: int, hp: int) -> Dictionary:
	var max_hp: int = 100
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), max_hp, max_hp, 20, 5, 1)
	var e1 = B.new("", &"orc", 1, Vector2i(0, 0), max_hp, max_hp, 20, 5, 1)
	var s = S.new(42, [p], [e1], 7, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(s)
	w.apply_damage(entity_id, max_hp - hp)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var rng = DeterministicRngScript.new(0)
	return {"world": w, "emitter": em, "rng": rng}


func _make_synthetic_def(p_id: StringName, p_interval: float,
		p_duration: int, p_dot_damage: int, p_dot_heal: int) -> Resource:
	var StatusDefScript = preload("res://core/data/status_def.gd")
	var s = StatusDefScript.new()
	s.id = p_id
	s.duration = float(p_duration)
	s.tick_interval = p_interval
	s.dot_damage = p_dot_damage
	s.dot_heal = p_dot_heal
	return s


func _inject_synthetic_def(def: Resource) -> void:
	# Inject into ContentDB's per-type effects map so
	# StatusDefResolver can find it. This is a TEST-ONLY
	# injection seam; no shipping content is mutated.
	var ContentDBScript = preload("res://core/utils/content_db.gd")
	ContentDBScript.ensure_loaded()
	var id: StringName = def.id
	# Inject into _by_id_by_type["effects"] (typed map).
	var typed: Dictionary = ContentDBScript._by_id_by_type.get("effects", {})
	typed[id] = def
	# Also inject into legacy _by_id for any consumer.
	if not ContentDBScript._by_id.has(id):
		ContentDBScript._by_id[id] = def


func _events_of_type(events: Array, type: int) -> Array:
	var out: Array = []
	for e in events:
		if int(e.type) == type:
			out.append(e)
	return out
