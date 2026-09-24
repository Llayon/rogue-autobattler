extends SceneTree
## B6.1.1 — PERFORM_ATTACK reaction ancestry, bounds, and 20-run
## determinism. Test-only counter-like providers prove the
## canonical path is safe for a real Counterattack content
## integration. NO shipping Counterattack content migration.
## NO ReactionDef / ContentDB / UnitDef changes.

const BattleSimulationScript = preload(
	"res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload(
	"res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload(
	"res://core/battle_ecs/battle_unit_setup.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const BattleEventEmitterScript = preload(
	"res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleWorldScript = preload(
	"res://core/battle_ecs/world/battle_world.gd")
const DeterministicRngScript = preload(
	"res://core/rng/deterministic_rng.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const EffectExecutorScript = preload(
	"res://core/battle_ecs/effects/effect_executor.gd")
const EffectContextScript = preload(
	"res://core/battle_ecs/effects/effect_context.gd")
const TriggerProviderScript = preload(
	"res://core/battle_ecs/triggers/trigger_provider.gd")
const TriggerReactionScript = preload(
	"res://core/battle_ecs/triggers/trigger_reaction.gd")
const TriggerLimitsScript = preload(
	"res://core/battle_ecs/triggers/trigger_limits.gd")
const TriggerDispatcherScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatcher.gd")
const TriggerDispatchSessionScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatch_session.gd")
const DispatchResultScript = preload(
	"res://core/battle_ecs/triggers/dispatch_result.gd")
const StatusInstanceScript = preload(
	"res://core/battle_ecs/status/status_instance.gd")
const ContentDBScript = preload(
	"res://core/utils/content_db.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	await _test_counter_like_exact_4_event_prefix()
	await _test_counter_like_stunned_source_rejected()
	await _test_counter_like_out_of_range_rejected()
	await _test_root_budget_bound_dispatcher()
	await _test_depth_bound_dispatcher()
	await _test_20_run_determinism_reaction_enabled()
	print("\n=== B6.1.1 reaction closure: %d pass / %d fail ===\n" % [_passed, _failed])
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


# ============================================================
# Test-only counter-like providers.
#
# B611OneShotCounterProvider
#   - reacts ONLY to DAMAGE_APPLIED with source=0, target=1
#     (the FIRST player attack). Never reacts to the
#     reverse-direction counter attacker's DAMAGE_APPLIED
#     or any other event. Gives a stable integration trace.
#   - deliberately permissive: provider proposes a counter
#     PERFORM_ATTACK even when source/target out-of-range or
#     stunned. Execute is the authoritative gate.
#
# B611PingPongProvider
#   - reacts to ANY DAMAGE_APPLIED with reverse source/target.
#   - produces a reaction chain that exercises the
#     max_reactions_per_root / max_chain_depth limits.
# ============================================================
class B611OneShotCounterProvider extends TriggerProviderScript:
	var invocations: int = 0
	var last_event = null
	var fired: bool = false
	func discover(p_world, p_event, p_rng) -> Array:
		# One-shot guard: fire at most ONCE per provider
		# instance. Increment counter only when we actually
		# considered a candidate event so invocation count
		# reflects semantic invocations, not raw calls.
		if fired:
			return []
		if int(p_event.type) != BattleEventTypeScript.DAMAGE_APPLIED:
			return []
		if int(p_event.source_entity) != 0:
			return []
		if int(p_event.target_entity) != 1:
			return []
		invocations += 1
		last_event = p_event
		var template = EffectRequestScript.root(
			EffectKindScript.PERFORM_ATTACK, 1, 0, 0)
		var child_req = EffectRequestScript.child_from_template(
			template, p_event)
		if child_req == null:
			return []
		var tr = TriggerReactionScript.new()
		tr.reacting_entity = 1
		tr.kind = "counter_one_shot"
		tr.request = child_req
		fired = true
		return [tr]


class B611PingPongProvider extends TriggerProviderScript:
	var invocations: int = 0
	func discover(p_world, p_event, p_rng) -> Array:
		invocations += 1
		if int(p_event.type) != BattleEventTypeScript.DAMAGE_APPLIED:
			return []
		var src: int = int(p_event.source_entity)
		var tgt: int = int(p_event.target_entity)
		var template = EffectRequestScript.root(
			EffectKindScript.PERFORM_ATTACK, tgt, src, 0)
		var child_req = EffectRequestScript.child_from_template(
			template, p_event)
		if child_req == null:
			return []
		var tr = TriggerReactionScript.new()
		tr.reacting_entity = tgt
		tr.kind = "ping_pong"
		tr.request = child_req
		return [tr]


# ============================================================
# Helper: make a sim with healthy p0 vs e0 (range 1)
# ============================================================
func _make_sim(p_hp: int = 200, e_hp: int = 200, p_atk: int = 50, e_atk: int = 20,
		p_range: int = 1, e_range: int = 1, seed: int = 42) -> Dictionary:
	var sim = BattleSimulationScript.new()
	var s = BattleSetupScript.new(seed,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), p_hp, p_hp, p_atk, 5, p_range)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), e_hp, e_hp, e_atk, 5, e_range)],
		7, 4)
	sim.initialize(s)
	return {"sim": sim}


# ============================================================
# 1) counter-like exact 4-event prefix.
#
# Healthy units (HP >= 200) so neither side dies from the
# player's normal attack; the counter fires exactly once
# because B611OneShotCounterProvider fires ONLY for the
# player's DAMAGE_APPLIED (not the counter's).
# ============================================================
func _test_counter_like_exact_4_event_prefix() -> void:
	print("[B611-COUNTER] counter_like_exact_4_event_prefix")
	var D = _make_sim()
	var sim: RefCounted = D["sim"]
	var provider = B611OneShotCounterProvider.new()
	sim.set_trigger_provider(provider)
	sim.set_max_ticks(5)
	var events: Array = []
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	_assert(events.size() >= 4,
		"trace has at least 4 events (got %d)" % events.size())
	if events.size() < 4:
		return
	# First 4 events must be canonical counter prefix:
	#   0 player ATTACK_RESOLVED    depth 0
	#   1 player DAMAGE_APPLIED      depth 1
	#   2 counter ATTACK_RESOLVED    depth 2
	#   3 counter DAMAGE_APPLIED      depth 3
	# Then any later scheduler root (e.g. enemy normal action)
	# appears strictly AFTER index 3.
	var types: Array = []
	var depths: Array = []
	for i in 4:
		types.append(int(events[i].type))
		depths.append(int(events[i].chain_depth))
	_assert(types == [
			BattleEventTypeScript.ATTACK_RESOLVED,
			BattleEventTypeScript.DAMAGE_APPLIED,
			BattleEventTypeScript.ATTACK_RESOLVED,
			BattleEventTypeScript.DAMAGE_APPLIED],
		"events[0..3].type = [ATK, DMG, ATK, DMG] (got %s)" % str(types))
	_assert(depths == [0, 1, 2, 3],
		"events[0..3].chain_depth = [0, 1, 2, 3] (got %s)" % str(depths))
	# All four share the SAME root_action_id.
	var root_ids: Array = []
	for i in 4:
		root_ids.append(int(events[i].root_action_id))
	_assert(root_ids[0] == root_ids[1] \
			and root_ids[1] == root_ids[2] \
			and root_ids[2] == root_ids[3],
		"events[0..3] share SAME root_action_id (got %s)" % str(root_ids))
	# Parent chain on the first 4 events.
	_assert(int(events[0].parent_event_id) == -1,
		"events[0] (player ATK) parent_event_id == -1 (root)")
	_assert(int(events[1].parent_event_id) == int(events[0].event_id),
		"events[1] (player DMG) parent == events[0].event_id")
	_assert(int(events[2].parent_event_id) == int(events[1].event_id),
		"events[2] (counter ATK) parent == events[1].event_id")
	_assert(int(events[3].parent_event_id) == int(events[2].event_id),
		"events[3] (counter DMG) parent == events[2].event_id")
	# Provider fires EXACTLY ONCE (only the player's DMG).
	_assert(int(provider.invocations) == 1,
		"one-shot provider invoked exactly 1 time (got %d)"
		% int(provider.invocations))
	# Counter source/target swap.
	_assert(int(events[2].source_entity) == 1
			and int(events[2].target_entity) == 0,
		"counter ATK: source=1 target=0 (reverse)")
	_assert(int(events[3].source_entity) == 1
			and int(events[3].target_entity) == 0,
		"counter DMG: source=1 target=0 (reverse)")
	# Unique event_ids across the entire trace.
	var seen: Dictionary = {}
	var dup: Array = []
	for e in events:
		var id: int = int(e.event_id)
		if seen.has(id):
			dup.append(id)
		seen[id] = true
	_assert(dup.size() == 0,
		"all event_ids unique (got duplicates %s)" % str(dup))


# ============================================================
# 2) stunned reactor rejected at execute.
# Provider is deliberately permissive (one-shot, source/target
# match intact). PerformAttackEffect must reject because the
# enemy (would-be reactor) has blocks_actions=true.
# ============================================================
func _test_counter_like_stunned_source_rejected() -> void:
	print("[B611-STUN] counter_like_stunned_source_rejected")
	var sim = BattleSimulationScript.new()
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 200, 200, 50, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 200, 200, 20, 5, 1)],
		7, 4)
	sim.initialize(s)
	# Inject real Stun on the would-be reactor (entity 1).
	# Duration=99 (effectively forever for this test) so the
	# stun remains active across all 5 ticks.
	var container = sim.world().create_status_container(1)
	var inst = StatusInstanceScript.new(
		&"stun", 0, 1, 1, 99, 0)
	container.add(inst, "unique", 1)
	var provider = B611OneShotCounterProvider.new()
	sim.set_trigger_provider(provider)
	var p_hp_before: int = int(sim.world().current_hp_of(0))
	var events: Array = []
	sim.set_max_ticks(5)
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	# Provider was permissive and proposed a counter; PerformAttack
	# Effect rejected at execute due to blocks_actions.
	# Expected: player ATK + player DMG only (no counter ATK/DMG
	# whose source == 1).
	var saw_counter_atk: bool = false
	var saw_counter_dmg: bool = false
	for e in events:
		if int(e.source_entity) == 1 \
				and int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED:
			saw_counter_atk = true
		if int(e.source_entity) == 1 \
				and int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			saw_counter_dmg = true
	_assert(not saw_counter_atk,
		"no counter ATTACK_RESOLVED (stunned reactor rejected)")
	_assert(not saw_counter_dmg,
		"no counter DAMAGE_APPLIED (stunned reactor rejected)")
	_assert(int(sim.world().current_hp_of(0)) == p_hp_before,
		"player HP unchanged (stunned counter rejected at execute)")
	_assert(int(provider.invocations) >= 1,
		"provider was invoked (permissive dispatcher proposal)")


# ============================================================
# 3) out-of-range counter rejected
# Provider proposes a counter PERFORM_ATTACK whose source/target
# are outside attack range. PerformAttackEffect rejects the
# request cleanly (no movement, no HP mutation).
# ============================================================
func _test_counter_like_out_of_range_rejected() -> void:
	print("[B611-RANGE] counter_like_out_of_range_rejected")
	# Both p0/e0 in range=1; first player ATK lands in range
	# (player DMG fired) so the provider triggers the counter.
	# Counter PERFORM_ATTACK source=1, target=0 — they remain
	# adjacent so the counter IS in range and would normally
	# execute. To prove out-of-range rejection at execute, we
	# drive the dispatcher DIRECTLY with a parent DAMAGE_APPLIED
	# whose source/target are too far apart for the counter
	# to reach. This avoids BattleSimulation scheduler noise.
	var w = BattleWorldScript.new(7, 4)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 200, 200, 50, 5, 1)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(6, 3), 200, 200, 20, 5, 1)],
		7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	# Commit a synthetic DAMAGE_APPLIED event whose source/target
	# are far apart (out of range). The provider will then
	# propose a counter that, when executed, MUST be rejected
	# because the reactor (entity 1) cannot reach entity 0.
	var em_event = em.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		1, 0, "e0", "p0", 10)
	var sink: Array = []
	var ctx = EffectContextScript.new(w, rng, em, sink)
	# A permissive ping-pong provider proposes a counter.
	var provider = B611PingPongProvider.new()
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 32
	limits.max_events_per_tick = 100
	limits.max_reactions_per_root = 256
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var dispatcher = TriggerDispatcherScript.new()
	var result = dispatcher.process(
		[em_event], w, rng, em, sink, provider, limits, session)
	_assert(result != null, "dispatcher returned a result")
	# Ping-pong proposed counter (depth 2), but PerformAttack
	# Effect rejected it at execute (source/target out of range).
	# The DAMAGE_APPLIED counter attempt is admitted but the
	# execute attempt fails; the reaction may still count in
	# reactions_executed (B5 contract). The trace must NOT
	# contain a counter DAMAGE_APPLIED or counter ATTACK_RESOLVED
	# because PerformAttack failed before any emission.
	var saw_counter_atk: bool = false
	var saw_counter_dmg: bool = false
	for e in sink:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED:
			saw_counter_atk = true
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			saw_counter_dmg = true
	_assert(not saw_counter_atk,
		"no counter ATTACK_RESOLVED (out-of-range rejected)")
	_assert(not saw_counter_dmg,
		"no counter DAMAGE_APPLIED (out-of-range rejected)")
	# World unchanged: HP unchanged on entity 0.
	_assert(int(w.current_hp_of(0)) == 200,
		"world HP unchanged (effect rejected, no mutation)")


# ============================================================
# 4) root-budget bound — DIRECT DISPATCHER (no BattleSimulation)
#
# Use a ping-pong provider that creates an unbounded reaction
# chain. Set max_reactions_per_root = 3 to bound the chain.
# The first 4 events (root attack + first reaction) plus
# further reaction attempts are bounded by the budget.
# ============================================================
func _test_root_budget_bound_dispatcher() -> void:
	print("[B611-BUDGET] root_budget_bound_dispatcher")
	var w = BattleWorldScript.new(7, 4)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 200, 200, 50, 5, 3)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 200, 200, 20, 5, 3)],
		7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	# Commit the initial root player ATTACK_RESOLVED + its
	# DAMAGE_APPLIED. We feed BOTH into the dispatcher's
	# initial_events so the provider reacts to the DAMAGE_APPLIED.
	var atk_root = em.emit(
		BattleEventTypeScript.ATTACK_RESOLVED,
		0, 1, "p0", "e0", 50)
	# The DAMAGE_APPLIED chain: root attack already triggered;
	# the dispatcher will admit a counter reaction that, when
	# executed, emits its own DAMAGE_APPLIED as an atomic child.
	# To seed the FIRST reaction, we feed the dispatcher only
	# the root DAMAGE_APPLIED.
	# Easier: feed the dispatcher the already-committed
	# root DAMAGE_APPLIED. We have to construct one manually
	# because emit_child requires parent_event_id > 0.
	# Simplest: feed the ATTACK_RESOLVED as initial; provider
	# reacts to it (we'll allow DAMAGE_APPLIED or ATTACK_RESOLVED).
	var provider = B611PingPongProvider.new()
	# Override provider to also react to ATTACK_RESOLVED so the
	# initial_event triggers a reaction. Use a local extension.
	# Easiest: change provider to react on both. We do that
	# inline by subclassing.
	# Simpler: just feed the root DAMAGE_APPLIED via a child
	# emission. emit_child accepts parent_event_id == atk_root.event_id.
	var dmg_root = em.emit_child(
		BattleEventTypeScript.DAMAGE_APPLIED,
		int(atk_root.event_id),
		int(atk_root.root_action_id),
		int(atk_root.chain_depth),
		0, 1, "p0", "e0", 30)
	var sink: Array = []
	var ctx = EffectContextScript.new(w, rng, em, sink)
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 32
	limits.max_events_per_tick = 1000
	limits.max_reactions_per_root = 3
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var dispatcher = TriggerDispatcherScript.new()
	var result = dispatcher.process(
		[dmg_root], w, rng, em, sink, provider, limits, session)
	_assert(result != null, "dispatcher returned non-null")
	_assert(result.truncated == true,
		"root budget hit: result.truncated == true")
	_assert(int(result.reason) == int(DispatchResultScript.REASON_MAX_REACTIONS_PER_ROOT),
		"root budget hit: reason == MAX_REACTIONS_PER_ROOT (got %d)"
		% int(result.reason))
	# All emitted reaction events share the ORIGINAL root_action_id.
	var original_root_id: int = int(dmg_root.root_action_id)
	for e in result.events:
		_assert(int(e.root_action_id) == original_root_id,
			"reaction event id=%d shares original root_action_id"
			% int(e.event_id))
	# No fresh root allowed in the reaction chain.
	# Count distinct root_action_ids across result.events.
	var seen_roots: Dictionary = {}
	for e in result.events:
		seen_roots[int(e.root_action_id)] = true
	_assert(seen_roots.size() == 1,
		"reaction chain emits ZERO fresh roots (got %d distinct roots)"
		% seen_roots.size())


# ============================================================
# 5) depth bound — DIRECT DISPATCHER with atomic PerformAttack
# admission. Prove the dispatcher admits ONE reaction at the
# limit, that the atomic PerformAttackEffect may emit its own
# DAMAGE_APPLIED deeper than the limit, and that the NEXT
# reaction request whose requested depth exceeds the limit is
# rejected with no rollback of the already-committed atomic
# children.
#
# Fixture: max_chain_depth = 2.
#   - Initial DAMAGE_APPLIED at depth 1.
#   - Ping-pong provider proposes counter request at depth 2.
#     Depth 2 is admitted (== max_chain_depth).
#   - PerformAttackEffect atomically commits counter ATK (depth 2)
#     and counter DMG (depth 3). Depth 3 > limit, but this is an
#     INTERNAL atomic child of an already-admitted effect —
#     it remains committed. No rollback.
#   - Ping-pong provider sees counter DMG (depth 3) and proposes
#     next attack request at depth 4. Depth 4 > max_chain_depth=2
#     → REJECTED before execution. result.truncated == true,
#     result.reason == REASON_MAX_DEPTH.
# ============================================================
func _test_depth_bound_dispatcher() -> void:
	print("[B611-DEPTH] depth_bound_dispatcher")
	var w = BattleWorldScript.new(7, 4)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var s = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 200, 200, 50, 5, 3)],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 200, 200, 20, 5, 3)],
		7, 4)
	w.spawn_from_setup(s)
	var rng = DeterministicRngScript.new(0)
	var atk_root = em.emit(
		BattleEventTypeScript.ATTACK_RESOLVED,
		0, 1, "p0", "e0", 50)
	var dmg_root = em.emit_child(
		BattleEventTypeScript.DAMAGE_APPLIED,
		int(atk_root.event_id),
		int(atk_root.root_action_id),
		int(atk_root.chain_depth),
		0, 1, "p0", "e0", 30)
	var hp_before: int = int(w.current_hp_of(0))
	var sink: Array = []
	var provider = B611PingPongProvider.new()
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 2
	limits.max_events_per_tick = 1000
	limits.max_reactions_per_root = 256
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var dispatcher = TriggerDispatcherScript.new()
	var result = dispatcher.process(
		[dmg_root], w, rng, em, sink, provider, limits, session)
	_assert(result != null, "dispatcher returned non-null")
	# Exactly one reaction admitted (the depth-2 counter).
	_assert(int(result.reactions_executed) == 1,
		"depth-bound: exactly 1 reaction admitted (got %d)"
		% int(result.reactions_executed))
	# result.events contains exactly the committed atomic pair.
	_assert(result.events.size() == 2,
		"depth-bound: result.events.size == 2 (atomic pair, got %d)"
		% result.events.size())
	if result.events.size() != 2:
		return
	var counter_atk = result.events[0]
	var counter_dmg = result.events[1]
	_assert(int(counter_atk.type) == BattleEventTypeScript.ATTACK_RESOLVED,
		"depth-bound: counter ATK type")
	_assert(int(counter_dmg.type) == BattleEventTypeScript.DAMAGE_APPLIED,
		"depth-bound: counter DMG type")
	_assert(int(counter_atk.chain_depth) == 2,
		"depth-bound: counter ATK chain_depth == 2 (admitted at limit)")
	_assert(int(counter_dmg.chain_depth) == 3,
		"depth-bound: counter DMG chain_depth == 3 "
		+ "(atomic child, > limit, remains committed)")
	# Both share the ORIGINAL root_action_id (no fresh root).
	var original_root_id: int = int(atk_root.root_action_id)
	_assert(int(counter_atk.root_action_id) == original_root_id,
		"depth-bound: counter ATK shares original root_action_id")
	_assert(int(counter_dmg.root_action_id) == original_root_id,
		"depth-bound: counter DMG shares original root_action_id")
	# Parent chain:
	# counter ATK.parent_event_id == initial DMG.event_id (depth 2
	# admitted from initial DMG depth 1).
	_assert(int(counter_atk.parent_event_id) == int(dmg_root.event_id),
		"depth-bound: counter ATK.parent_event_id == initial DMG.event_id")
	_assert(int(counter_dmg.parent_event_id) == int(counter_atk.event_id),
		"depth-bound: counter DMG.parent_event_id == counter ATK.event_id")
	# World: player HP must reflect exactly ONE counter damage.
	# 20-5 raw → 13 dmg applied (HP 200 → 187). If a SECOND counter
	# were silently executed, HP would be lower (200 - 2*13 = 174).
	# We assert HP decreased by EXACTLY one counter damage amount.
	var hp_after: int = int(w.current_hp_of(0))
	var expected_dmg: int = int(w.attack_of(1)) * 100 / (100 + int(w.defense_of(0)))
	_assert(hp_after == hp_before - expected_dmg,
		"depth-bound: player HP reflects exactly ONE counter "
		+ "damage (before=%d after=%d expected_decr=%d)"
		% [hp_before, hp_after, expected_dmg])
	# No second reaction ATTACK_RESOLVED in result.events.
	# (result.events.size == 2 already guarantees exactly one
	# counter pair; if the depth-4 request had been admitted we
	# would have a third event.)
	# NEXT reaction was rejected: truncated + MAX_DEPTH.
	_assert(result.truncated == true,
		"depth-bound: result.truncated == true "
		+ "(next depth-4 reaction request rejected)")
	_assert(int(result.reason) == int(DispatchResultScript.REASON_MAX_DEPTH),
		"depth-bound: reason == MAX_DEPTH (got %d)"
		% int(result.reason))
	# Session-level proof: keep the local session reference.
	_assert(session.truncated == true,
		"depth-bound: session.truncated == true")
	_assert(int(session.first_reason) == int(DispatchResultScript.REASON_MAX_DEPTH),
		"depth-bound: session.first_reason == MAX_DEPTH (got %d)"
		% int(session.first_reason))
	# Sink contains the admitted counter atomic pair (counter
	# ATK + counter DMG). The initial event itself lives outside
	# result.events by B5 contract.
	_assert(sink.size() == 2,
		"depth-bound: sink contains the counter atomic pair (got %d)"
		% sink.size())


# ============================================================
# 6) 20-run reaction-enabled determinism with full 14-field
# Uses the one-shot provider so the trace is stable across
# runs (no ping-pong, no budget dependency).
# ============================================================
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

func _dict_eq14(a, b) -> bool:
	for k in a.keys():
		if not b.has(k):
			return false
		if str(a[k]) != str(b[k]):
			return false
	return true

func _test_20_run_determinism_reaction_enabled() -> void:
	print("[B611-DET] 20_run_determinism_reaction_enabled")
	var first_norm: Array = []
	var first_hp_p0: int = -1
	var first_hp_e0: int = -1
	var first_pos_p0: String = ""
	var first_pos_e0: String = ""
	var first_result: Dictionary = {}
	var first_rng: Dictionary = {}
	var first_emit_id: int = -1
	var first_emit_root: int = -1
	var first_inv: int = -1
	for run in 20:
		var sim = BattleSimulationScript.new()
		var provider = B611OneShotCounterProvider.new()
		var s = BattleSetupScript.new(42,
			[BattleUnitSetupScript.new(
				"p0", &"warrior", 0, Vector2i(0, 0), 200, 200, 50, 5, 3)],
			[BattleUnitSetupScript.new(
				"e0", &"orc", 1, Vector2i(0, 1), 200, 200, 20, 5, 3)],
			7, 4)
		# CANONICAL B6 LIFECYCLE: initialize FIRST, then apply
		# provider (initialize() resets the trigger provider to
		# the no-op default).
		_assert(sim.initialize(s),
			"run %d initialize ok" % run)
		sim.set_trigger_provider(provider)
		sim.set_max_ticks(8)
		var events: Array = []
		while not sim.is_finished():
			events.append_array(sim.step_tick())
		# Per-run uniqueness.
		var seen: Dictionary = {}
		var dup: Array = []
		for e in events:
			var id: int = int(e.event_id)
			if seen.has(id):
				dup.append(id)
			seen[id] = true
		_assert(dup.size() == 0,
			"run %d has duplicate event_ids: %s" % [run, str(dup)])
		# ============================================================
		# Provider-actually-fired guard. The one-shot provider
		# exposes `fired` (boolean) and `invocations` (count of
		# semantic discovery calls that matched the candidate
		# filter). Both must be in their post-fire state for the
		# trace to contain a real counter reaction.
		# ============================================================
		_assert(provider.fired == true,
			"run %d provider.fired == true (got %s)"
			% [run, str(provider.fired)])
		_assert(int(provider.invocations) == 1,
			"run %d provider.invocations == 1 (got %d)"
			% [run, int(provider.invocations)])
		# ============================================================
		# Causal counter identification. The player's scheduled
		# normal attack and the enemy's later scheduled normal
		# attack BOTH have source_entity in {0, 1}, so the
		# "source_entity == 1" check is INSUFFICIENT. We must
		# identify the reaction counter by following the
		# parent_event_id / root_action_id chain from the FIRST
		# player root.
		#
		# player_attack:    ATK src=0 tgt=1 parent=-1   depth=0
		# player_damage:    DMG src=0 tgt=1 parent=atk  depth=1
		# counter_attack:   ATK src=1 tgt=0 parent=dmg  depth=2
		# counter_damage:   DMG src=1 tgt=0 parent=catk  depth=3
		# All four share the SAME root_action_id (the player's).
		# A later enemy scheduled attack would have parent=-1,
		# depth=0, and a DIFFERENT root_action_id — distinguishing
		# it from the reaction counter.
		# ============================================================
		var player_atk = null
		var player_dmg = null
		var counter_atk = null
		var counter_dmg = null
		var enemy_sched_atk = null
		for e in events:
			if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
					and int(e.source_entity) == 0 \
					and int(e.target_entity) == 1 \
					and int(e.chain_depth) == 0 \
					and int(e.parent_event_id) == -1:
				if player_atk == null:
					player_atk = e
			if player_atk != null and player_dmg == null \
					and int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
					and int(e.parent_event_id) == int(player_atk.event_id) \
					and int(e.root_action_id) == int(player_atk.root_action_id):
				player_dmg = e
			if player_dmg != null and counter_atk == null \
					and int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
					and int(e.source_entity) == 1 \
					and int(e.target_entity) == 0 \
					and int(e.parent_event_id) == int(player_dmg.event_id) \
					and int(e.root_action_id) == int(player_atk.root_action_id) \
					and int(e.chain_depth) == int(player_dmg.chain_depth) + 1:
				counter_atk = e
			if counter_atk != null and counter_dmg == null \
					and int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
					and int(e.source_entity) == 1 \
					and int(e.target_entity) == 0 \
					and int(e.parent_event_id) == int(counter_atk.event_id) \
					and int(e.root_action_id) == int(player_atk.root_action_id) \
					and int(e.chain_depth) == int(counter_atk.chain_depth) + 1:
				counter_dmg = e
			if player_atk != null \
					and int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
					and int(e.source_entity) == 1 \
					and int(e.target_entity) == 0 \
					and int(e.parent_event_id) == -1 \
					and int(e.chain_depth) == 0 \
					and int(e.event_id) != int(counter_atk.event_id if counter_atk != null else -1):
				if enemy_sched_atk == null:
					enemy_sched_atk = e
		_assert(player_atk != null,
			"run %d: player ATK root found" % run)
		_assert(player_dmg != null,
			"run %d: player DMG found under player ATK" % run)
		_assert(counter_atk != null,
			"run %d: counter ATK found under player DMG (causally identified via parent_event_id + root_action_id)"
			% run)
		_assert(counter_dmg != null,
			"run %d: counter DMG found under counter ATK" % run)
		_assert(counter_atk != null
				and int(counter_atk.chain_depth) == 2,
			"run %d: counter ATK chain_depth == 2" % run)
		_assert(counter_dmg != null
				and int(counter_dmg.chain_depth) == 3,
			"run %d: counter DMG chain_depth == 3" % run)
		# Reaction chain shares the ORIGINAL player root.
		_assert(int(counter_atk.root_action_id) == int(player_atk.root_action_id),
			"run %d: counter ATK root_action_id == player ATK root_action_id"
			% run)
		_assert(int(counter_dmg.root_action_id) == int(player_atk.root_action_id),
			"run %d: counter DMG root_action_id == player ATK root_action_id"
			% run)
		# If a later enemy scheduled attack is present (e.g.
		# enemy has range and fires next tick), it must be
		# an INDEPENDENT root, distinct from the player root.
		if enemy_sched_atk != null:
			_assert(int(enemy_sched_atk.parent_event_id) == -1
					and int(enemy_sched_atk.chain_depth) == 0,
				"run %d: enemy scheduled ATTACK_RESOLVED is independent root"
				% run)
			_assert(int(enemy_sched_atk.root_action_id) != int(player_atk.root_action_id),
				"run %d: enemy scheduled root != player root (reaction child vs independent scheduler root)"
				% run)
		# Capture baseline.
		var norm: Array = []
		for e in events:
			norm.append(_normalize_event_14(e))
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
		var inv: int = int(provider.invocations)
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
			first_inv = inv
			continue
		# Compare each subsequent run vs baseline.
		if norm.size() != first_norm.size():
			_assert(false,
				"run %d trace length differs (got %d, base %d)"
				% [run, norm.size(), first_norm.size()])
			return
		for i in norm.size():
			if not _dict_eq14(norm[i], first_norm[i]):
				_assert(false,
					"run %d event[%d] 14-field mismatch"
					% [run, i])
				return
		_assert(hp_p0 == first_hp_p0,
			"run %d p0 HP %d != base %d"
			% [run, hp_p0, first_hp_p0])
		_assert(hp_e0 == first_hp_e0,
			"run %d e0 HP %d != base %d"
			% [run, hp_e0, first_hp_e0])
		_assert(pos_p0 == first_pos_p0,
			"run %d p0 pos differs" % run)
		_assert(pos_e0 == first_pos_e0,
			"run %d e0 pos differs" % run)
		_assert(int(rng.get("seed", -1)) ==
				int(first_rng.get("seed", -2)),
			"run %d RNG seed mismatch" % run)
		_assert(int(rng.get("draw_count", -1)) ==
				int(first_rng.get("draw_count", -2)),
			"run %d RNG draw_count mismatch" % run)
		_assert(str(rng.get("state", "")) ==
				str(first_rng.get("state", "")),
			"run %d RNG state mismatch" % run)
		_assert(emit_id == first_emit_id,
			"run %d emitter peek_next_event_id mismatch" % run)
		_assert(emit_root == first_emit_root,
			"run %d emitter peek_next_root_action_id mismatch" % run)
		for k in first_result.keys():
			if int(result_d.get(k, -1)) != int(first_result[k]):
				_assert(false, "run %d result[%s] mismatch" % [run, k])
				return
		_assert(inv == first_inv,
			"run %d provider invocations %d != base %d"
			% [run, inv, first_inv])
	_assert(true, "20 runs identical on full 14 fields + HP + pos + RNG + emitter + provider + result")
