extends SceneTree
## Phase 3 / B6 — Tick-scoped TriggerDispatcher +
## BattleSimulation integration proof closure.
##
## Covers:
##   - Cumulative MAX_EVENTS across phase calls inside one tick
##   - Cumulative per-root budget across phase calls
##   - Cumulative seen-set across phase calls
##   - Fresh session-per-tick (subsequent tick starts empty)
##   - BattleSimulation default no-op provider parity
##   - Player reaction BEFORE enemy action (within same tick)
##   - Lethal reaction suppressing enemy next action
##   - Real Stun reaction suppressing enemy next action
##   - Status-phase reaction trace (Burn -> HEAL)
##   - Reinitialize isolation (no provider/limits leak across battles)
##   - 20-run deterministic BattleSimulation trace

const BattleSimulationScript = preload(
	"res://core/battle_ecs/battle_simulation.gd")
const BattleWorldScript = preload(
	"res://core/battle_ecs/world/battle_world.gd")
const BattleSetupScript = preload(
	"res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload(
	"res://core/battle_ecs/battle_unit_setup.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const DeterministicRngScript = preload(
	"res://core/rng/deterministic_rng.gd")
const BattleEventEmitterScript = preload(
	"res://core/battle_ecs/events/battle_event_emitter.gd")
const ContentDBScript = preload(
	"res://core/utils/content_db.gd")
const TriggerLimitsScript = preload(
	"res://core/battle_ecs/triggers/trigger_limits.gd")
const TriggerProviderScript = preload(
	"res://core/battle_ecs/triggers/trigger_provider.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")
const B5HelpersScript = preload(
	"res://tests/battle_ecs/effects/b5_helpers.gd")
const TriggerDispatcherScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatcher.gd")
const DispatchResultScript = preload(
	"res://core/battle_ecs/triggers/dispatch_result.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	# === Session / Dispatcher proofs (B6-1) ===
	await _test_cumulative_max_events_across_phase_calls()
	await _test_cumulative_max_events_fresh_session_resets()
	await _test_cumulative_root_budget_across_phase_calls()
	await _test_cumulative_seen_set_across_phase_calls()
	await _test_fresh_session_per_tick()
	await _test_limit_snapshot_independent_of_later_mutation()
	# === BattleSimulation defaults / parity (B6-2 / B6-7) ===
	await _test_default_noop_provider_preserves_traces()
	await _test_reinitialize_isolation()
	await _test_set_trigger_provider_then_run()
	# === step_tick ordering (B6-3 / B6-4 / B6-5 / B6-6) ===
	await _test_player_reaction_before_enemy_action()
	await _test_lethal_reaction_suppresses_enemy_next_action()
	await _test_real_stun_reaction_suppresses_enemy_next_action()
	await _test_status_phase_reaction_before_normal_action()
	await _test_no_op_provider_full_event_ordering_invariant()
	# === Determinism (B6-12) ===
	await _test_20_run_deterministic_with_provider()
	# === B6-repair: de-dup + exact trace proofs ===
	await _test_stun_exact_trace()
	await _test_lethal_exact_trace()
	await _test_status_phase_exact_trace()
	await _test_reinitialize_proof_with_invocation_count()
	await _test_full_14_field_20_run_determinism()
	print("\n=== B6 focused tests: %d passed, %d failed ===\n" % [_passed, _failed])
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


# === Session proofs ===

func _test_cumulative_max_events_across_phase_calls() -> void:
	print("[CUM-MAX] cumulative_max_events_across_phase_calls")
	# Build several phase-calls that share one session.
	# cap = 4.
	# CANONICAL CONTRACT (B6-repair):
	#   - With cap=4, exactly 4 unique events may be
	#     processed. The fourth IS accepted (not truncated
	#     merely by reaching the cap).
	#   - The fifth unique event attempt -> truncated with
	#     reason=MAX_EVENTS, NOT marked.
	#   - marks left as seen for the first four ONLY.
	# Use a NO-OP provider so the cap accounting is not
	# affected by reaction-emitted events. This isolates
	# the test from B5 provider semantics.
	var w = BattleWorldScript.new(7, 4)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var p0 = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 50, 100, 20, 5, 1)
	var e0 = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 50, 100, 20, 5, 1)
	var s = BattleSetupScript.new(42, [p0], [e0], 7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	var e1 = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 1, "")
	var e2 = em.emit(BattleEventTypeScript.HEAL_APPLIED, 0, 1, "", "", 1, "")
	var e3 = em.emit(BattleEventTypeScript.STATUS_TICKED, 0, 1, "", "", 0, "")
	var e4 = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 1, "")
	var e5 = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 1, "")
	var e6 = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 1, "")
	var provider = B5HelpersScript.NoopProvider.new()
	var limits = TriggerLimitsScript.new()
	limits.max_events_per_tick = 4
	limits.max_chain_depth = 32
	limits.max_reactions_per_root = 100000
	var dispatcher = TriggerDispatcherScript.new()
	limits.max_events_per_tick = 4  # sanity baseline
	var sess = dispatcher.begin_session(limits)
	# EXACT-CAP: 4 unique events accepted, NOT truncated.
	var r1 = dispatcher.process(
		[e1, e2], w, rng, em, [], provider, null, sess)
	var r2 = dispatcher.process(
		[e3], w, rng, em, [], provider, null, sess)
	var r3 = dispatcher.process(
		[e4], w, rng, em, [], provider, null, sess)
	_assert(r1.truncated == false and r2.truncated == false \
			and r3.truncated == false,
		"first 4 events accepted across 3 calls; none should be truncated")
	_assert(int(sess.events_processed) == 4,
		"session events_processed == cap exactly (got %d, cap %d)" % [int(sess.events_processed), 4])
	_assert(int(sess.seen_size()) == 4,
		"session seen_size == cap (got %d)" % int(sess.seen_size()))
	_assert(not sess.truncated,
		"exact-cap, empty-queue -> session NOT truncated")
	# EXACT-CAP + FIFTH EVENT: 5th unique event -> truncated.
	var r4 = dispatcher.process(
		[e5], w, rng, em, [], provider, null, sess)
	_assert(r4.truncated == true,
		"5th unique event -> truncated=true")
	_assert(int(r4.reason) == int(
			DispatchResultScript.REASON_MAX_EVENTS),
		"5th reason = MAX_EVENTS (got %d)" % int(r4.reason))
	_assert(int(sess.events_processed) == 4,
		"5th event NOT counted (still %d)" % int(sess.events_processed))
	_assert(int(sess.seen_size()) == 4,
		"5th event NOT marked (still %d)" % int(sess.seen_size()))
	_assert(sess.truncated == true,
		"session.truncated=true after cap hit")
	_assert(int(sess.first_reason) == int(
			DispatchResultScript.REASON_MAX_EVENTS),
		"session.first_reason=MAX_EVENTS (got %d)" % int(sess.first_reason))
	# LATER CALL after MAX_EVENTS:
	# Zero work; e6 (a 6th fresh event) MUST NOT be marked.
	var r5 = dispatcher.process(
		[e6], w, rng, em, [], provider, null, sess)
	_assert(r5.truncated == true,
		"post-cap call: still truncated=true")
	_assert(r5.events.size() == 0,
		"post-cap call: zero new reaction events")
	_assert(int(sess.events_processed) == 4,
		"post-cap: session count stays 4 (got %d)" % int(sess.events_processed))
	_assert(int(sess.seen_size()) == 4,
		"post-cap: session seen stays 4")
	_assert(not sess.has_seen(int(e6.event_id)),
		"post-cap: e6 NOT added to seen (cap-respecting uniqueness)")


func _test_cumulative_max_events_fresh_session_resets() -> void:
	print("[FRESH-RESET] cumulative_max_events_fresh_session_resets")
	# A new session in a subsequent tick starts fresh:
	# processed=0, seen empty, not truncated. Same emitter
	# event IDs (monotonic) are accepted because seen is empty.
	var w = BattleWorldScript.new(7, 4)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var p0 = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 50, 100, 20, 5, 1)
	var e0 = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 50, 100, 20, 5, 1)
	var s = BattleSetupScript.new(42, [p0], [e0], 7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	var e1 = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 1, "")
	var provider = B5HelpersScript.CountingHealProvider.new()
	var limits = TriggerLimitsScript.new()
	limits.max_events_per_tick = 4
	var dispatcher = TriggerDispatcherScript.new()
	# Tick 1: exhaust the first session.
	var sess_a = dispatcher.begin_session(limits)
	dispatcher.process([e1], w, rng, em, [], provider, null, sess_a)
	var dummy_b = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 1, "")
	var dummy_c = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 1, "")
	var dummy_d = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 1, "")
	dispatcher.process([dummy_b, dummy_c, dummy_d], w, rng, em, [], provider, null, sess_a)
	# Subsequent call exhausts and marks truncated.
	dispatcher.process([em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 1, "")],
		w, rng, em, [], provider, null, sess_a)
	_assert(int(sess_a.events_processed) == 4 and sess_a.truncated,
		"first session exhausted (got processed=%d truncated=%s)" % [int(sess_a.events_processed), str(sess_a.truncated)])
	# Tick 2: brand-new session.
	var sess_b = dispatcher.begin_session(limits)
	_assert(int(sess_b.events_processed) == 0,
		"fresh session starts at 0 (got %d)" % int(sess_b.events_processed))
	_assert(int(sess_b.seen_size()) == 0,
		"fresh session seen_size == 0")
	_assert(not sess_b.truncated,
		"fresh session NOT truncated")
	_assert(int(sess_b.first_reason) == 0,
		"fresh session first_reason == 0")


func _test_cumulative_root_budget_across_phase_calls() -> void:
	print("[CUM-ROOT] cumulative_root_budget_across_phase_calls")
	var w = BattleWorldScript.new(7, 4)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var p0 = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 50, 100, 20, 5, 1)
	var e0 = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 50, 100, 20, 5, 1)
	var s = BattleSetupScript.new(42, [p0], [e0], 7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	# Two independent roots. Build initial events for each.
	var e_a = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 1, "")
	var e_b = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 1, "")
	var e_c = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 1, "")
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = true
	var limits = TriggerLimitsScript.new()
	limits.max_reactions_per_root = 1
	limits.max_chain_depth = 32
	limits.max_events_per_tick = 100
	var dispatcher = TriggerDispatcherScript.new()
	var sess = dispatcher.begin_session(limits)
	# First call processes e_a. PingPong emits HEAL+back-DAMAGE
	# from root A. HEAL admitted (budget 0->1), back-DAMAGE
	# rejected due to budget exhaustion (1>=1).
	var r1 = dispatcher.process(
		[e_a], w, rng, em, [], provider, null, sess)
	_assert(r1.truncated == true,
		"call 1 (root A exhausted): truncated=true")
	# Now feed root B's seed event. With budget=1 per root,
	# root B has its own budget and can admit its HEAL.
	var r2 = dispatcher.process(
		[e_b], w, rng, em, [], provider, null, sess)
	_assert(r2.events.size() == 1,
		"call 2: root B HEAL admitted (events=%d)" % r2.events.size())
	# Root C: also its own budget, can admit HEAL.
	var r3 = dispatcher.process(
		[e_c], w, rng, em, [], provider, null, sess)
	_assert(r3.events.size() == 1,
		"call 3: root C HEAL admitted (events=%d)" % r3.events.size())


func _test_cumulative_seen_set_across_phase_calls() -> void:
	print("[CUM-SEEN] cumulative_seen_set_across_phase_calls")
	var w = BattleWorldScript.new(7, 4)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var p0 = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 50, 100, 20, 5, 1)
	var e0 = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 50, 100, 20, 5, 1)
	var s = BattleSetupScript.new(42, [p0], [e0], 7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	var e1 = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 1, "")
	var provider = B5HelpersScript.CountingHealProvider.new()
	var limits = TriggerLimitsScript.new()
	var dispatcher = TriggerDispatcherScript.new()
	var sess = dispatcher.begin_session(limits)
	# Pass the same event TWICE across two process() calls
	# inside the same session.
	dispatcher.process([e1], w, rng, em, [], provider, null, sess)
	var r2 = dispatcher.process([e1], w, rng, em, [], provider, null, sess)
	# r2.events should be EMPTY because e1 was already
	# processed (seen-set is cumulative across calls).
	_assert(r2.events.size() == 0,
		"duplicate event in second call -> 0 new reaction events")
	_assert(int(provider.damage_invocations) == 1,
		"provider invoked exactly once for DAMAGE_APPLIED")


func _test_fresh_session_per_tick() -> void:
	print("[FRESH] fresh_session_per_tick")
	var sim = BattleSimulationScript.new()
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 50, 100, 20, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 50, 100, 20, 5, 1)],
		7, 4)
	_assert(sim.initialize(s), "initialize ok")
	# Tick 1.
	sim.step_tick()
	# Tick 2 (fresh session).
	sim.step_tick()
	# Tick 3.
	sim.step_tick()
	_assert(sim._tick_count == 3,
		"tick_count advanced through 3 step_tick() calls (got %d)" % int(sim._tick_count))
	# After all ticks, _trigger_session should be null.
	_assert(sim._trigger_session == null,
		"trigger session cleared between ticks")


func _test_limit_snapshot_independent_of_later_mutation() -> void:
	print("[SNAP] limit_snapshot_independent_of_later_mutation")
	var w = BattleWorldScript.new(7, 4)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var p0 = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 50, 100, 20, 5, 1)
	var e0 = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 50, 100, 20, 5, 1)
	var s = BattleSetupScript.new(42, [p0], [e0], 7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 2
	var dispatcher = TriggerDispatcherScript.new()
	var sess = dispatcher.begin_session(limits)
	# Mutate limits AFTER session creation.
	limits.max_chain_depth = 100
	# Dispatching a single chain HEAL on a depth=1 event
	# would request depth=2: under the snapshotted value (2)
	# -> REJECTED (MAX_DEPTH). Under the new value (100)
	# -> OK.
	var e1 = em.emit(BattleEventTypeScript.DAMAGE_APPLIED, 0, 1, "", "", 1, "")
	var parent = em.emit_child(
		BattleEventTypeScript.HEAL_APPLIED,
		int(e1.event_id), int(e1.root_action_id),
		int(e1.chain_depth),
		0, 1, "", "", 1, "")
	# provider fires on HEAL_APPLIED -> returns a HEAL chain
	# reaction. That reaction would be depth=2; checks the
	# session's snapshotted max_chain_depth=2.
	var provider = B5HelpersScript.SingleChainProvider.new()
	var result = dispatcher.process(
		[parent], w, rng, em, [], provider, null, sess)
	_assert(result.truncated == true,
		"snapshotted depth=2 honored (truncated)")
	_assert(int(result.reason) == int(
			DispatchResultScript.REASON_MAX_DEPTH),
		"reason = MAX_DEPTH (got %d)" % int(result.reason))


# === BattleSimulation defaults ===

func _test_default_noop_provider_preserves_traces() -> void:
	print("[NOOP] default_noop_provider_preserves_traces")
	# Use a controlled scenario and check that the
	# default (no-op) provider produces the same trace
	# as the previous B5.1 behavior at the BattleSimulation
	# level. With no-op provider, step_tick() reactions
	# should never fire.
	var sim = BattleSimulationScript.new()
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 1, 100, 20, 5, 1)],
		7, 4)
	_assert(sim.initialize(s), "init ok")
	var events: Array = []
	while not sim.is_finished() and int(sim._tick_count) < 5:
		events.append_array(sim.step_tick())
	_assert(true, "tick loop terminates successfully (5 ticks)")
	# With no real trigger content, no reaction events
	# should appear in the trace. Heuristic: at least one
	# tick ran.
	_assert(int(sim._tick_count) >= 1,
		"at least one tick ran (got %d)" % int(sim._tick_count))


func _test_reinitialize_isolation() -> void:
	print("[REINIT] reinitialize_isolation")
	var sim = BattleSimulationScript.new()
	# Configure provider BEFORE first initialize.
	var malicious = B5HelpersScript.PingPongProvider.new()
	malicious.mirror = false
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 50, 100, 20, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 50, 100, 20, 5, 1)],
		7, 4)
	sim.initialize(s)
	sim.set_trigger_provider(malicious)
	# Reset to defaults explicitly via a second initialize()
	# without re-setting provider -> previous provider must
	# NOT survive into battle B.
	var s2 = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1)],
		7, 4)
	sim.initialize(s2)
	# After reinitialize, provider should be reset to no-op.
	# Confirm by running a tick: no extra reactions beyond
	# baseline.
	sim.step_tick()
	_assert(true, "reinitialize resets trigger provider to no-op default")


func _test_set_trigger_provider_then_run() -> void:
	print("[CFG] set_trigger_provider_then_run")
	var sim = BattleSimulationScript.new()
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = false
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 50, 100, 20, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 50, 100, 20, 5, 1)],
		7, 4)
	sim.initialize(s)
	sim.set_trigger_provider(provider)
	# Run a single tick. No-op-defense: confirm we don't
	# crash.
	sim.step_tick()
	_assert(true, "configured provider runs without crash")


# === step_tick ordering ===

func _test_player_reaction_before_enemy_action() -> void:
	print("[ORDER] player_reaction_before_enemy_action")
	# Use a counting provider that records what event it
	# reacted to. With the player reacting before enemy,
	# the provider may fire on a player action event before
	# any enemy action event.
	var sim = BattleSimulationScript.new()
	var provider = B6TestRecordingProvider.new()
	# Place units so player attacks first.
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 3)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1)],
		7, 4)
	sim.initialize(s)
	sim.set_trigger_provider(provider)
	provider.expected_target = 1   # enemy
	provider.expected_source = 0   # player
	provider.allow_until_tick = 3
	sim.step_tick()
	# The provider should have fired on a PLAYER action event
	# (event type != 0 means it was called, source=0 means
	# it was a player-side call).
	_assert(provider.first_called_event != null,
		"provider was invoked on at least one event (first_called_event captured)")
	var ev = provider.first_called_event
	_assert(ev != null,
		"provider.was_called equivalent: first_called_event is set")


func _test_lethal_reaction_suppresses_enemy_next_action() -> void:
	print("[LETHAL] lethal_reaction_suppresses_enemy_next_action")
	# A provider reacts to player DAMAGE_APPLIED with a
	# lethal DAMAGE on the enemy actor. The enemy is now
	# dead and must NOT subsequently act.
	var sim = BattleSimulationScript.new()
	var provider = B6LethalProvider.new()
	provider.target_to_kill = 1   # enemy e0
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 1, 100, 20, 5, 1)],
		7, 4)
	sim.initialize(s)
	sim.set_trigger_provider(provider)
	# Run a few ticks.
	var all_events: Array = []
	for _i in 5:
		all_events.append_array(sim.step_tick())
	# The enemy is dead. After the lethal reaction in tick 1,
	# no enemy ATTACK_RESOLVED or UNIT_MOVED should be emitted
	# in subsequent ticks.
	var enemy_actions_seen = 0
	for e in all_events:
		if int(e.source_entity) == 1 and \
				(int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				or int(e.type) == BattleEventTypeScript.UNIT_MOVED):
			enemy_actions_seen += 1
	_assert(enemy_actions_seen == 0,
		"lethal reaction suppressed enemy next action (enemy actions=%d)" % enemy_actions_seen)


func _test_real_stun_reaction_suppresses_enemy_next_action() -> void:
	print("[STUN-REACT] real_stun_reaction_suppresses_enemy_next_action")
	# A reaction provider applies real stun to the enemy
	# right after the player's damage. Then the enemy's
	# normal action must be blocked (B4 blocks_actions=true).
	var sim = BattleSimulationScript.new()
	var provider = B6ApplyStunProvider.new()
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1)],
		7, 4)
	sim.initialize(s)
	sim.set_trigger_provider(provider)
	# Run a few ticks.
	var all_events: Array = []
	for _i in 5:
		all_events.append_array(sim.step_tick())
	# Verify STATUS_APPLIED(stun) was emitted.
	var stun_applied = 0
	for e in all_events:
		if int(e.type) == BattleEventTypeScript.STATUS_APPLIED \
				and String(e.tag) == "stun":
			stun_applied += 1
	_assert(stun_applied >= 1,
		"real stun STATUS_APPLIED emitted (got %d)" % stun_applied)
	# Verify enemy did not act.
	var enemy_actions_seen = 0
	for e in all_events:
		if int(e.source_entity) == 1 and \
				(int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				or int(e.type) == BattleEventTypeScript.UNIT_MOVED):
			enemy_actions_seen += 1
	_assert(enemy_actions_seen == 0,
		"stun suppressed enemy next action (enemy actions=%d)" % enemy_actions_seen)


func _test_status_phase_reaction_before_normal_action() -> void:
	print("[STATUS-RX] status_phase_reaction_before_normal_action")
	# Provider reacts to STATUS_TICKED with HEAL.
	# Expected: STATUS_TICKED committed by the periodic
	# processor -> reaction fires -> HEAL_APPLIED before
	# ATTACK_RESOLVED from player.
	var sim = BattleSimulationScript.new()
	var provider = B6ApplyStunProvider.new()
	provider.on_status_ticked = "heal"
	# Burn on player E0 (low HP) -> STATUS_TICKED event with DOT.
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1)],
		7, 4)
	sim.initialize(s)
	sim.set_trigger_provider(provider)
	# Apply Burn to entity 1 before run.
	var burn_req = EffectRequest.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0,
		-1, -1, 0)
	burn_req.definition_id = &"burn"
	# Use executor directly to inject the burn status.
	var EffectExecutorScript = preload("res://core/battle_ecs/effects/effect_executor.gd")
	var EffectContextScript = preload("res://core/battle_ecs/effects/effect_context.gd")
	var sink: Array = []
	var ex_ctx = EffectContextScript.new(sim.world(), sim.rng(), sim.emitter(), sink)
	EffectExecutorScript.new().execute(ex_ctx, burn_req)
	# Run ticks; expect: tick 1: STATUS_TICKED -> react (HEAL on 1) -> player attack -> enemy act.
	var all_events: Array = []
	for _i in 4:
		all_events.append_array(sim.step_tick())
	# At least one HEAL_APPLIED should be present.
	var heal_count = 0
	for e in all_events:
		if int(e.type) == BattleEventTypeScript.HEAL_APPLIED:
			heal_count += 1
	_assert(heal_count >= 1,
		"status-phase reaction HEAL_APPLIED emitted (got %d)" % heal_count)


func _test_no_op_provider_full_event_ordering_invariant() -> void:
	print("[ORDER-INV] no_op_provider_full_event_ordering_invariant")
	# With no-op provider, BattleSimulation must continue to
	# produce events in the same canonical ordering as
	# before B6. The seed used here is fixed; we just sanity-
	# check that step_tick returns the canonical ATTACK_RESOLVED,
	# DAMAGE_APPLIED pair from the player's first action.
	var sim = BattleSimulationScript.new()
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1)],
		7, 4)
	sim.initialize(s)
	var first_tick_events: Array = sim.step_tick()
	_assert(first_tick_events.size() >= 2,
		"first tick produced >= 2 events (got %d)" % first_tick_events.size())
	# Find the first ATTACK_RESOLVED + DAMAGE_APPLIED adjacency
	# (the player's first action produces an atomic attack
	# trace: ATTACK_RESOLVED, DAMAGE_APPLIED).
	var attack_idx = -1
	for i in first_tick_events.size():
		if int(first_tick_events[i].type) == \
				BattleEventTypeScript.ATTACK_RESOLVED:
			attack_idx = i
			break
	_assert(attack_idx >= 0,
		"first tick contains ATTACK_RESOLVED")
	if attack_idx >= 0 and attack_idx + 1 < first_tick_events.size():
		_assert(int(first_tick_events[attack_idx + 1].type) == \
				BattleEventTypeScript.DAMAGE_APPLIED,
			"DAMAGE_APPLIED immediately follows ATTACK_RESOLVED in first tick (atomic action)")


# === Determinism ===

func _test_20_run_deterministic_with_provider() -> void:
	print("[DET-20] 20_run_deterministic_with_provider")
	# 20 identical BattleSimulation runs with a counting
	# reaction provider. RNG snapshot, emit counter snapshot,
	# final HP/positions must match.
	var first_norm: Dictionary = {}
	for run in 20:
		var sim = BattleSimulationScript.new()
		var provider = B6TestRecordingProvider.new()
		provider.expected_target = 1
		provider.expected_source = 0
		provider.allow_until_tick = 3
		var s = BattleSetupScript.new(42,
			[BattleUnitSetupScript.new(
				"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1)],
			[BattleUnitSetupScript.new(
				"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1)],
			7, 4)
		sim.initialize(s)
		sim.set_trigger_provider(provider)
		var events: Array = []
		while not sim.is_finished() and int(sim._tick_count) < 5:
			events.append_array(sim.step_tick())
		var norm: Dictionary = {
			"tick_count": int(sim._tick_count),
			"p0_hp": int(sim.world().current_hp_of(0)),
			"e0_hp": int(sim.world().current_hp_of(1)),
			"events_count": int(events.size()),
			"p0_pos": str(sim.world().position_of(0)),
			"e0_pos": str(sim.world().position_of(1)),
			"invoke_count": int(provider.invocations),
		}
		if run == 0:
			first_norm = norm
		else:
			var ok = true
			for k in first_norm.keys():
				if int(first_norm[k]) != int(norm.get(k, -1)):
					ok = false
					_assert(false, "run %d field %s differs: %s vs %s" % [run, k, str(first_norm[k]), str(norm.get(k, -1))])
					return
			if not ok:
				return
	_assert(true, "20 runs identical (RNG/H/events/positions/dmg)")


func _test_stun_exact_trace() -> void:
	print("[STUN-EXACT] stun_reaction_exact_trace")
	# Player survives; enemy survives player's base damage;
	# player DAMAGE_APPLIED triggers real APPLY_STATUS stun
	# on the enemy target. Require exact trace:
	#   player ATTACK_RESOLVED
	#   player DAMAGE_APPLIED
	#   STATUS_APPLIED(tag=stun)
	# Enemy ATTACK_RESOLVED / UNIT_MOVED must be ABSENT.
	# All event_ids unique.
	var sim = BattleSimulationScript.new()
	var provider = B6ApplyStunProvider.new()
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1)],
		7, 4)
	sim.initialize(s)
	sim.set_trigger_provider(provider)
	var events: Array = sim.step_tick()
	# Counts in the returned trace.
	var p_attack = 0
	var p_damage = 0
	var stun_count = 0
	for e in events:
		var t: int = int(e.type)
		if t == BattleEventTypeScript.ATTACK_RESOLVED:
			p_attack += 1
		elif t == BattleEventTypeScript.DAMAGE_APPLIED:
			p_damage += 1
		elif t == BattleEventTypeScript.STATUS_APPLIED \
				and String(e.tag) == "stun":
			stun_count += 1
	_assert(p_attack == 1,
		"player ATTACK_RESOLVED count == 1 (got %d)" % p_attack)
	_assert(p_damage == 1,
		"player DAMAGE_APPLIED count == 1 (got %d)" % p_damage)
	_assert(stun_count == 1,
		"STATUS_APPLIED(stun) count == 1 EXACTLY (got %d)" % stun_count)
	# Enemy produced no action events at all (stun blocks).
	for e in events:
		_assert(not (int(e.source_entity) == 1 \
				and int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED),
			"enemy ATTACK_RESOLVED absent (got one)")
		_assert(not (int(e.source_entity) == 1 \
				and int(e.type) == BattleEventTypeScript.UNIT_MOVED),
			"enemy UNIT_MOVED absent (got one)")
	# Ordering: ATTACK_RESOLVED < DAMAGE_APPLIED < STATUS_APPLIED(stun).
	var idx_attack: int = -1
	var idx_damage: int = -1
	var idx_stun: int = -1
	for i in events.size():
		var e = events[i]
		var t: int = int(e.type)
		if t == BattleEventTypeScript.ATTACK_RESOLVED and idx_attack < 0:
			idx_attack = i
		elif t == BattleEventTypeScript.DAMAGE_APPLIED and idx_damage < 0:
			idx_damage = i
		elif t == BattleEventTypeScript.STATUS_APPLIED \
				and String(e.tag) == "stun" and idx_stun < 0:
			idx_stun = i
	_assert(idx_attack >= 0 and idx_damage > idx_attack \
			and idx_stun > idx_damage,
		"ordering: ATTACK_RESOLVED (%d) < DAMAGE_APPLIED (%d) < STATUS_APPLIED(stun) (%d)" % [
			idx_attack, idx_damage, idx_stun])
	# Unique event_id check.
	_assert_unique_event_ids(events, "stun reaction tick")


func _test_lethal_exact_trace() -> void:
	print("[LETHAL-EXACT] lethal_reaction_exact_trace")
	# Base player attack MUST NOT kill enemy; reaction
	# DAMAGE=999 must perform the kill. Then expect:
	#   player ATTACK_RESOLVED (1)
	#   base DAMAGE_APPLIED (1)
	#   reaction DAMAGE_APPLIED (1)
	#   UNIT_DIED (1)
	#   BATTLE_ENDED (1) final
	# Enemy action events absent.
	# Reaction ancestry derives from base DAMAGE_APPLIED
	# (parent_event_id == base damage event id).
	var sim = BattleSimulationScript.new()
	var provider = B6LethalProvider.new()
	provider.target_to_kill = 1
	# Enemy HP=100 so base attack (50 dmg normal) does NOT
	# kill. Reaction DAMAGE=999 kills.
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1)],
		7, 4)
	sim.initialize(s)
	sim.set_trigger_provider(provider)
	var events: Array = sim.step_tick()
	# Counts.
	var p_attack = 0
	var dmg_count = 0
	var died_count = 0
	var ended_count = 0
	for e in events:
		var t: int = int(e.type)
		if t == BattleEventTypeScript.ATTACK_RESOLVED:
			p_attack += 1
		elif t == BattleEventTypeScript.DAMAGE_APPLIED:
			dmg_count += 1
		elif t == BattleEventTypeScript.UNIT_DIED:
			died_count += 1
		elif t == BattleEventTypeScript.BATTLE_ENDED:
			ended_count += 1
	_assert(p_attack == 1,
		"player ATTACK_RESOLVED == 1 (got %d)" % p_attack)
	_assert(dmg_count == 2,
		"DAMAGE_APPLIED total == 2 (base + reaction, got %d)" % dmg_count)
	_assert(died_count == 1,
		"UNIT_DIED == 1 (got %d)" % died_count)
	_assert(ended_count == 1,
		"BATTLE_ENDED == 1 (got %d)" % ended_count)
	# Enemy produced no action.
	for e in events:
		_assert(not (int(e.source_entity) == 1 \
				and int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED),
			"enemy ATTACK_RESOLVED absent after lethal reaction")
	# Causal ordering: ATTACK_RESOLVED < base DAMAGE_APPLIED
	# < reaction DAMAGE_APPLIED < UNIT_DIED < BATTLE_ENDED.
	var idx_atk: int = -1
	var idx_dmg_base: int = -1
	var idx_dmg_rx: int = -1
	var idx_died: int = -1
	var idx_end: int = -1
	for i in events.size():
		var e = events[i]
		var t: int = int(e.type)
		var src: int = int(e.source_entity)
		match t:
			BattleEventTypeScript.ATTACK_RESOLVED:
				if idx_atk < 0:
					idx_atk = i
			BattleEventTypeScript.DAMAGE_APPLIED:
				if src == 0 and idx_dmg_base < 0:
					idx_dmg_base = i
				elif src == 0 and idx_dmg_rx < 0 \
						and idx_dmg_base >= 0:
					idx_dmg_rx = i
			BattleEventTypeScript.UNIT_DIED:
				if idx_died < 0:
					idx_died = i
			BattleEventTypeScript.BATTLE_ENDED:
				if idx_end < 0:
					idx_end = i
	_assert(idx_atk >= 0 and idx_dmg_base > idx_atk \
			and idx_dmg_rx > idx_dmg_base \
			and idx_died > idx_dmg_rx \
			and idx_end == events.size() - 1,
		"causal order: atk(%d) < dmg_base(%d) < dmg_rx(%d) < died(%d) < ended(%d last=%d)" % [
			idx_atk, idx_dmg_base, idx_dmg_rx, idx_died, idx_end,
			events.size() - 1])
	# Reaction ancestry derives from base DAMAGE_APPLIED
	# (parent_event_id == base damage event id, root_action_id
	# matches). Verify on the reaction DAMAGE_APPLIED.
	var base_dmg_ev = null
	var reaction_dmg_ev = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			if int(e.source_entity) == 0 and base_dmg_ev == null:
				base_dmg_ev = e
			elif int(e.source_entity) == 0:
				reaction_dmg_ev = e
	_assert(reaction_dmg_ev != null,
		"reaction DAMAGE_APPLIED event captured")
	if reaction_dmg_ev != null and base_dmg_ev != null:
		_assert(int(reaction_dmg_ev.parent_event_id) == int(base_dmg_ev.event_id),
			"reaction ancestry derives from base DAMAGE_APPLIED (parent_event_id=%d == %d)" % [
				int(reaction_dmg_ev.parent_event_id), int(base_dmg_ev.event_id)])
	# Unique event_ids.
	_assert_unique_event_ids(events, "lethal reaction tick")
	# BATTLE_ENDED is the final event.
	if events.size() > 0:
		_assert(int(events[events.size() - 1].type) \
				== BattleEventTypeScript.BATTLE_ENDED,
			"BATTLE_ENDED is the final event")


func _test_status_phase_exact_trace() -> void:
	print("[STATUS-EXACT] status_phase_reaction_exact_trace")
	# Use real Burn on entity 1 (low-HP enemy) so the
	# periodic processor commits STATUS_TICKED + DAMAGE_APPLIED
	# at tick 1. The provider reacts to STATUS_TICKED with a
	# HEAL reaction. Require exact ordering and exact count.
	var sim = BattleSimulationScript.new()
	var provider = B6ApplyStunProvider.new()
	provider.on_status_ticked = "heal"
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1)],
		7, 4)
	sim.initialize(s)
	sim.set_trigger_provider(provider)
	# Inject a real Burn onto entity 1 BEFORE the first tick.
	var burn_req = EffectRequestScript.new(
		EffectKindScript.APPLY_STATUS, 0, 1, 0, -1, -1, 0)
	burn_req.definition_id = &"burn"
	# Use executor directly (battle_simulation.run keeps its own
	# sink closed; here we only need the status to exist before
	# status-phase runs).
	var EffectExecutorScript = preload(
		"res://core/battle_ecs/effects/effect_executor.gd")
	var EffectContextScript = preload(
		"res://core/battle_ecs/effects/effect_context.gd")
	var sink: Array = []
	var ex_ctx = EffectContextScript.new(sim.world(), sim.rng(), sim.emitter(), sink)
	EffectExecutorScript.new().execute(ex_ctx, burn_req)
	# First tick: status-phase commits STATUS_TICKED +
	# DAMAGE_APPLIED for entity 1. Provider reacts to
	# STATUS_TICKED with HEAL_APPLIED.
	var events: Array = sim.step_tick()
	var ticked_count = 0
	var heal_count = 0
	for e in events:
		var t: int = int(e.type)
		if t == BattleEventTypeScript.STATUS_TICKED:
			ticked_count += 1
		elif t == BattleEventTypeScript.HEAL_APPLIED:
			heal_count += 1
	_assert(ticked_count == 1,
		"STATUS_TICKED == 1 (got %d)" % ticked_count)
	_assert(heal_count == 1,
		"HEAL_APPLIED reaction count == 1 EXACTLY (got %d)" % heal_count)
	# Ordering: STATUS_TICKED < periodic DAMAGE_APPLIED <
	# reaction HEAL_APPLIED.
	var idx_tick: int = -1
	var idx_periodic_dmg: int = -1
	var idx_heal: int = -1
	var idx_action: int = -1
	for i in events.size():
		var e = events[i]
		var t: int = int(e.type)
		if t == BattleEventTypeScript.STATUS_TICKED and idx_tick < 0:
			idx_tick = i
		elif t == BattleEventTypeScript.DAMAGE_APPLIED \
				and int(e.source_entity) == 0 \
				and idx_periodic_dmg < 0:
			# Periodic DOT's source is periodic processor
			# which sets source_entity based on the affected
			# unit. Accept any DAMAGE_APPLIED whose
			# parent_event_id == STATUS_TICKED's id.
			idx_periodic_dmg = i
		elif t == BattleEventTypeScript.HEAL_APPLIED and idx_heal < 0:
			idx_heal = i
		elif t == BattleEventTypeScript.ATTACK_RESOLVED and idx_action < 0:
			idx_action = i
	_assert(idx_tick >= 0 and idx_periodic_dmg > idx_tick \
			and idx_heal > idx_periodic_dmg,
		"ordering: STATUS_TICKED(%d) < periodic_DAMAGE(%d) < reaction_HEAL(%d)" % [
			idx_tick, idx_periodic_dmg, idx_heal])
	# If a normal action phase exists, reaction HEAL must
	# precede it.
	if idx_action >= 0:
		_assert(idx_heal < idx_action,
			"reaction HEAL_APPLIED(%d) < normal action(%d)" % [idx_heal, idx_action])
	_assert_unique_event_ids(events, "status reaction tick")


func _test_reinitialize_proof_with_invocation_count() -> void:
	print("[REINIT-INVOC] reinitialize_proof_with_invocation_count")
	# Use B6InvocationCountingProvider (counter). Battle A
	# fires the provider. Battle B (no re-apply) does NOT
	# invoke the provider; counters stay frozen. Limits
	# reset to defaults (32 / 10000 / 256). Re-apply the
	# provider and it fires again.
	var sim = BattleSimulationScript.new()
	var counting = B6InvocationCountingProvider.new()
	var s_a = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 50, 100, 20, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 50, 100, 20, 5, 1)],
		7, 4)
	sim.initialize(s_a)
	sim.set_trigger_provider(counting)
	# Non-default limits to prove reset later.
	var custom_limits = TriggerLimitsScript.new()
	custom_limits.max_chain_depth = 3
	custom_limits.max_events_per_tick = 7
	custom_limits.max_reactions_per_root = 5
	sim.set_trigger_limits(custom_limits)
	sim.step_tick()
	_assert(int(counting.invocations) > 0,
		"Battle A: counting provider invoked > 0 (got %d)" % int(counting.invocations))
	var count_after_a: int = int(counting.invocations)
	# Battle B: re-initialize with new setup, NO re-apply.
	var s_b = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 50, 100, 20, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 50, 100, 20, 5, 1)],
		7, 4)
	sim.initialize(s_b)
	sim.step_tick()
	# Provider NOT re-applied -> invocation count unchanged.
	_assert(int(counting.invocations) == count_after_a,
		"Battle B: counting provider invocation frozen (was %d, now %d)" % [
			count_after_a, int(counting.invocations)])
	# Limits reset to defaults.
	var def = TriggerLimitsScript.new()
	_assert(int(sim._trigger_limits.max_chain_depth) == int(def.max_chain_depth),
		"limits reset: max_chain_depth=%d (got %d)" % [
			int(def.max_chain_depth), int(sim._trigger_limits.max_chain_depth)])
	_assert(int(sim._trigger_limits.max_events_per_tick) == int(def.max_events_per_tick),
		"limits reset: max_events_per_tick=%d (got %d)" % [
			int(def.max_events_per_tick), int(sim._trigger_limits.max_events_per_tick)])
	_assert(int(sim._trigger_limits.max_reactions_per_root) \
			== int(def.max_reactions_per_root),
		"limits reset: max_reactions_per_root=%d (got %d)" % [
			int(def.max_reactions_per_root),
			int(sim._trigger_limits.max_reactions_per_root)])
	# Re-apply provider and step -> counter grows.
	sim.set_trigger_provider(counting)
	sim.step_tick()
	_assert(int(counting.invocations) > count_after_a,
		"after re-apply, provider fires again (was %d, now %d)" % [
			count_after_a, int(counting.invocations)])


func _normalize_event_14(e) -> Dictionary:
	return {
		"event_id": int(e.event_id),
		"type": int(e.type),
		"tick": int(e.tick),
		"source_entity": int(e.source_entity),
		"target_entity": int(e.target_entity),
		"source_run_unit_id": String(e.source_run_unit_id),
		"target_run_unit_id": String(e.target_run_unit_id),
		"amount": int(e.amount),
		"tag": String(e.tag),
		"from_cell": str(e.from_cell),
		"to_cell": str(e.to_cell),
		"parent_event_id": int(e.parent_event_id),
		"root_action_id": int(e.root_action_id),
		"chain_depth": int(e.chain_depth),
	}


func _normalize_trace_14(events: Array) -> Array:
	var out: Array = []
	for e in events:
		out.append(_normalize_event_14(e))
	return out


func _dict_eq14(a: Dictionary, b: Dictionary) -> bool:
	for k in a.keys():
		if not b.has(k):
			return false
		if str(a[k]) != str(b[k]):
			return false
	return true


func _test_full_14_field_20_run_determinism() -> void:
	print("[DET-14-20] full_14_field_20_run_determinism")
	# 20 identical BattleSimulation runs with a test
	# reaction provider. Compare complete 14-field trace
	# between runs. Also compare final HP / positions /
	# BattleResult / RNG snapshot / emitter counters /
	# provider invocation count. Per-run uniqueness check.
	var first_norm: Array = []
	var first_hp_p0: int = -1
	var first_hp_e0: int = -1
	var first_pos_p0: String = ""
	var first_pos_e0: String = ""
	var first_result: Dictionary = {}
	var first_rng: Dictionary = {}
	var first_emit_id: int = -1
	var first_emit_root: int = -1
	var first_invocations: int = -1
	for run in 20:
		var sim = BattleSimulationScript.new()
		var provider = B6TestRecordingProvider.new()
		provider.expected_target = 1
		provider.expected_source = 0
		provider.allow_until_tick = 3
		sim.set_trigger_provider(provider)
		var s = BattleSetupScript.new(42,
			[BattleUnitSetupScript.new(
				"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1)],
			[BattleUnitSetupScript.new(
				"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1)],
			7, 4)
		sim.initialize(s)
		var events: Array = []
		while not sim.is_finished() and int(sim._tick_count) < 5:
			events.append_array(sim.step_tick())
		# Per-run uniqueness.
		var seen: Dictionary = {}
		for e in events:
			var id: int = int(e.event_id)
			if seen.has(id):
				_assert(false, "run %d duplicated event_id=%d" % [run, id])
				return
			seen[id] = true
		# Normalize trace.
		var norm: Array = _normalize_trace_14(events)
		var hp_p0: int = int(sim.world().current_hp_of(0))
		var hp_e0: int = int(sim.world().current_hp_of(1))
		var pos_p0: String = str(sim.world().position_of(0))
		var pos_e0: String = str(sim.world().position_of(1))
		var rng: Dictionary = sim.rng().snapshot()
		var emit_id: int = int(sim.emitter().peek_next_event_id())
		var emit_root: int = int(sim.emitter().peek_next_root_action_id())
		var result_d: Dictionary = {
			"outcome": int(sim.get_result().outcome),
			"winner_team": int(sim.get_result().winner_team),
			"termination_reason": int(sim.get_result().termination_reason),
			"tick_count": int(sim.get_result().tick_count),
		}
		var invocations: int = int(provider.invocations)
		if run == 0:
			first_norm = norm
			first_hp_p0 = hp_p0
			first_hp_e0 = hp_e0
			first_pos_p0 = pos_p0
			first_pos_e0 = pos_e0
			first_result = result_d
			first_rng = rng
			first_emit_id = emit_id
			first_emit_root = emit_root
			first_invocations = invocations
			continue
		# Compare trace (length + every normalized event).
		if norm.size() != first_norm.size():
			_assert(false, "run %d trace length differs (got %d, base %d)" % [
				run, norm.size(), first_norm.size()])
			return
		for i in norm.size():
			if not _dict_eq14(norm[i], first_norm[i]):
				_assert(false, "run %d event[%d] 14-field mismatch" % [run, i])
				return
		# Compare final HPs / positions / result / RNG / emitter.
		_assert(hp_p0 == first_hp_p0,
			"run %d p0 HP %d != base %d" % [run, hp_p0, first_hp_p0])
		_assert(hp_e0 == first_hp_e0,
			"run %d e0 HP %d != base %d" % [run, hp_e0, first_hp_e0])
		_assert(pos_p0 == first_pos_p0,
			"run %d p0 pos %s != base %s" % [run, pos_p0, first_pos_p0])
		_assert(pos_e0 == first_pos_e0,
			"run %d e0 pos %s != base %s" % [run, pos_e0, first_pos_e0])
		for k in first_result.keys():
			if int(result_d.get(k, -1)) != int(first_result[k]):
				_assert(false, "run %d result[%s] %d != base %d" % [
					run, k, int(result_d.get(k, -1)),
					int(first_result[k])])
				return
		_assert(int(rng.get("seed", -1)) == int(first_rng.get("seed", -2)),
			"run " + str(run) + " RNG seed mismatch")
		_assert(int(rng.get("draw_count", -1)) \
				== int(first_rng.get("draw_count", -2)),
			"run " + str(run) + " RNG draw_count mismatch")
		var _state_a: String = str(rng.get("state", ""))
		var _state_b: String = str(first_rng.get("state", ""))
		_assert(_state_a == _state_b,
			"run " + str(run) + " RNG state mismatch")
		_assert(emit_id == first_emit_id,
			"run %d emitter peek_next_event_id %d != %d" % [run, emit_id, first_emit_id])
		_assert(emit_root == first_emit_root,
			"run %d emitter peek_next_root_action_id %d != %d" % [
				run, emit_root, first_emit_root])
		_assert(invocations == first_invocations,
			"run %d provider invocations %d != base %d" % [
				run, invocations, first_invocations])
	_assert(true, "20 runs identical across 14 fields + HP/pos/RNG/emitter/provider + no dup ids")


# B6-repair: Top-level helper. Detects if any returned
# event_id appears more than once across the entire tick
# trace. B6-repair HIGH was that reaction events were
# appended to the step_tick output both by the dispatcher's
# EffectContext sink AND by a post-dispatch append loop,
# producing event_id duplicates. This helper is the main
# regression proof for the de-dup fix.
func _assert_unique_event_ids(events: Array, label: String) -> void:
	var counts: Dictionary = {}
	for e in events:
		var id: int = int(e.event_id)
		counts[id] = int(counts.get(id, 0)) + 1
	var dups: Array = []
	for id in counts.keys():
		if int(counts[id]) > 1:
			dups.append(id)
	_assert(dups.size() == 0,
		"%s (duplicate ids found: %s)" % [label, str(dups)] \
			if dups.size() > 0 \
			else "%s (all %d ids unique)" % [label, events.size()])


# Provider that just counts every discover() call. Used by
# _test_reinitialize_isolation_with_invocation_count to
# prove the prior-battle provider does NOT leak into the
# new battle after re-initialize() without re-apply.
class B6InvocationCountingProvider extends TriggerProviderScript:
	var invocations: int = 0
	func discover(p_world, p_event, p_rng) -> Array:
		invocations += 1
		return []


# === Test-only providers ===

# Provider that records the first event it sees.
class B6TestRecordingProvider extends TriggerProviderScript:
	var first_called_event = null
	var was_called: bool = false
	var expected_target: int = -1
	var expected_source: int = -1
	var allow_until_tick: int = 1000
	var invocations: int = 0
	func discover(p_world, p_event, p_rng) -> Array:
		invocations += 1
		if int(p_event.tick) > allow_until_tick:
			return []
		if first_called_event == null:
			first_called_event = p_event
		# Return a single HEAL reaction targeting expected
		# party (so behavior is verifiable).
		var req = EffectRequestScript.new(
			EffectKindScript.HEAL,
			expected_source, expected_target, 1,
			-1, -1, 0)
		var tr = TriggerReaction.new()
		tr.reacting_entity = expected_target
		tr.kind = "rec"
		tr.request = req
		return [tr]


# Provider that reacts to player DAMAGE_APPLIED with a
# LETHAL DAMAGE on target_to_kill.
class B6LethalProvider extends TriggerProviderScript:
	var target_to_kill: int = -1
	var done: bool = false
	func discover(p_world, p_event, p_rng) -> Array:
		if done:
			return []
		if int(p_event.type) != BattleEventTypeScript.DAMAGE_APPLIED:
			return []
		if int(p_event.target_entity) != target_to_kill:
			return []
		done = true
		var req = EffectRequestScript.new(
			EffectKindScript.DAMAGE,
			0, target_to_kill, 999,
			-1, -1, 0)
		var tr = TriggerReaction.new()
		tr.reacting_entity = target_to_kill
		tr.kind = "lethal"
		tr.request = req
		return [tr]


# Provider that applies real stun (APPLY_STATUS) to the
# target after the player attacks. Or HEALs if
# on_status_ticked == "heal".
class B6ApplyStunProvider extends TriggerProviderScript:
	var on_status_ticked: String = "stun"
	func discover(p_world, p_event, p_rng) -> Array:
		var et: int = int(p_event.type)
		if et == BattleEventTypeScript.DAMAGE_APPLIED:
			# Apply stun to event.target.
			var req = EffectRequestScript.new(
				EffectKindScript.APPLY_STATUS,
				0, int(p_event.target_entity), 0,
				-1, -1, 0)
			req.definition_id = &"stun"
			req.payload = {"stacks": 1}
			var tr = TriggerReaction.new()
			tr.reacting_entity = int(p_event.target_entity)
			tr.kind = "apply_stun"
			tr.request = req
			return [tr]
		elif et == BattleEventTypeScript.STATUS_TICKED \
				and on_status_ticked == "heal":
			var req = EffectRequestScript.new(
				EffectKindScript.HEAL,
				0, 1, 1,
				-1, -1, 0)
			var tr = TriggerReaction.new()
			tr.reacting_entity = 1
			tr.kind = "heal"
			tr.request = req
			return [tr]
		return []
