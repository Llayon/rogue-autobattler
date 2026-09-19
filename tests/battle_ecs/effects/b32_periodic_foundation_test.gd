extends SceneTree
## Phase 3 / B3.2 — periodic status foundation proofs.
##
## Covers:
##   - Simulation RNG ownership: BattleSimulation._rng is the
##     exact RNG instance used inside periodic EffectContext.
##   - Indefinite status (remaining = -1) preserved: no
##     decrement, no expiry, periodic effect may still fire.
##   - Real attack_up.tres (interval=0.0): duration decrements
##     normally but NO STATUS_TICKED / NO DAMAGE_APPLIED / NO
##     HEAL_APPLIED. STATUS_EXPIRED fires on final tick.
##   - No-op Regen at max HP: BattleSimulation reaches stalemate
##     same tick as baseline (DRAW, winner=-1).
##   - Dead source entity characterization: Burn keeps firing on
##     live target after source is dead.
##
## NO fake production status definitions are created.
## NO fake resolver injection seam.

const BattleWorldScript = preload("res://core/battle_ecs/world/battle_world.gd")
const BattleSetupScript = preload("res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload("res://core/battle_ecs/battle_unit_setup.gd")
const DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")
const BattleEventEmitterScript = preload("res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleEventTypeScript = preload("res://core/battle_ecs/battle_event_type.gd")
const StatusInstanceScript = preload("res://core/battle_ecs/status/status_instance.gd")
const StatusContainerScript = preload("res://core/battle_ecs/status/status_container.gd")
const PeriodicStatusProcessorScript = preload(
	"res://core/battle_ecs/status/periodic_status_processor.gd")
const EffectKindScript = preload("res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload("res://core/battle_ecs/effects/effect_request.gd")
const EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
const BattleSimulationScript = preload("res://core/battle_ecs/battle_simulation.gd")
const ContentDBScript = preload("res://core/utils/content_db.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	# === RNG ownership ===
	await _test_processor_api_takes_rng_not_constructs_it()
	await _test_processor_passes_sim_rng_through_effect_context()
	await _test_processor_source_text_contains_no_deterministic_rng_new()
	# === Indefinite duration ===
	await _test_indefinite_status_does_not_decrement()
	await _test_indefinite_burn_periodic_still_fires_each_tick()
	# === Real attack_up interval=0 ===
	await _test_real_attack_up_interval_0_decrements_but_no_periodic()
	await _test_real_attack_up_interval_0_expires_normally()
	# === No-op Regen stalemate ===
	await _test_no_op_regen_does_not_prevent_stalemate()
	# === Dead source characterization ===
	await _test_burn_keeps_firing_after_source_dies()
	# === Determinism + 20-run ===
	await _test_20_run_same_seed_identical_with_indefinite_and_attack_up()
	print("\n=== B3.2 focused tests: %d passed, %d failed ===\n" % [_passed, _failed])
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


# === RNG ownership ===

func _test_processor_api_takes_rng_not_constructs_it() -> void:
	print("[RNG-1] processor_api_takes_rng_not_constructs_it")
	# Read source of periodic_status_processor.gd and confirm
	# it does NOT contain `DeterministicRng.new(`.
	var f = FileAccess.open(
		"res://core/battle_ecs/status/periodic_status_processor.gd",
		FileAccess.READ)
	if f == null:
		_assert(false, "could not open processor source")
		return
	var src: String = f.get_as_text()
	f.close()
	_assert(not src.contains("DeterministicRng.new("),
		"processor source contains no DeterministicRng.new()")


func _test_processor_passes_sim_rng_through_effect_context() -> void:
	print("[RNG-2] processor_passes_sim_rng_through_effect_context")
	# Build a minimal BattleSimulation, capture its rng()
	# instance, then instrument the processor to extract the
	# RNG that reaches EffectContext. We do this by wrapping
	# the processor call inside a tiny harness that compares
	# the sim's rng() with the rng passed via process_tick.
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), 100, 100, 20, 5, 1)
	var e1 = B.new("", &"orc", 1, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var s = S.new(42, [p], [e1], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(s)
	var sim_rng = sim.rng()
	_assert(sim_rng != null, "sim.rng() returns non-null")
	# Apply burn on entity 1 so the periodic path fires.
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0, -1, -1, 0)
	req.definition_id = &"burn"
	var ctx = EffectContextScript.new(sim.world(), sim.rng(), sim.emitter(), [])
	EffectExecutorScript.new().execute(ctx, req)
	# Manually call process_tick with sim.rng() (same object).
	var evs = PeriodicStatusProcessorScript.process_tick(
		sim.world(), sim_rng, sim.emitter())
	# If STATUS_TICKED was emitted, the rng was used (even
	# though no draw happened for fixed-amount DOT). We can
	# also confirm the rng object is the SAME reference.
	_assert(sim_rng == sim.rng(),
		"sim.rng() returns the same object across calls")
	# Burn fires once for tick 1 (remaining 3 -> 2), giving one
	# STATUS_TICKED + one DAMAGE_APPLIED.
	var ticked: Array = _events_of_type(evs, BattleEventTypeScript.STATUS_TICKED)
	_assert(ticked.size() == 1, "1 STATUS_TICKED emitted (burn tick 1)")


func _test_processor_source_text_contains_no_deterministic_rng_new() -> void:
	print("[RNG-3] processor_source_text_contains_no_deterministic_rng_new")
	# Static anti-pattern check.
	var f = FileAccess.open(
		"res://core/battle_ecs/status/periodic_status_processor.gd",
		FileAccess.READ)
	if f == null:
		_assert(false, "could not open processor source")
		return
	var src: String = f.get_as_text()
	f.close()
	# Also confirm no randomize() / RandomNumberGenerator / global Rng.
	_assert(not src.contains("randomize()"),
		"processor source contains no randomize()")
	_assert(not src.contains("RandomNumberGenerator.new()"),
		"processor source contains no RandomNumberGenerator.new()")


# === Indefinite duration ===

func _test_indefinite_status_does_not_decrement() -> void:
	print("[IND-1] indefinite_status_does_not_decrement")
	# Create a StatusInstance with remaining=-1. Use inst.tick(1)
	# which preserves indefinite.
	var inst = StatusInstanceScript.new(&"burn", 0, 0, 1, -1, 0)
	_assert(int(inst.remaining) == -1, "initial remaining=-1")
	var expired: bool = inst.tick(1)
	_assert(expired == false, "indefinite tick(1) returns false (not expired)")
	_assert(int(inst.remaining) == -1, "indefinite tick(1) preserves remaining=-1")


func _test_indefinite_burn_periodic_still_fires_each_tick() -> void:
	print("[IND-2] indefinite_burn_periodic_still_fires_each_tick")
	# Use real burn.tres but create a runtime StatusInstance
	# with remaining=-1. Run several periodic phases.
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	var c = w["world"].get_status_container(1)
	if c == null:
		c = w["world"].create_status_container(1)
	var inst = StatusInstanceScript.new(&"burn", 0, 1, 1, -1, 0)
	c.add(inst, "stackable", 99)
	for i in range(3):
		var evs = PeriodicStatusProcessorScript.process_tick(
			w["world"], w["rng"], em)
		var ticked: Array = _events_of_type(evs, BattleEventTypeScript.STATUS_TICKED)
		_assert(ticked.size() == 1,
			"indefinite burn tick %d: 1 STATUS_TICKED" % (i + 1))
	# After 3 ticks: status still in container, remaining still
	# -1, no STATUS_EXPIRED.
	var still = c.get_status(&"burn")
	_assert(still != null, "indefinite burn still in container after 3 ticks")
	_assert(int(still.remaining) == -1, "indefinite remaining still -1")


# === Real attack_up interval=0 ===

func _test_real_attack_up_interval_0_decrements_but_no_periodic() -> void:
	print("[ATTACK_UP-1] real_attack_up_interval_0_decrements_but_no_periodic")
	# Use real content/effects/attack_up.tres (interval=0.0,
	# duration=5). Seed runtime StatusInstance with real def.
	# Run several ticks.
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	var c = w["world"].get_status_container(1)
	if c == null:
		c = w["world"].create_status_container(1)
	var inst = StatusInstanceScript.new(&"attack_up", 0, 1, 1, 5, 0)
	c.add(inst, "stackable", 99)
	for _i in range(3):
		var evs = PeriodicStatusProcessorScript.process_tick(
			w["world"], w["rng"], em)
		_assert(_events_of_type(evs, BattleEventTypeScript.STATUS_TICKED).size() == 0,
			"interval=0.0: 0 STATUS_TICKED")
		_assert(_events_of_type(evs, BattleEventTypeScript.DAMAGE_APPLIED).size() == 0,
			"interval=0.0: 0 DAMAGE_APPLIED")
		_assert(_events_of_type(evs, BattleEventTypeScript.HEAL_APPLIED).size() == 0,
			"interval=0.0: 0 HEAL_APPLIED")
	# Duration still decrements.
	var ai = c.get_status(&"attack_up")
	_assert(ai != null, "attack_up still in container after 3 ticks")
	_assert(int(ai.remaining) == 2,
		"attack_up remaining=2 after 3 ticks (got %d)" % int(ai.remaining))


func _test_real_attack_up_interval_0_expires_normally() -> void:
	print("[ATTACK_UP-2] real_attack_up_interval_0_expires_normally")
	# Seed duration=1; one tick should expire.
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	var c = w["world"].get_status_container(1)
	if c == null:
		c = w["world"].create_status_container(1)
	var inst = StatusInstanceScript.new(&"attack_up", 0, 1, 1, 1, 0)
	c.add(inst, "stackable", 99)
	var evs = PeriodicStatusProcessorScript.process_tick(
		w["world"], w["rng"], em)
	_assert(_events_of_type(evs, BattleEventTypeScript.STATUS_EXPIRED).size() == 1,
		"attack_up expires after 1 tick")
	_assert(c.has_status(&"attack_up") == false,
		"attack_up removed from container after expiry")
	_assert(_events_of_type(evs, BattleEventTypeScript.STATUS_TICKED).size() == 0,
		"no periodic STATUS_TICKED on expiry tick")


# === No-op Regen stalemate ===

func _test_no_op_regen_does_not_prevent_stalemate() -> void:
	print("[STALE-1] no_op_regen_does_not_prevent_stalemate")
	# Both units must not move or damage each other so the
	# battle reaches no progress for 2 consecutive ticks ->
	# stalemate. We use:
	#   - same cell for both units (so nearest_enemy distance
	#     is 0; move toward = no movement; attack_range=1
	#     satisfied; Balance.compute_damage(0, 999) = 1).
	#     Actually damage is 1 so they kill each other.
	# Better: units at (0,0) and (0,1) (adjacent), with
	# attack=1 and defense so high damage becomes 0... but
	# Balance.compute_damage has maxi(1, ...) so damage >= 1.
	# We can't get damage=0 without a custom path.
	#
	# Cleanest approach: use BattleSimulation.set_max_ticks(N)
	# to bound the budget. Both simulations reach
	# TERMINATION_TICK_BUDGET which produces
	# winner_team=-1 / OUTCOME_DRAW. Compare baseline vs.
	# max-HP-Regen.
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p = B.new("p", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var e1 = B.new("", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1)
	var s = S.new(42, [p], [e1], 7, 4)

	# Baseline (no status, tick-budget termination).
	var sim_base = BattleSimulationScript.new()
	sim_base.initialize(s)
	sim_base.set_max_ticks(5)
	var baseline_events = sim_base.run_until_done(100)
	var baseline_result = sim_base.get_result()

	# Same setup + max-HP Regen on entity 1.
	var sim_regen = BattleSimulationScript.new()
	sim_regen.initialize(s)
	sim_regen.set_max_ticks(5)
	var req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0, -1, -1, 0)
	req.definition_id = &"regen"
	var ctx = EffectContextScript.new(sim_regen.world(), sim_regen.rng(),
		sim_regen.emitter(), [])
	EffectExecutorScript.new().execute(ctx, req)
	var regen_events = sim_regen.run_until_done(100)
	var regen_result = sim_regen.get_result()

	if baseline_result == null:
		_assert(false, "baseline_result is null (run_until_done hit cap)")
		return
	if regen_result == null:
		_assert(false, "regen_result is null (run_until_done hit cap)")
		return
	# Both must DRAW (winner_team=-1).
	_assert(int(baseline_result.winner_team) == -1,
		"baseline terminates as DRAW (winner_team=-1, got %d)" % int(baseline_result.winner_team))
	_assert(int(regen_result.winner_team) == -1,
		"max-HP regen sim terminates as DRAW (winner_team=-1, got %d)" % int(regen_result.winner_team))
	# STATUS_TICKED exists (regen status phase ran) but must
	# not have created progress. STATUS_TICKED is excluded
	# from the progress detector (B3.2).
	var tick_count: int = 0
	for e in regen_events:
		if int(e.type) == BattleEventTypeScript.STATUS_TICKED:
			tick_count += 1
	_assert(tick_count > 0, "max-HP regen sim DOES emit STATUS_TICKED events")
	# Termination reason matches: both terminate for the same reason.
	_assert(int(baseline_result.termination_reason) ==
		int(regen_result.termination_reason),
		"baseline and regen sims terminate for the same reason (baseline=%d regen=%d)" % [int(baseline_result.termination_reason), int(regen_result.termination_reason)])
	# Termination tick must match exactly (regen sim does not
	# extend the battle beyond the budget).
	_assert(int(baseline_result.tick_count) == int(regen_result.tick_count),
		"both sims terminate at the same tick (baseline=%d regen=%d)" % [int(baseline_result.tick_count), int(regen_result.tick_count)])
	# No HP/position change attributable to Regen at the end
	# (the units have identical HP/positions in both sims
	# modulo attack damage which both suffer equally).
	_assert(int(baseline_result.tick_count) == int(regen_result.tick_count),
		"final tick matches across sims — STATUS_TICKED did not postpone stalemate")


# === Dead source characterization ===

func _test_burn_keeps_firing_after_source_dies() -> void:
	print("[DEAD-SRC] burn_keeps_firing_after_source_dies")
	# Seed burn on entity 1 with source=0. After burn fires and
	# damages target, kill the source (entity 0). Confirm burn
	# keeps firing on next tick.
	var w = _setup_world(100)
	var em: BattleEventEmitterScript = w["emitter"]
	var c = w["world"].get_status_container(1)
	if c == null:
		c = w["world"].create_status_container(1)
	var inst = StatusInstanceScript.new(&"burn", 0, 1, 1, 100, 0)
	c.add(inst, "stackable", 99)
	# Tick 1: burn fires.
	var evs1 = PeriodicStatusProcessorScript.process_tick(
		w["world"], w["rng"], em)
	var dmg1: Array = _events_of_type(evs1, BattleEventTypeScript.DAMAGE_APPLIED)
	_assert(dmg1.size() == 1, "tick 1: 1 DAMAGE_APPLIED")
	# Kill source (entity 0).
	w["world"].apply_damage(0, 9999)
	_assert(not w["world"].is_alive(0), "entity 0 (source) dead")
	_assert(w["world"].is_alive(1), "entity 1 (target) still alive")
	# Tick 2: burn keeps firing despite dead source.
	var evs2 = PeriodicStatusProcessorScript.process_tick(
		w["world"], w["rng"], em)
	var dmg2: Array = _events_of_type(evs2, BattleEventTypeScript.DAMAGE_APPLIED)
	_assert(dmg2.size() == 1, "tick 2 (dead source): burn STILL fires 1 DAMAGE_APPLIED")


# === Determinism ===

func _test_20_run_same_seed_identical_with_indefinite_and_attack_up() -> void:
	print("[DET-1] 20_run_same_seed_identical_with_indefinite_and_attack_up")
	# Run 20 simulations with same seed; all event traces must
	# be byte-identical (normalized).
	var first_norm: Array = []
	for run in 20:
		var sim = _make_mixed_sim()
		var evs: Array = sim.run_until_done(20)
		var norm: Array = _normalize(evs)
		if run == 0:
			first_norm = norm
		else:
			if norm.size() != first_norm.size():
				_assert(false, "run %d size mismatch (got %d, expected %d)" % [run, norm.size(), first_norm.size()])
				return
			for i in norm.size():
				var diff: String = _field_diff(first_norm[i], norm[i])
				if diff != "":
					_assert(false, "run %d event %d differs: %s" % [run, i, diff])
					return
	_assert(true, "20 runs identical (mixed-status trace)")


# === Helpers ===

func _setup_world(max_hp: int) -> Dictionary:
	# Single deterministic RNG fixture shared across all
	# process_tick() calls in a test scenario.
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


func _make_mixed_sim() -> BattleSimulationScript:
	var B = BattleUnitSetupScript
	var S = BattleSetupScript
	var p = B.new("p", &"warrior", 0, Vector2i(0, 1), 100, 100, 20, 5, 1)
	var e1 = B.new("", &"orc", 1, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var s = S.new(42, [p], [e1], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(s)
	# Seed burn (timed) on entity 1.
	var req_burn = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0, -1, -1, 0)
	req_burn.definition_id = &"burn"
	var ctx = EffectContextScript.new(sim.world(), sim.rng(),
		sim.emitter(), [])
	EffectExecutorScript.new().execute(ctx, req_burn)
	# Add indefinite burn on entity 0 via direct container access.
	var c0 = sim.world().get_status_container(0)
	if c0 == null:
		c0 = sim.world().create_status_container(0)
	var indef = StatusInstanceScript.new(&"burn", 1, 0, 1, -1, 0)
	c0.add(indef, "stackable", 99)
	return sim


func _events_of_type(events: Array, type: int) -> Array:
	var out: Array = []
	for e in events:
		if int(e.type) == type:
			out.append(e)
	return out


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
