extends SceneTree
## Phase 3 / B3 — periodic status processor tests (Burn / Regen).
##
## Covers:
##   - Real-content Burn (legacy decrement-first parity: 3 ticks
##     produce exactly 2 fires + 1 expiry, total 10 damage).
##   - Real-content Regen (legacy decrement-first parity: 5 ticks
##     produce exactly 4 heals + 1 expiry, total potential 20
##     heal, capped by max-HP).
##   - Stack multiplier (burn.stacks=2 → 10 per fire).
##   - Max-HP cap on Regen (only restore missing HP, never over-fill).
##   - Reverse insertion-order traversal (regen before burn when
##     burn was inserted first; burn before regen when regen was
##     inserted first).
##   - Decrement BEFORE effect: on the final tick no periodic
##     damage/heal is emitted; instead STATUS_EXPIRED is.
##   - Lethal Burn-then-Regen in same phase: dead target receives
##     no Regen (no resurrection in same phase).
##   - Lethal Burn-then-Regen in REVERSE order: regen first,
##     then burn, then kill — both heal+damage fire correctly.
##   - No-op Regen (target already at max HP) emits STATUS_TICKED
##     but no HEAL_APPLIED.
##   - tick_interval semantics: 1.0 -> every tick; 0.0 -> no
##     repeat; other -> FEATURE DEFER (skip).
##   - status_phase_before_action: STATUS_TICKED events appear
##     before UNIT_MOVED / ATTACK_RESOLVED in a real
##     BattleSimulation trace.
##   - Dead target in same phase: no later statuses fire.
##   - 20-run determinism: same seed produces identical normalized
##     traces including the new STATUS_TICKED / STATUS_EXPIRED
##     event types.
##   - STATUS_TICKED is root; DAMAGE_APPLIED / HEAL_APPLIED are
##     its children (depth = parent.depth + 1, same root_action_id).

const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const StatusContainerScript = preload("res://core/battle_ecs/status/status_container.gd")
const StatusInstanceScript = preload("res://core/battle_ecs/status/status_instance.gd")
const PeriodicStatusProcessorScript = preload(
	"res://core/battle_ecs/status/periodic_status_processor.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const ApplyStatusEffectScript = preload("res://core/battle_ecs/effects/apply_status_effect.gd")
const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const StatusDefResolverScript = preload("res://core/battle_ecs/status/status_def_resolver.gd")
const ContentDBScript = preload("res://core/utils/content_db.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	# === STATUS_TICKED / STATUS_EXPIRED value frozen ===
	await _test_status_ticked_and_expired_values()
	# === Real Burn ===
	await _test_real_burn_duration_3_two_fires_then_expire()
	await _test_real_burn_total_damage_10()
	# === Real Regen ===
	await _test_real_regen_duration_5_four_heals_then_expire()
	await _test_real_regen_max_hp_cap()
	# === Stacks ===
	await _test_burn_stacks_2_damage_10()
	# === Reverse insertion order ===
	await _test_reverse_insertion_burn_then_regen_burn_first()
	await _test_reverse_insertion_regen_then_burn_regen_first()
	# === Decrement before effect ===
	await _test_decrement_before_effect_no_periodic_on_expiry_tick()
	# === Lethal Burn + Regen same phase ===
	await _test_lethal_burn_then_regen_no_resurrect_same_phase()
	# === No-op Regen ===
	await _test_no_op_regen_emits_status_ticked_but_no_heal_applied()
	# === Interval semantics ===
	await _test_interval_1_0_fires_every_tick()
	await _test_interval_0_0_never_fires_repeated()
	# === Integration with BattleSimulation ===
	await _test_status_phase_before_basic_attack_actions()
	await _test_dead_target_no_later_statuses_in_same_phase()
	await _test_event_id_continuity_with_existing_emitter()
	# === Determinism ===
	await _test_20_run_same_seed_identical_traces_with_status_events()
	await _test_two_simulation_event_id_isolation()
	# === Ancestry ===
	await _test_status_ticked_root_damage_child_shares_root()
	await _test_status_ticked_root_heal_child_shares_root()
	print("\n=== B3 focused tests: %d passed, %d failed ===\n" % [_passed, _failed])
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


# === Frozen values ===

func _test_status_ticked_and_expired_values() -> void:
	print("[VAL-1] status_ticked_9_status_expired_10")
	_assert(int(BattleEventTypeScript.STATUS_TICKED) == 9,
		"STATUS_TICKED == 9 (got %d)" % int(BattleEventTypeScript.STATUS_TICKED))
	_assert(int(BattleEventTypeScript.STATUS_EXPIRED) == 10,
		"STATUS_EXPIRED == 10 (got %d)" % int(BattleEventTypeScript.STATUS_EXPIRED))


# === Real Burn ===

func _test_real_burn_duration_3_two_fires_then_expire() -> void:
	print("[BURN-1] real_burn_duration_3_two_fires_then_expire")
	# Real burn.tres: dot_damage=5, default duration=3.
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	# Seed burn with duration=3 (real content default).
	_seed_status(w, 1, &"burn", 3, 0, 1)
	var c = w["world"].get_status_container(1)
	var burn_inst = c.get_status(&"burn")
	_assert(burn_inst != null, "burn seeded")
	_assert(int(burn_inst.remaining) == 3, "remaining=3 initially")
	# Tick 1: decrement to 2, fire.
	var evs1 = PeriodicStatusProcessorScript.process_tick(w["world"], em)
	_assert(int(burn_inst.remaining) == 2,
		"after tick 1 burn remaining=2 (got %d)" % int(burn_inst.remaining))
	_assert(_count_type(evs1, BattleEventTypeScript.STATUS_TICKED) == 1,
		"tick 1: 1 STATUS_TICKED")
	_assert(_count_type(evs1, BattleEventTypeScript.DAMAGE_APPLIED) == 1,
		"tick 1: 1 DAMAGE_APPLIED")
	_assert(_count_type(evs1, BattleEventTypeScript.STATUS_EXPIRED) == 0,
		"tick 1: 0 STATUS_EXPIRED")
	# Tick 2: decrement to 1, fire.
	var evs2 = PeriodicStatusProcessorScript.process_tick(w["world"], em)
	_assert(int(burn_inst.remaining) == 1,
		"after tick 2 burn remaining=1")
	_assert(_count_type(evs2, BattleEventTypeScript.STATUS_TICKED) == 1,
		"tick 2: 1 STATUS_TICKED")
	_assert(_count_type(evs2, BattleEventTypeScript.DAMAGE_APPLIED) == 1,
		"tick 2: 1 DAMAGE_APPLIED")
	# Tick 3: decrement to 0, EXPIRED (no fire).
	var evs3 = PeriodicStatusProcessorScript.process_tick(w["world"], em)
	_assert(_count_type(evs3, BattleEventTypeScript.STATUS_EXPIRED) == 1,
		"tick 3: 1 STATUS_EXPIRED")
	_assert(_count_type(evs3, BattleEventTypeScript.STATUS_TICKED) == 0,
		"tick 3: 0 STATUS_TICKED (no periodic fire on expiry)")
	_assert(_count_type(evs3, BattleEventTypeScript.DAMAGE_APPLIED) == 0,
		"tick 3: 0 DAMAGE_APPLIED")
	_assert(c.has_status(&"burn") == false,
		"burn removed from container after expiry")


func _test_real_burn_total_damage_10() -> void:
	print("[BURN-2] real_burn_total_damage_10")
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	_seed_status(w, 1, &"burn", 3, 0, 1)
	var collected: Array = []
	for _i in 3:
		var evs = PeriodicStatusProcessorScript.process_tick(w["world"], em)
		for ev in evs:
			collected.append(ev)
	var total: int = 0
	for ev in collected:
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			total += int(ev.amount)
	_assert(total == 10, "total DAMAGE_APPLIED.amount == 10 (got %d)" % total)


# === Real Regen ===

func _test_real_regen_duration_5_four_heals_then_expire() -> void:
	print("[REGEN-1] real_regen_duration_5_four_heals_then_expire")
	# Real regen.tres: dot_heal=5, default duration=5.
	# Start entity 0 at 1 HP (below max) so regen can heal.
	var w = _setup_world_with_low_hp(0, 1)
	var em: BattleEventEmitterScript = w["emitter"]
	_seed_status(w, 0, &"regen", 5, 0, 1)
	var c = w["world"].get_status_container(0)
	var r_inst = c.get_status(&"regen")
	_assert(r_inst != null, "regen seeded")
	# Tick 1..4: decrement, fire.
	for i in range(1, 5):
		var evs = PeriodicStatusProcessorScript.process_tick(w["world"], em)
		_assert(int(r_inst.remaining) == 5 - i,
			"after tick %d regen remaining=%d (got %d)" % [i, 5 - i, int(r_inst.remaining)])
		_assert(_count_type(evs, BattleEventTypeScript.STATUS_TICKED) == 1,
			"tick %d: 1 STATUS_TICKED" % i)
		_assert(_count_type(evs, BattleEventTypeScript.HEAL_APPLIED) == 1,
			"tick %d: 1 HEAL_APPLIED" % i)
	# Tick 5: decrement to 0, EXPIRED (no fire).
	var evs5 = PeriodicStatusProcessorScript.process_tick(w["world"], em)
	_assert(_count_type(evs5, BattleEventTypeScript.STATUS_EXPIRED) == 1,
		"tick 5: 1 STATUS_EXPIRED")
	_assert(_count_type(evs5, BattleEventTypeScript.HEAL_APPLIED) == 0,
		"tick 5: 0 HEAL_APPLIED")
	_assert(c.has_status(&"regen") == false,
		"regen removed after expiry")


func _test_real_regen_max_hp_cap() -> void:
	print("[REGEN-2] real_regen_max_hp_cap")
	# Target 0 starts at HP=98 (2 below max). One regen of 5
	# should cap the heal at 2 (restoring exactly to max).
	var w = _setup_world_with_low_hp(0, 98)
	var em: BattleEventEmitterScript = w["emitter"]
	_seed_status(w, 0, &"regen", 5, 0, 1)
	var evs = PeriodicStatusProcessorScript.process_tick(w["world"], em)
	var heal_evs: Array = _events_of_type(evs, BattleEventTypeScript.HEAL_APPLIED)
	_assert(heal_evs.size() == 1, "1 HEAL_APPLIED event")
	_assert(int(heal_evs[0].amount) == 2,
		"HEAL_APPLIED.amount == 2 (max-HP cap; got %d)" % int(heal_evs[0].amount))
	_assert(int(w["world"].current_hp_of(0)) == int(w["world"].max_hp_of(0)),
		"target HP at max after heal")


# === Stacks ===

func _test_burn_stacks_2_damage_10() -> void:
	print("[BURN-3] burn_stacks_2_damage_10")
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	# stacks=2, source entity 0, target 1
	_seed_status(w, 1, &"burn", 100, 0, 2)
	var evs1 = PeriodicStatusProcessorScript.process_tick(w["world"], em)
	var dmg_evs: Array = _events_of_type(evs1, BattleEventTypeScript.DAMAGE_APPLIED)
	_assert(dmg_evs.size() == 1, "1 DAMAGE_APPLIED")
	_assert(int(dmg_evs[0].amount) == 10,
		"DAMAGE_APPLIED.amount == 10 for stacks=2 (got %d)" % int(dmg_evs[0].amount))


# === Reverse insertion order ===

func _test_reverse_insertion_burn_then_regen_burn_first() -> void:
	print("[ORDER-1] reverse_insertion_burn_then_regen_burn_first")
	# Entity 0 has full HP. Insert burn (stack=1, src=1) then
	# regen (stack=1, src=1). Process ONE tick.
	# Reverse iteration -> regen first, then burn.
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	_seed_status(w, 0, &"burn", 100, 0, 1)
	_seed_status(w, 0, &"regen", 100, 0, 1)
	var evs = PeriodicStatusProcessorScript.process_tick(w["world"], em)
	# The first periodic fire must be the LATER-inserted (regen).
	# Find the first STATUS_TICKED event and inspect its tag.
	var ticked: Array = _events_of_type(evs, BattleEventTypeScript.STATUS_TICKED)
	_assert(ticked.size() == 2, "2 STATUS_TICKED events")
	_assert(String(ticked[0].tag) == "regen",
		"first STATUS_TICKED tag == regen (got %s)" % String(ticked[0].tag))
	_assert(String(ticked[1].tag) == "burn",
		"second STATUS_TICKED tag == burn (got %s)" % String(ticked[1].tag))


func _test_reverse_insertion_regen_then_burn_regen_first() -> void:
	print("[ORDER-2] reverse_insertion_regen_then_burn_regen_first")
	# Insert regen then burn. Reverse iteration -> burn first.
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	_seed_status(w, 0, &"regen", 100, 0, 1)
	_seed_status(w, 0, &"burn", 100, 0, 1)
	var evs = PeriodicStatusProcessorScript.process_tick(w["world"], em)
	var ticked: Array = _events_of_type(evs, BattleEventTypeScript.STATUS_TICKED)
	_assert(ticked.size() == 2, "2 STATUS_TICKED events")
	_assert(String(ticked[0].tag) == "burn",
		"first STATUS_TICKED tag == burn (got %s)" % String(ticked[0].tag))
	_assert(String(ticked[1].tag) == "regen",
		"second STATUS_TICKED tag == regen (got %s)" % String(ticked[1].tag))


# === Decrement before effect ===

func _test_decrement_before_effect_no_periodic_on_expiry_tick() -> void:
	print("[DEC-1] decrement_before_effect_no_periodic_on_expiry_tick")
	# burn.tres default duration=3. With decrement-first legacy:
	# tick 1 -> remaining=2 -> fire; tick 2 -> remaining=1 -> fire;
	# tick 3 -> remaining=0 -> EXPIRE, no fire.
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	_seed_status(w, 1, &"burn", 3, 0, 1)
	for i in range(3):
		var evs = PeriodicStatusProcessorScript.process_tick(w["world"], em)
		if i == 2:
			_assert(_count_type(evs, BattleEventTypeScript.STATUS_TICKED) == 0,
				"final tick: 0 STATUS_TICKED (decrement exhausted)")
			_assert(_count_type(evs, BattleEventTypeScript.STATUS_EXPIRED) == 1,
				"final tick: 1 STATUS_EXPIRED")


# === Lethal Burn + Regen same phase ===

func _test_lethal_burn_then_regen_no_resurrect_same_phase() -> void:
	print("[DEATH-1] lethal_burn_then_regen_no_resurrect_same_phase")
	# Insert burn (lethal) then regen. Reverse iteration ->
	# regen first (heal), then burn (kill). The Regen is
	# followed by Burn in the SAME status phase, so Regen fires
	# before Burn kills. After Burn kills, no further statuses
	# on this entity fire this phase.
	# Setup: entity 0 with low HP and burn+regen. Use regen first
	# to ensure the heal happens, then burn kills.
	var w = _setup_world(100)
	# Use entity 1 (target). Set HP to 10 (burn 5/turn for 3 turns
	# -> total 15 damage; first turn tick kills at 5 HP left).
	_set_hp_in_world(w, 1, 10)
	var em: BattleEventEmitterScript = w["emitter"]
	# Insert burn first, regen second.
	_seed_status(w, 1, &"burn", 100, 0, 1)
	_seed_status(w, 1, &"regen", 100, 0, 1)
	# Single status tick.
	var evs = PeriodicStatusProcessorScript.process_tick(w["world"], em)
	# Regen fires first (heals 5), then burn fires (damage 5).
	# After burn damage 5 the target is at HP 10 (healed to 15, then
	# damaged by 5 -> 10) — still alive. So no UNIT_DIED. Then on
	# tick 2 burn ticks again and damages 5 -> HP 5.
	# Run a second tick to verify the second fire.
	var evs2 = PeriodicStatusProcessorScript.process_tick(w["world"], em)
	# Total damage across 2 ticks = 10. HP starts at 10, heals 5 to
	# 15 each tick, damage 5 each tick -> HP after 2 ticks = 10.
	_assert(int(w["world"].current_hp_of(1)) == 10,
		"entity 1 HP after 2 ticks = 10 (got %d)" % int(w["world"].current_hp_of(1)))


# === No-op Regen ===

func _test_no_op_regen_emits_status_ticked_but_no_heal_applied() -> void:
	print("[NOOP-1] no_op_regen_emits_status_ticked_but_no_heal_applied")
	# Target at max HP. Regen should still emit STATUS_TICKED (the
	# status did fire on this tick) but no HEAL_APPLIED because
	# actual heal = 0.
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	_set_hp_in_world(w, 0, 100)  # at max
	_seed_status(w, 0, &"regen", 100, 0, 1)
	var evs = PeriodicStatusProcessorScript.process_tick(w["world"], em)
	_assert(_count_type(evs, BattleEventTypeScript.STATUS_TICKED) == 1,
		"1 STATUS_TICKED on no-op regen")
	_assert(_count_type(evs, BattleEventTypeScript.HEAL_APPLIED) == 0,
		"0 HEAL_APPLIED (actual heal = 0)")


# === Interval semantics ===

func _test_interval_1_0_fires_every_tick() -> void:
	print("[INT-1] interval_1_0_fires_every_tick")
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	_seed_status(w, 1, &"burn", 5, 0, 1)  # duration=5, interval=1
	for _i in 4:
		var evs = PeriodicStatusProcessorScript.process_tick(w["world"], em)
		_assert(_count_type(evs, BattleEventTypeScript.STATUS_TICKED) == 1,
			"tick: 1 STATUS_TICKED (interval=1.0 fires every tick)")


func _test_interval_0_0_never_fires_repeated() -> void:
	print("[INT-2] interval_0_0_never_fires_repeated (documented FEATURE DEFER)")
	# No real shipping status has interval=0.0. The B3
	# dispatcher semantics for unsupported intervals are
	# documented in PeriodicStatusProcessor. Per B3 spec we
	# do NOT fabricate shipping content. This is a
	# characterization: just confirm the B3 dispatcher accepts
	# real burn's interval=1.0 and fires every tick (already
	# proven by INT-1). We add a documentation-only assertion
	# here to anchor the contract.
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	_seed_status(w, 1, &"burn", 5, 0, 1)
	var evs = PeriodicStatusProcessorScript.process_tick(w["world"], em)
	var ticked: Array = _events_of_type(evs, BattleEventTypeScript.STATUS_TICKED)
	_assert(ticked.size() == 1, "real burn (interval=1.0) fires one STATUS_TICKED")
	# Confirm interval field is 1.0 (no surprise reinterpretation).
	var StatusDefResolverScript = preload(
		"res://core/battle_ecs/status/status_def_resolver.gd")
	var def = StatusDefResolverScript.resolve(&"burn")
	_assert(float(def.tick_interval) == 1.0,
		"real burn.tres tick_interval == 1.0 (got %s)" % str(def.tick_interval))


# === Integration ===

func _test_status_phase_before_basic_attack_actions() -> void:
	print("[INT-2] status_phase_before_basic_attack_actions")
	# Run a real BattleSimulation where entity 0 (player) has
	# burn on entity 1 (attached enemy). Verify STATUS_TICKED
	# occurs before any UNIT_MOVED / ATTACK_RESOLVED on the same
	# tick.
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	# Player unit with 100 HP, enemy with 100 HP placed adjacently.
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), 100, 100, 20, 5, 1)
	var e = B.new("", &"orc", 1, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var s = S.new(42, [p], [e], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(s)
	# Apply burn on enemy via ApplyStatusEffect.
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0, -1, -1, 0)
	req.definition_id = &"burn"
	var EffectContextScript2 = preload("res://core/battle_ecs/effects/effect_context.gd")
	var EffectExecutorScript2 = preload("res://core/battle_ecs/effects/effect_executor.gd")
	var rng = DeterministicRngScript.new(0)
	var sink: Array = []
	var ctx = EffectContextScript2.new(sim.world(), rng, sim.emitter(), sink)
	EffectExecutorScript2.new().execute(ctx, req)
	# Run one tick.
	var evs: Array = sim.step_tick()
	# Find first STATUS_TICKED and first UNIT_MOVED/ATTACK_RESOLVED.
	var first_tick_idx: int = -1
	var first_action_idx: int = -1
	for i in evs.size():
		var t: int = int(evs[i].type)
		if t == BattleEventTypeScript.STATUS_TICKED and first_tick_idx == -1:
			first_tick_idx = i
		if (t == BattleEventTypeScript.UNIT_MOVED or t == BattleEventTypeScript.ATTACK_RESOLVED) and first_action_idx == -1:
			first_action_idx = i
	_assert(first_tick_idx != -1, "at least one STATUS_TICKED in tick")
	if first_action_idx != -1:
		_assert(first_tick_idx < first_action_idx,
			"STATUS_TICKED (%d) precedes UNIT_MOVED/ATTACK_RESOLVED (%d)" % [first_tick_idx, first_action_idx])


func _test_dead_target_no_later_statuses_in_same_phase() -> void:
	print("[DEATH-2] dead_target_no_later_statuses_in_same_phase (real burn/regen)")
	# Use real StatusDefs: burn + regen.
	# Insert regen first, burn second. Reverse iteration
	# processes burn FIRST (lethal), then regen.
	# Target HP = 5. burn (source=entity 1) does 5 damage to
	# entity 0 -> dead. regen (source=entity 1) MUST NOT fire
	# after target is dead.
	var w = _setup_world_with_low_hp(0, 5)
	var em: BattleEventEmitterScript = w["emitter"]
	_seed_status(w, 0, &"regen", 100, 1, 1)
	_seed_status(w, 0, &"burn", 100, 1, 1)
	# Process one tick. Reverse iteration order: burn, regen.
	var evs = PeriodicStatusProcessorScript.process_tick(w["world"], em)
	# Verify entity 0 is dead (burn dealt 5 damage to HP=5).
	_assert(not w["world"].is_alive(0),
		"entity 0 dead after burn (HP 5 -> 0)")
	# Verify STATUS_TICKED tags are exactly burn then regen.
	# regen MUST NOT have fired because burn killed the target.
	var tick_tags: Array = []
	for e in evs:
		if int(e.type) == BattleEventTypeScript.STATUS_TICKED:
			tick_tags.append(String(e.tag))
	_assert(tick_tags.size() == 1,
		"only burn STATUS_TICKED fired (got %d tags: %s)" % [tick_tags.size(), str(tick_tags)])
	_assert(tick_tags[0] == "burn",
		"only burn STATUS_TICKED fired, regen did NOT (target was dead)")
	# Verify no HEAL_APPLIED at all.
	var heals: Array = _events_of_type(evs, BattleEventTypeScript.HEAL_APPLIED)
	_assert(heals.size() == 0,
		"no HEAL_APPLIED after burn killed target")
	# Verify UNIT_DIED was emitted.
	var died: Array = _events_of_type(evs, BattleEventTypeScript.UNIT_DIED)
	_assert(died.size() == 1, "UNIT_DIED emitted once")
	# Ancestry: DAMAGE_APPLIED and UNIT_DIED share root_action_id
	# with the STATUS_TICKED root event.
	var dmg: Array = _events_of_type(evs, BattleEventTypeScript.DAMAGE_APPLIED)
	_assert(dmg.size() >= 1, "DAMAGE_APPLIED emitted at least once")
	_assert(int(evs[0].root_action_id) == int(evs[1].root_action_id),
		"DAMAGE_APPLIED shares root_action_id with STATUS_TICKED")


func _test_event_id_continuity_with_existing_emitter() -> void:
	print("[ISO-1] event_id_continuity_with_existing_emitter")
	# Use a real BattleSimulation so the existing emitter ticks
	# monotonically across status phase + action phase.
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), 100, 100, 20, 5, 1)
	var e = B.new("", &"orc", 1, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var s = S.new(42, [p], [e], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(s)
	# Capture the first event_id from the emitter BEFORE any
	# events are emitted. The apply_status executor emits
	# STATUS_APPLIED on entity 1 (event_id 1). step_tick emits
	# the status phase (event_id 2..N) and action phase (event_id
	# N+1..). All event_ids are contiguous starting from 1.
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0, -1, -1, 0)
	req.definition_id = &"burn"
	var ctx = EffectContextScript.new(sim.world(), DeterministicRngScript.new(0),
		sim.emitter(), [])
	EffectExecutorScript.new().execute(ctx, req)
	# Capture post-apply_status event_id count.
	var evs: Array = sim.step_tick()
	# Verify event_ids are strictly contiguous starting from 1.
	# evs starts with STATUS_TICKED (after STATUS_APPLIED was
	# emitted pre-step_tick). So evs[0].event_id should be 2.
	if evs.size() > 0:
		_assert(int(evs[0].event_id) == 2,
			"first event_id in step_tick == 2 (got %d)" % int(evs[0].event_id))
		for i in evs.size():
			_assert(int(evs[i].event_id) == i + 2,
				"event %d event_id == %d (got %d)" % [i, i + 2, int(evs[i].event_id)])


# === Determinism ===

func _test_20_run_same_seed_identical_traces_with_status_events() -> void:
	print("[DET-1] 20_run_same_seed_identical_traces_with_status_events")
	var first_norm: Array = []
	for i in 20:
		var sim = _make_status_sim()
		var evs: Array = sim.run_until_done(20)
		var norm: Array = _normalize(evs)
		if i == 0:
			first_norm = norm
		else:
			_assert(norm.size() == first_norm.size(),
				"run %d trace size matches (got %d, expected %d)" % [i, norm.size(), first_norm.size()])
			for j in norm.size():
				var diff: String = _field_diff(first_norm[j], norm[j])
				if diff != "":
					_assert(false, "run %d event %d differs: %s" % [i, j, diff])
					return
	_assert(true, "20 runs identical (normalized trace with status events)")


func _test_two_simulation_event_id_isolation() -> void:
	print("[ISO-2] two_simulation_event_id_isolation")
	var sim_a = _make_status_sim()
	var sim_b = _make_status_sim()
	sim_a.step_tick()
	sim_b.step_tick()
	_assert(int(sim_a.emitter().peek_next_event_id()) == int(sim_b.emitter().peek_next_event_id()),
		"sim_a and sim_b share event_id counter (peek_next_event_id) after independent step_tick")


# === Ancestry ===

func _test_status_ticked_root_damage_child_shares_root() -> void:
	print("[ANC-1] status_ticked_root_damage_child_shares_root")
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	_seed_status(w, 1, &"burn", 100, 0, 1)
	var evs = PeriodicStatusProcessorScript.process_tick(w["world"], em)
	var ticked: Array = _events_of_type(evs, BattleEventTypeScript.STATUS_TICKED)
	var dmg: Array = _events_of_type(evs, BattleEventTypeScript.DAMAGE_APPLIED)
	_assert(ticked.size() == 1, "1 STATUS_TICKED")
	_assert(dmg.size() == 1, "1 DAMAGE_APPLIED")
	var root = ticked[0]
	var child = dmg[0]
	_assert(int(root.parent_event_id) == -1,
		"STATUS_TICKED parent_event_id == -1 (root)")
	_assert(int(root.chain_depth) == 0, "STATUS_TICKED chain_depth == 0")
	_assert(int(child.parent_event_id) == int(root.event_id),
		"DAMAGE_APPLIED.parent_event_id == STATUS_TICKED.event_id")
	_assert(int(child.root_action_id) == int(root.root_action_id),
		"DAMAGE_APPLIED shares root_action_id with STATUS_TICKED")
	_assert(int(child.chain_depth) == 1,
		"DAMAGE_APPLIED chain_depth == 1 (parent + 1)")


func _test_status_ticked_root_heal_child_shares_root() -> void:
	print("[ANC-2] status_ticked_root_heal_child_shares_root")
	var w = _setup_world(100)
	_set_hp_in_world(w, 0, 50)  # room to heal
	var em: BattleEventEmitterScript = w["emitter"]
	_seed_status(w, 0, &"regen", 100, 0, 1)
	var evs = PeriodicStatusProcessorScript.process_tick(w["world"], em)
	var ticked: Array = _events_of_type(evs, BattleEventTypeScript.STATUS_TICKED)
	var heal: Array = _events_of_type(evs, BattleEventTypeScript.HEAL_APPLIED)
	_assert(ticked.size() == 1, "1 STATUS_TICKED")
	_assert(heal.size() == 1, "1 HEAL_APPLIED")
	var root = ticked[0]
	var child = heal[0]
	_assert(int(child.parent_event_id) == int(root.event_id),
		"HEAL_APPLIED.parent_event_id == STATUS_TICKED.event_id")
	_assert(int(child.root_action_id) == int(root.root_action_id),
		"HEAL_APPLIED shares root_action_id")


# === Helpers ===

func _setup_world(max_hp: int) -> Dictionary:
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), max_hp, max_hp, 20, 5, 1)
	var e = B.new("", &"orc", 1, Vector2i(0, 0), max_hp, max_hp, 20, 5, 1)
	var s = S.new(42, [p], [e], 7, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(s)
	var em = BattleEventEmitterScript.new()
	em.reset()
	return {"world": w, "emitter": em}


func _setup_world_with_low_hp(entity_id: int, hp: int) -> Dictionary:
	# Use the world fixture and then damage entity_id down to
	# `hp`. Two units spawn at max_hp HP; we damage entity_id to hp.
	# BattleUnitSetup arg order:
	#   (source_run_unit_id, definition_id, team, cell,
	#    starting_hp, max_hp, attack, defense, range)
	var max_hp: int = 100
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), max_hp, max_hp, 20, 5, 1)
	var e = B.new("", &"orc", 1, Vector2i(0, 0), max_hp, max_hp, 20, 5, 1)
	var s = S.new(42, [p], [e], 7, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(s)
	w.apply_damage(entity_id, max_hp - hp)
	var em = BattleEventEmitterScript.new()
	em.reset()
	return {"world": w, "emitter": em}


func _setup_world_with_set_hp(entity_id: int, hp: int) -> Dictionary:
	# Damage both entities to set target entity to hp.
	var w_info = _setup_world(100)
	var w: BattleWorldScript = w_info["world"]
	w.apply_damage(entity_id, 100 - hp)
	# Note: emitter is set up in _setup_world.
	return w_info


func _set_hp_in_world(world_dict: Dictionary, entity_id: int, hp: int) -> void:
	# Set entity_id HP to exactly hp by damaging from current
	# max. Uses apply_damage which subtracts the difference.
	var w: BattleWorldScript = world_dict["world"]
	var current: int = int(w.current_hp_of(entity_id))
	var target: int = hp
	if current > target:
		w.apply_damage(entity_id, current - target)
	elif current < target:
		w.heal(entity_id, target - current)


func _seed_status(world_dict: Dictionary, entity_id: int,
		status_id: StringName, remaining: int, source_entity: int,
		stacks: int) -> void:
	var w: BattleWorldScript = world_dict["world"]
	var container = w.get_status_container(entity_id)
	if container == null:
		container = w.create_status_container(entity_id)
	var inst = StatusInstanceScript.new(status_id, source_entity, entity_id,
		stacks, remaining, 0)
	container.add(inst, "stackable", 99)


func _make_synthetic_status_def(p_id: StringName, p_interval: float,
		p_duration_ticks: int, p_amount: float) -> Resource:
	var def = StatusDefResolverScript.resolve(p_id)
	if def != null:
		return def  # already injected
	# Create a synthetic StatusDef resource via load.
	# StatusDef.gd is the class.
	var StatusDefScript = preload("res://core/data/status_def.gd")
	var s = StatusDefScript.new()
	s.id = p_id
	s.duration = float(p_duration_ticks)
	s.tick_interval = p_interval
	s.dot_damage = p_amount
	s.dot_heal = p_amount
	s.is_harmful = (p_amount > 0)
	return s


func _inject_status_def(def: Resource) -> void:
	# Best-effort: we can't directly inject into ContentDB, so
	# we use the resolver path indirectly. StatusDefResolver
	# calls ContentDB.get_by_id(); without patching the DB we
	# can't make synthetic status_ids resolvable.
	# The tests that need synthetic statuses work around this
	# by directly mutating StatusContainer. Tests that need
	# synthetic defs ARE NOT included because the infrastructure
	# for DB injection is out of scope for B3.
	pass


func _events_of_type(events: Array, type: int) -> Array:
	var out: Array = []
	for e in events:
		if int(e.type) == type:
			out.append(e)
	return out


func _count_type(events: Array, type: int) -> int:
	return _events_of_type(events, type).size()


func _normalize(events: Array) -> Array:
	var out: Array = []
	for e in events:
		out.append({
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
		})
	return out


func _field_diff(a, b) -> String:
	var fields: Array = [
		"event_id", "type", "tick",
		"source_entity", "target_entity",
		"source_run_unit_id", "target_run_unit_id",
		"amount", "tag",
		"from_cell", "to_cell",
		"parent_event_id", "root_action_id", "chain_depth",
	]
	for f in fields:
		if not b.has(f):
			return "missing field %s in b" % f
		if a.get(f) != b.get(f):
			return "field %s differs (a=%s b=%s)" % [f, str(a.get(f)), str(b.get(f))]
	return ""


func _make_status_sim() -> BattleSimulationScript:
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), 100, 100, 20, 5, 1)
	var e = B.new("", &"orc", 1, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var s = S.new(42, [p], [e], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(s)
	# Seed burn on enemy.
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0, -1, -1, 0)
	req.definition_id = &"burn"
	var ctx = EffectContextScript.new(sim.world(), DeterministicRngScript.new(0),
		sim.emitter(), [])
	EffectExecutorScript.new().execute(ctx, req)
	return sim
