extends SceneTree
## B6.2b / Gauntlet D — Counterattack adversarial matrix +
## 20-run reaction-enabled determinism + no-reaction parity.

const BattleSimulationScript = preload(
	"res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload(
	"res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload(
	"res://core/battle_ecs/battle_unit_setup.gd")
const BattleSetupBuilderScript = preload(
	"res://core/battle_ecs/battle_setup_builder.gd")
const BattleWorldScript = preload(
	"res://core/battle_ecs/world/battle_world.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const DeterministicRngScript = preload(
	"res://core/rng/deterministic_rng.gd")
const ContentDBScript = preload(
	"res://core/utils/content_db.gd")
const ContentReactionProviderScript = preload(
	"res://core/battle_ecs/triggers/content_reaction_provider.gd")
const RunDomainStateScript = preload(
	"res://core/progression/run_domain_state.gd")
const RunUnitScript = preload(
	"res://core/progression/run_unit.gd")
const StatusInstanceScript = preload(
	"res://core/battle_ecs/status/status_instance.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	await _test_normal_counter_exact_trace_ancestry()
	await _test_no_counter_counter_loop_both_sides_own()
	await _test_stunned_reactor_rejected_at_execute()
	await _test_out_of_range_counter_rejected_at_execute()
	await _test_lethal_base_attack_no_counter()
	await _test_lethal_counterattack_kills_attacker()
	await _test_non_attack_events_never_trigger()
	await _test_owner_match_prevents_borrowing()
	await _test_react_to_attack_excludes_counter_chain()
	await _test_20_run_shipping_determinism()
	await _test_no_reaction_parity_with_default_provider()
	print("\n=== B6.2b counterattack adversarial + determinism: %d pass / %d fail ===\n" % [_passed, _failed])
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


func _guardian_setup() -> Dictionary:
	# Save and restore guardian reaction_ids.
	var guardian_def = ContentDBScript.get_by_id_for_type(
		"units", &"guardian")
	var original = Array(guardian_def.reaction_ids) as Array[StringName]
	var state = RunDomainStateScript.new()
	state.seed = 42
	state.round_index = 1
	state.meta_modifiers = {"rest_attack_bonus": 0, "shrine_attack_bonus": 0}
	state.create_unit(&"guardian", 250, RunUnitScript.LOCATION_BOARD)
	var setup = BattleSetupBuilderScript.build(state, 42, 1, 7, 4)
	return {"setup": setup, "guardian_def": guardian_def,
		"original": original, "state": state}


func _run_battle(setup) -> Array:
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim.set_max_ticks(8)
	var events: Array = []
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	return events


# ============================================================
# D1 — Normal counter exact trace ancestry
# ============================================================
func _test_normal_counter_exact_trace_ancestry() -> void:
	print("[B62B-D1] normal_counter_exact_trace_ancestry")
	var C = _guardian_setup()
	var events: Array = _run_battle(C["setup"])
	# Find enemy normal ATTACK_RESOLVED (target=0 guardian) that
	# triggered a counter.
	var normal_atk = null
	var counter_atk = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and int(e.target_entity) == 0 \
				and int(e.source_entity) == 1 \
				and int(e.parent_event_id) == -1 \
				and int(e.chain_depth) == 0:
			for child in events:
				if int(child.type) == BattleEventTypeScript.ATTACK_RESOLVED \
						and int(child.parent_event_id) == int(e.event_id) \
						and int(child.source_entity) == 0 \
						and String(child.tag) == "counterattack":
					normal_atk = e
					counter_atk = child
					break
			if normal_atk != null:
				break
	_assert(normal_atk != null and counter_atk != null,
		"normal enemy ATK + counter ATK found")
	if normal_atk == null or counter_atk == null:
		(C["guardian_def"] as Resource).reaction_ids = C["original"]
		return
	# Verify ancestry tree:
	#   normal ATK (depth 0, fresh root)
	#   normal DMG (depth 1, child of normal ATK)
	#   counter ATK (depth 1, child of normal ATK, source=guardian)
	#   counter DMG (depth 2, child of counter ATK)
	_assert(int(normal_atk.chain_depth) == 0,
		"normal ATK depth == 0")
	_assert(int(normal_atk.parent_event_id) == -1,
		"normal ATK parent == -1 (root)")
	# counter ATK depth = normal ATK depth + 1 (1).
	_assert(int(counter_atk.chain_depth) == 1,
		"counter ATK depth == 1 (sibling to normal DMG)")
	# counter ATK shares normal ATK's root_action_id.
	_assert(int(counter_atk.root_action_id) == int(normal_atk.root_action_id),
		"counter ATK shares normal ATK root_action_id")
	# counter ATK parent = normal ATK.event_id.
	_assert(int(counter_atk.parent_event_id) == int(normal_atk.event_id),
		"counter ATK parent == normal ATK.event_id")
	# counter ATK source=0, target=1 (enemy), tag=counterattack.
	_assert(int(counter_atk.source_entity) == 0,
		"counter ATK source == 0 (guardian)")
	_assert(int(counter_atk.target_entity) == 1,
		"counter ATK target == 1 (enemy)")
	_assert(String(counter_atk.tag) == "counterattack",
		"counter ATK tag == 'counterattack'")
	# counter DMG: child of counter ATK.
	var counter_dmg = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and int(e.parent_event_id) == int(counter_atk.event_id) \
				and int(e.root_action_id) == int(normal_atk.root_action_id):
			counter_dmg = e
			break
	_assert(counter_dmg != null, "counter DMG under counter ATK")
	if counter_dmg != null:
		_assert(String(counter_dmg.tag) == "counterattack",
			"counter DMG tag == 'counterattack'")
		_assert(int(counter_dmg.chain_depth) == 2,
			"counter DMG depth == 2")
	# No counter-counter (counter ATK must not have a counter child).
	for e in events:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and int(e.source_entity) == 1 \
				and int(e.parent_event_id) == int(counter_atk.event_id) \
				and String(e.tag) == "counterattack":
			_assert(false, "counter-counter detected (semantic loop broken)")
			(C["guardian_def"] as Resource).reaction_ids = C["original"]
			return
	_assert(true, "no counter-counter chain")
	(C["guardian_def"] as Resource).reaction_ids = C["original"]


# ============================================================
# B3 + E4 — Both sides own counterattack: exactly one
# counter fires (semantic loop breaker)
# ============================================================
func _test_no_counter_counter_loop_both_sides_own() -> void:
	print("[B62B-B3] no_counter_counter_loop_both_sides_own")
	# CORRECT fixture: BOTH sides own counterattack from the
	# start. Construct BattleSetup directly (NOT via
	# BattleSetupBuilder + post-build def mutation, which is
	# invisible to B6.2a snapshot semantics).
	# Use high HP so nobody dies during the first tick.
	var BattleSetupScript = preload(
		"res://core/battle_ecs/battle_setup.gd")
	var BattleUnitSetupScript = preload(
		"res://core/battle_ecs/battle_unit_setup.gd")
	var player = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 500, 500, 50, 5, 3,
		[&"counterattack"])
	var enemy = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 3), 500, 500, 20, 5, 3,
		[&"counterattack"])
	var setup = BattleSetupScript.new(42, [player], [enemy], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim.set_max_ticks(1)
	var events: Array = []
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	# 1) Both sides genuinely own counterattack (verified by
	# world snapshot — defensive copies, not the caller arrays).
	var player_reactions: Array = sim.world().reaction_ids_of(0)
	var enemy_reactions: Array = sim.world().reaction_ids_of(1)
	_assert(player_reactions.size() == 1
			and String(player_reactions[0]) == "counterattack",
		"player entity 0 owns counterattack (got %s)"
		% str(player_reactions))
	_assert(enemy_reactions.size() == 1
			and String(enemy_reactions[0]) == "counterattack",
		"enemy entity 1 owns counterattack (got %s)"
		% str(enemy_reactions))
	# 2) Counter-counter prohibition: NO counter ATTACK child
	# of any counter ATTACK. Sequential walk (parent appears
	# earlier in trace).
	var seen: Dictionary = {}
	for e in events:
		seen[int(e.event_id)] = e
	var counter_counter_count: int = 0
	for e in events:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and String(e.tag) == "counterattack":
			for child in events:
				if int(child.parent_event_id) == int(e.event_id) \
						and int(child.type) == BattleEventTypeScript.ATTACK_RESOLVED \
						and String(child.tag) == "counterattack":
					counter_counter_count += 1
	_assert(counter_counter_count == 0,
		"both sides own counterattack: zero counter-counter events (got %d)"
			% counter_counter_count)
	# 3) One response to each independent normal attack.
	# Find normal root ATK events (parent=-1, depth=0, tag="").
	var normal_root_atks: Array = []
	for e in events:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and int(e.parent_event_id) == -1 \
				and int(e.chain_depth) == 0 \
				and String(e.tag) == "":
			normal_root_atks.append(e)
	_assert(normal_root_atks.size() >= 2,
		"at least 2 normal root ATKs in first tick (got %d)"
		% normal_root_atks.size())
	# For each normal root ATK, find a counter ATK child that
	# shares the same root_action_id and depth=1.
	var normal_with_response: int = 0
	for n in normal_root_atks:
		for c in events:
			if int(c.type) == BattleEventTypeScript.ATTACK_RESOLVED \
					and String(c.tag) == "counterattack" \
					and int(c.parent_event_id) == int(n.event_id) \
					and int(c.root_action_id) == int(n.root_action_id) \
					and int(c.chain_depth) == int(n.chain_depth) + 1:
				normal_with_response += 1
				break
	_assert(normal_with_response == normal_root_atks.size(),
		"every normal root ATK gets a counter child (got %d/%d)"
		% [normal_with_response, normal_root_atks.size()])
	# 4) Root semantics: each normal root has a fresh
	# root_action_id. Counters share parent's root_action_id.
	var root_action_ids: Dictionary = {}
	for n in normal_root_atks:
		root_action_ids[int(n.root_action_id)] = true
	_assert(root_action_ids.size() == normal_root_atks.size(),
		"each normal root has a unique root_action_id (got %d for %d roots)"
		% [root_action_ids.size(), normal_root_atks.size()])
	# 5) No dispatcher truncation — semantic loop breaker
	# must be the only thing stopping counter-counter.
	var dispatch_result = sim._last_trigger_dispatch_result
	_assert(dispatch_result != null,
		"sim._last_trigger_dispatch_result populated")
	if dispatch_result != null:
		_assert(bool(dispatch_result.truncated) == false,
			"dispatcher NOT truncated (got truncated=true)")
		_assert(int(dispatch_result.reason) == 0,
			"dispatcher reason == REASON_NONE (got %d)"
			% int(dispatch_result.reason))


# ============================================================
# D4 — Stunned reactor rejected at execute
# ============================================================
func _test_stunned_reactor_rejected_at_execute() -> void:
	print("[B62B-D4] stunned_reactor_rejected_at_execute")
	# CORRECT fixture: use direct dispatcher.
	# 1) Counter owner B has real Stun (blocks_actions == true).
	# 2) Incoming normal ATTACK_RESOLVED is created.
	# 3) Provider discovers intent and returns a TriggerReaction.
	# 4) Dispatcher admits execution attempt
	#    (reactions_executed == 1).
	# 5) PerformAttackEffect rejects because blocks_actions.
	# 6) sink has no counter events; attacker HP unchanged.
	var BattleWorldScript = preload(
		"res://core/battle_ecs/world/battle_world.gd")
	var BattleEventEmitterScript = preload(
		"res://core/battle_ecs/events/battle_event_emitter.gd")
	var BattleSetupScript = preload(
		"res://core/battle_ecs/battle_setup.gd")
	var BattleUnitSetupScript = preload(
		"res://core/battle_ecs/battle_unit_setup.gd")
	var TriggerLimitsScript = preload(
		"res://core/battle_ecs/triggers/trigger_limits.gd")
	var TriggerDispatchSessionScript = preload(
		"res://core/battle_ecs/triggers/trigger_dispatch_session.gd")
	var TriggerDispatcherScript = preload(
		"res://core/battle_ecs/triggers/trigger_dispatcher.gd")
	var StatusInstanceScript = preload(
		"res://core/battle_ecs/status/status_instance.gd")
	var StatQueryScript = preload(
		"res://core/battle_ecs/status/stat_query.gd")
	var em = BattleEventEmitterScript.new()
	em.reset()
	var w = BattleWorldScript.new(7, 4)
	var attacker = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1, [])
	var reactor = BattleUnitSetupScript.new(
		"e0", &"warrior", 1, Vector2i(0, 1), 100, 100, 50, 5, 1,
		[&"counterattack"])
	w.spawn_from_setup(BattleSetupScript.new(
		42, [attacker], [reactor], 7, 4))
	# Apply real Stun on reactor (entity 1).
	var container = w.create_status_container(1)
	var stun_inst = StatusInstanceScript.new(&"stun", 0, 1, 1, 99, 0)
	container.add(stun_inst, "unique", 1)
	_assert(StatQueryScript.blocks_actions(w, 1) == true,
		"stun: blocks_actions == true before dispatch")
	# Incoming attack.
	var atk_event = em.emit(
		BattleEventTypeScript.ATTACK_RESOLVED,
		0, 1, "p0", "e0", 50)
	var sink: Array = []
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 32
	limits.max_events_per_tick = 100
	limits.max_reactions_per_root = 256
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var dispatcher = TriggerDispatcherScript.new()
	var prov = preload(
		"res://core/battle_ecs/triggers/content_reaction_provider.gd"
	).new()
	var rng = DeterministicRngScript.new(0)
	var hp_a_before: int = int(w.current_hp_of(0))
	var emit_before: int = int(em.peek_next_event_id())
	var result = dispatcher.process(
		[atk_event], w, rng, em, sink, prov, limits, session)
	_assert(int(result.reactions_executed) == 1,
		"stun: provider intent ADMITTED (reactions_executed=1, got %d)"
		% int(result.reactions_executed))
	var counter_atk_count: int = 0
	var counter_dmg_count: int = 0
	for ev in sink:
		if int(ev.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and String(ev.tag) == "counterattack":
			counter_atk_count += 1
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and String(ev.tag) == "counterattack":
			counter_dmg_count += 1
	_assert(counter_atk_count == 0,
		"stun: sink contains ZERO counter ATTACK_RESOLVED (got %d)"
		% counter_atk_count)
	_assert(counter_dmg_count == 0,
		"stun: sink contains ZERO counter DAMAGE_APPLIED (got %d)"
		% counter_dmg_count)
	_assert(int(w.current_hp_of(0)) == hp_a_before,
		"stun: attacker HP unchanged (before=%d after=%d)"
		% [hp_a_before, int(w.current_hp_of(0))])
	_assert(int(em.peek_next_event_id()) == emit_before,
		"stun: emitter next_event_id unchanged (before=%d after=%d)"
		% [emit_before, int(em.peek_next_event_id())])


# ============================================================
# D5 — Out-of-range counter rejected
# ============================================================
func _test_out_of_range_counter_rejected_at_execute() -> void:
	print("[B62B-D5] out_of_range_counter_rejected_at_execute")
	# CORRECT fixture: incoming attack CAN happen, but the
	# counter owner cannot reach the attacker.
	# A: attacker, team 0, position (0,0), attack_range=3
	# B: counter owner, team 1, position (3,0), attack_range=1
	# A can reach B (distance 3 <= 3).
	# B cannot reach A (distance 3 > 1).
	# Therefore: provider discovers Counterattack intent,
	# dispatcher ADMITS an execution attempt (reactions_executed
	# == 1), but PerformAttackEffect rejects because B is
	# out of range from A.
	#
	# Use direct dispatcher (not full sim) to isolate the
	# provider-intent / executor-rejection path.
	var BattleWorldScript = preload(
		"res://core/battle_ecs/world/battle_world.gd")
	var BattleEventEmitterScript = preload(
		"res://core/battle_ecs/events/battle_event_emitter.gd")
	var BattleSetupScript = preload(
		"res://core/battle_ecs/battle_setup.gd")
	var BattleUnitSetupScript = preload(
		"res://core/battle_ecs/battle_unit_setup.gd")
	var TriggerLimitsScript = preload(
		"res://core/battle_ecs/triggers/trigger_limits.gd")
	var TriggerDispatchSessionScript = preload(
		"res://core/battle_ecs/triggers/trigger_dispatch_session.gd")
	var TriggerDispatcherScript = preload(
		"res://core/battle_ecs/triggers/trigger_dispatcher.gd")
	var em = BattleEventEmitterScript.new()
	em.reset()
	var w = BattleWorldScript.new(7, 4)
	# A: warrior with attack_range=3 (override default 1).
	var a = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 3, [])
	# B: counter owner warrior with attack_range=1 (default).
	var b = BattleUnitSetupScript.new(
		"e0", &"warrior", 1, Vector2i(3, 0), 100, 100, 50, 5, 1,
		[&"counterattack"])
	w.spawn_from_setup(BattleSetupScript.new(
		42, [a], [b], 7, 4))
	# Sanity: A's attack_range allows reaching B (distance 3).
	_assert(int(w.attack_range_of(0)) >= 3,
		"A attack_range >= 3 (got %d)" % int(w.attack_range_of(0)))
	# B's attack_range is 1, so it cannot reach A.
	_assert(int(w.attack_range_of(1)) == 1,
		"B attack_range == 1 (got %d)" % int(w.attack_range_of(1)))
	# Synthesize a real root ATTACK_RESOLVED from A -> B.
	var atk_event = em.emit(
		BattleEventTypeScript.ATTACK_RESOLVED,
		0, 1, "p0", "e0", 50)
	var sink: Array = []
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 32
	limits.max_events_per_tick = 100
	limits.max_reactions_per_root = 256
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var dispatcher = TriggerDispatcherScript.new()
	var prov = preload(
		"res://core/battle_ecs/triggers/content_reaction_provider.gd"
	).new()
	var rng = DeterministicRngScript.new(0)
	# Snapshot HP/positions before dispatch.
	var hp_a_before: int = int(w.current_hp_of(0))
	var hp_b_before: int = int(w.current_hp_of(1))
	var pos_a_before: Vector2i = w.position_of(0)
	var pos_b_before: Vector2i = w.position_of(1)
	var emit_before: int = int(em.peek_next_event_id())
	var root_before: int = int(em.peek_next_root_action_id())
	var result = dispatcher.process(
		[atk_event], w, rng, em, sink, prov, limits, session)
	# 1) Provider discovered a Counterattack intent.
	_assert(int(result.reactions_executed) == 1,
		"out-of-range: provider intent ADMITTED (reactions_executed=1, got %d)"
		% int(result.reactions_executed))
	# 2) BUT PerformAttackEffect rejected because B is out of
	# range from A. Therefore no counter events committed.
	var counter_atk_count: int = 0
	var counter_dmg_count: int = 0
	for ev in sink:
		if int(ev.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and String(ev.tag) == "counterattack":
			counter_atk_count += 1
		if int(ev.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and String(ev.tag) == "counterattack":
			counter_dmg_count += 1
	_assert(counter_atk_count == 0,
		"out-of-range: sink contains ZERO counter ATTACK_RESOLVED (got %d)"
		% counter_atk_count)
	_assert(counter_dmg_count == 0,
		"out-of-range: sink contains ZERO counter DAMAGE_APPLIED (got %d)"
		% counter_dmg_count)
	# 3) State unchanged: HP and positions identical.
	_assert(int(w.current_hp_of(0)) == hp_a_before,
		"out-of-range: A HP unchanged (before=%d after=%d)"
		% [hp_a_before, int(w.current_hp_of(0))])
	_assert(int(w.current_hp_of(1)) == hp_b_before,
		"out-of-range: B HP unchanged (before=%d after=%d)"
		% [hp_b_before, int(w.current_hp_of(1))])
	_assert(w.position_of(0) == pos_a_before,
		"out-of-range: A position unchanged")
	_assert(w.position_of(1) == pos_b_before,
		"out-of-range: B position unchanged")
	# 4) No new emitter IDs allocated by failed execution.
	_assert(int(em.peek_next_event_id()) == emit_before,
		"out-of-range: emitter next_event_id unchanged (before=%d after=%d)"
		% [emit_before, int(em.peek_next_event_id())])
	_assert(int(em.peek_next_root_action_id()) == root_before,
		"out-of-range: emitter next_root_action_id unchanged")


# ============================================================
# BLOCKER 3 — Lethal base attack: defender dead BEFORE
# trigger discovery. No counter.
# ============================================================
func _test_lethal_base_attack_no_counter() -> void:
	print("[B62B-LBASE] lethal_base_attack_no_counter")
	var BattleSetupScript = preload(
		"res://core/battle_ecs/battle_setup.gd")
	var BattleUnitSetupScript = preload(
		"res://core/battle_ecs/battle_unit_setup.gd")
	# Player attacker: high attack, no reaction.
	var player = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 999, 5, 1, [])
	# Enemy defender: low HP, owns counterattack.
	var enemy = BattleUnitSetupScript.new(
		"e0", &"warrior", 1, Vector2i(0, 1), 10, 10, 20, 5, 1,
		[&"counterattack"])
	var setup = BattleSetupScript.new(42, [player], [enemy], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim.set_max_ticks(2)
	var events: Array = []
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	# 1) Base chain present: ATTACK_RESOLVED -> DAMAGE_APPLIED ->
	# UNIT_DIED for the enemy.
	var enemy_atk: int = 0
	var enemy_dmg: int = 0
	var enemy_died: int = 0
	for e in events:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and int(e.target_entity) == 1:
			enemy_atk += 1
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and int(e.target_entity) == 1:
			enemy_dmg += 1
		if int(e.type) == BattleEventTypeScript.UNIT_DIED \
				and int(e.event_id) >= 0 \
				and int(e.target_entity) == 1:
			enemy_died += 1
	_assert(enemy_atk >= 1,
		"lethal base: at least one ATK_RESOLVED targeting enemy (got %d)"
		% enemy_atk)
	_assert(enemy_dmg >= 1,
		"lethal base: at least one DAMAGE_APPLIED targeting enemy (got %d)"
		% enemy_dmg)
	_assert(enemy_died >= 1,
		"lethal base: enemy UNIT_DIED observed (got %d)" % enemy_died)
	# 2) NO counter events at all (defender dead before
	# trigger discovery evaluates ownership).
	var counter_atk: int = 0
	var counter_dmg: int = 0
	for e in events:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and String(e.tag) == "counterattack":
			counter_atk += 1
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and String(e.tag) == "counterattack":
			counter_dmg += 1
	_assert(counter_atk == 0,
		"lethal base: ZERO counter ATTACK_RESOLVED (got %d)" % counter_atk)
	_assert(counter_dmg == 0,
		"lethal base: ZERO counter DAMAGE_APPLIED (got %d)" % counter_dmg)
	# 3) Enemy is actually dead.
	_assert(sim.world().is_alive(1) == false,
		"lethal base: enemy entity 1 is dead at battle end")


# ============================================================
# BLOCKER 4 — Lethal counterattack: counter DMG kills the
# original attacker; dead attacker MUST NOT later scheduler.
# ============================================================
func _test_lethal_counterattack_kills_attacker() -> void:
	print("[B62B-LCTR] lethal_counterattack_kills_attacker")
	var BattleSetupScript = preload(
		"res://core/battle_ecs/battle_setup.gd")
	var BattleUnitSetupScript = preload(
		"res://core/battle_ecs/battle_unit_setup.gd")
	# Player: low HP, low attack, no reaction.
	var player = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 10, 10, 10, 5, 1, [])
	# Enemy: enough HP to survive base hit, very high attack,
	# owns counterattack.
	var enemy = BattleUnitSetupScript.new(
		"e0", &"warrior", 1, Vector2i(0, 1), 200, 200, 999, 5, 1,
		[&"counterattack"])
	var setup = BattleSetupScript.new(42, [player], [enemy], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	sim.set_max_ticks(4)
	var events: Array = []
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	# 1) Player normal ATK + DMG present (tag=""), enemy
	# counter ATK + DMG + UNIT_DIED present (tag="counterattack").
	var normal_atk: int = 0
	var normal_dmg: int = 0
	var counter_atk: int = 0
	var counter_dmg: int = 0
	var counter_died: int = 0
	for e in events:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED:
			if String(e.tag) == "":
				normal_atk += 1
			elif String(e.tag) == "counterattack":
				counter_atk += 1
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED:
			if String(e.tag) == "":
				normal_dmg += 1
			elif String(e.tag) == "counterattack":
				counter_dmg += 1
		if int(e.type) == BattleEventTypeScript.UNIT_DIED \
				and String(e.tag) == "counterattack":
			counter_died += 1
	_assert(normal_atk >= 1,
		"lethal counter: normal ATK present (got %d)" % normal_atk)
	_assert(normal_dmg >= 1,
		"lethal counter: normal DMG present (got %d)" % normal_dmg)
	_assert(counter_atk >= 1,
		"lethal counter: counter ATK present (got %d)" % counter_atk)
	_assert(counter_dmg >= 1,
		"lethal counter: counter DMG present (got %d)" % counter_dmg)
	_assert(counter_died >= 1,
		"lethal counter: counter UNIT_DIED tagged counterattack (got %d)"
		% counter_died)
	# 2) Player (attacker) is dead at battle end.
	_assert(sim.world().is_alive(0) == false,
		"lethal counter: player entity 0 is dead")
	# 3) No LATER root ATTACK_RESOLVED by the enemy AFTER the
	# counterattack killed the player. natural_after_player
	# becomes true once player is dead.
	# Find the counter UNIT_DIED event's tick. Any enemy root
	# ATK_RESOLVED with tick > that tick must NOT exist.
	var counter_died_tick: int = -1
	for e in events:
		if int(e.type) == BattleEventTypeScript.UNIT_DIED \
				and String(e.tag) == "counterattack":
			counter_died_tick = int(e.tick)
			break
	_assert(counter_died_tick >= 0,
		"lethal counter: counter UNIT_DIED tick recorded")
	if counter_died_tick >= 0:
		for e in events:
			if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
					and int(e.source_entity) == 1 \
					and int(e.parent_event_id) == -1 \
					and int(e.tick) > counter_died_tick:
				_assert(false,
					"lethal counter: enemy root ATK after counter UNIT_DIED "
					+ "(tick=%d, eid=%d)" % [int(e.tick), int(e.event_id)])
				return
		_assert(true,
			"lethal counter: enemy never scheduled another root ATK after counter UNIT_DIED")


# ============================================================
# D6 — Non-attack events never trigger
# ============================================================
func _test_non_attack_events_never_trigger() -> void:
	print("[B62B-D6] non_attack_events_never_trigger")
	var C = _guardian_setup()
	var events: Array = _run_battle(C["setup"])
	# No counter reaction should trigger from DAMAGE_APPLIED,
	# HEAL_APPLIED, STATUS_TICKED, UNIT_MOVED, STATUS_APPLIED,
	# STATUS_REMOVED.
	# We check that for any of these event types, no child
	# ATTACK_RESOLVED has tag=counterattack whose parent is
	# that event.
	for non_atk_type in [
		BattleEventTypeScript.DAMAGE_APPLIED,
		BattleEventTypeScript.HEAL_APPLIED,
		BattleEventTypeScript.STATUS_TICKED,
		BattleEventTypeScript.UNIT_MOVED,
		BattleEventTypeScript.STATUS_APPLIED,
		BattleEventTypeScript.STATUS_REMOVED,
	]:
		for ev in events:
			if int(ev.type) != int(non_atk_type):
				continue
			for child in events:
				if int(child.parent_event_id) == int(ev.event_id) \
						and int(child.type) == BattleEventTypeScript.ATTACK_RESOLVED \
						and String(child.tag) == "counterattack":
					_assert(false,
						"counter triggered from non-attack event type=%d (parent_event_id=%d)"
							% [int(non_atk_type), int(ev.event_id)])
					(C["guardian_def"] as Resource).reaction_ids = C["original"]
					return
	_assert(true,
		"non-attack events never triggered counterattack")
	(C["guardian_def"] as Resource).reaction_ids = C["original"]


# ============================================================
# D8 — Ownership security: entity cannot fire reaction it does
# not own
# ============================================================
func _test_owner_match_prevents_borrowing() -> void:
	print("[B62B-D8] owner_match_prevents_borrowing")
	# Construct a manual scenario: source owns counterattack;
	# ReactionDef owner_selector=TARGET (so the defender should
	# be the reactor). The source's reaction_ids must NOT cause
	# a counterattack to fire from the source — only from the
	# target (which doesn't own counterattack in this test).
	# Use direct dispatcher to test in isolation.
	var BattleWorldScript = preload(
		"res://core/battle_ecs/world/battle_world.gd")
	var BattleEventEmitterScript = preload(
		"res://core/battle_ecs/events/battle_event_emitter.gd")
	var BattleSetupScript = preload(
		"res://core/battle_ecs/battle_setup.gd")
	var BattleUnitSetupScript = preload(
		"res://core/battle_ecs/battle_unit_setup.gd")
	var TriggerLimitsScript = preload(
		"res://core/battle_ecs/triggers/trigger_limits.gd")
	var TriggerDispatchSessionScript = preload(
		"res://core/battle_ecs/triggers/trigger_dispatch_session.gd")
	var TriggerDispatcherScript = preload(
		"res://core/battle_ecs/triggers/trigger_dispatcher.gd")
	var em = BattleEventEmitterScript.new()
	em.reset()
	var w = BattleWorldScript.new(7, 4)
	# Source (entity 0) owns counterattack. Target (entity 1)
	# owns nothing.
	var setup = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 3,
			[&"counterattack"])],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 3,
			[])],
		7, 4)
	w.spawn_from_setup(setup)
	# event = source->target ATTACK_RESOLVED. The defender
	# (entity 1, the target) doesn't own counterattack. The
	# source (entity 0) owns it but ReactionDef owner_selector
	# is OWNER_EVENT_TARGET = 1. So owner_match check fails:
	# owner_entity (1) != entity_id (0).
	var atk_event = em.emit(
		BattleEventTypeScript.ATTACK_RESOLVED,
		0, 1, "p0", "e0", 50)
	var sink: Array = []
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 32
	limits.max_events_per_tick = 100
	limits.max_reactions_per_root = 256
	var session = TriggerDispatchSessionScript.from_limits(limits)
	var dispatcher = TriggerDispatcherScript.new()
	var prov = ContentReactionProviderScript.new()
	var rng = DeterministicRngScript.new(0)
	var result = dispatcher.process(
		[atk_event], w, rng, em, sink, prov, limits, session)
	_assert(result.reactions_executed == 0,
		"owner-match: source-owns counterattack rejected because owner_selector=TARGET (got %d reactions)"
			% int(result.reactions_executed))
	_assert(sink.size() == 0,
		"owner-match: no committed reaction events in sink (got %d)"
			% sink.size())


# ============================================================
# B3 — React-to-attack excludes counter chain
# ============================================================
func _test_react_to_attack_excludes_counter_chain() -> void:
	print("[B62B-B3] react_to_attack_excludes_counter_chain")
	# The counterattack ReactionDef excludes trigger tag
	# "counterattack". So a counter-attack emits events with
	# tag=counterattack, which the provider SKIPS (excluded
	# trigger tags). Hence no counter-counter.
	# Verified indirectly by _test_no_counter_counter_loop_both_sides_own.
	# Direct test: feed provider an ATTACK_RESOLVED with
	# tag=counterattack. It must produce zero reactions.
	var BattleWorldScript = preload(
		"res://core/battle_ecs/world/battle_world.gd")
	var BattleEventEmitterScript = preload(
		"res://core/battle_ecs/events/battle_event_emitter.gd")
	var BattleSetupScript = preload(
		"res://core/battle_ecs/battle_setup.gd")
	var BattleUnitSetupScript = preload(
		"res://core/battle_ecs/battle_unit_setup.gd")
	var em = BattleEventEmitterScript.new()
	em.reset()
	var w = BattleWorldScript.new(7, 4)
	var setup = BattleSetupScript.new(42,
		[BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 3,
			[&"counterattack"])],
		[BattleUnitSetupScript.new(
			"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 3,
			[])],
		7, 4)
	w.spawn_from_setup(setup)
	# Synthetic event: ATTACK_RESOLVED with tag="counterattack".
	var atk_event = em.emit(
		BattleEventTypeScript.ATTACK_RESOLVED,
		0, 1, "p0", "e0", 50)
	atk_event.tag = StringName("counterattack")
	var rng = DeterministicRngScript.new(0)
	var prov = ContentReactionProviderScript.new()
	var reactions: Array = prov.discover(w, atk_event, rng)
	_assert(reactions.size() == 0,
		"counterattack ReactionDef excludes trigger tag 'counterattack' (got %d reactions)"
			% reactions.size())


# ============================================================
# E5 — 20-run shipping determinism
# ============================================================
func _test_20_run_shipping_determinism() -> void:
	print("[B62B-DET] 20_run_shipping_determinism")
	var C = _guardian_setup()
	var first_norm: Array = []
	var first_hp0: int = -1
	var first_hp1: int = -1
	var first_pos0: String = ""
	var first_pos1: String = ""
	var first_statuses0: Array = []
	var first_statuses1: Array = []
	var first_result: Dictionary = {}
	var first_rng: Dictionary = {}
	var first_emit: int = -1
	var first_root: int = -1
	for run in 20:
		var sim = BattleSimulationScript.new()
		sim.initialize(C["setup"])
		sim.set_max_ticks(8)
		var events: Array = []
		while not sim.is_finished():
			events.append_array(sim.step_tick())
		# 1) Real BattleResult.
		_assert(sim.is_finished() == true,
			"run %d: sim.is_finished() == true" % run)
		var result = sim.get_result()
		_assert(result != null,
			"run %d: sim.get_result() != null" % run)
		# 2) Causal quartet: normal ATK -> counter ATK -> counter DMG.
		# Find the FIRST normal ATK that has a counter ATK
		# child. The first normal ATK may not trigger a counter
		# (e.g. tick 1 enemy is moving, not attacking).
		var normal_atk = null
		var counter_atk = null
		var counter_dmg = null
		for e in events:
			if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
					and int(e.parent_event_id) == -1 \
					and int(e.chain_depth) == 0 \
					and String(e.tag) == "":
				# Look for a counter child.
				var found_counter = null
				for c in events:
					if int(c.type) == BattleEventTypeScript.ATTACK_RESOLVED \
							and String(c.tag) == "counterattack" \
							and int(c.parent_event_id) == int(e.event_id) \
							and int(c.root_action_id) == int(e.root_action_id) \
							and int(c.chain_depth) == int(e.chain_depth) + 1:
						found_counter = c
						break
				if found_counter != null:
					normal_atk = e
					counter_atk = found_counter
					break
		_assert(normal_atk != null,
			"run %d: normal root ATTACK_RESOLVED with counter child found" % run)
		if counter_atk != null:
			for d in events:
				if int(d.type) == BattleEventTypeScript.DAMAGE_APPLIED \
						and String(d.tag) == "counterattack" \
						and int(d.parent_event_id) == int(counter_atk.event_id) \
						and int(d.root_action_id) == int(normal_atk.root_action_id) \
						and int(d.chain_depth) == int(counter_atk.chain_depth) + 1:
					counter_dmg = d
					break
			_assert(counter_dmg != null,
				"run %d: counterattack DAMAGE_APPLIED child found" % run)
		# 3) Unique event_ids.
		var seen: Dictionary = {}
		for e in events:
			var id: int = int(e.event_id)
			if seen.has(id):
				_assert(false,
					"run %d: duplicate event_id=%d" % [run, id])
				(C["guardian_def"] as Resource).reaction_ids = C["original"]
				return
			seen[id] = true
		# 4) 14-field norm.
		var norm: Array = []
		for e in events:
			norm.append(_normalize_event_14(e))
		# 5) BOTH sides' HP and positions.
		var hp0: int = int(sim.world().current_hp_of(0))
		var hp1: int = int(sim.world().current_hp_of(1))
		var pos0: String = str(sim.world().position_of(0))
		var pos1: String = str(sim.world().position_of(1))
		# 6) Active statuses per known entity (deterministic
		# empty snapshot is also valid). Iterate container
		# via .all() (deterministic insertion order).
		var statuses0: Array = []
		var sc0 = sim.world().get_status_container(0)
		if sc0 != null:
			for s in sc0.all():
				statuses0.append({
					"status_id": String(s.status_id),
					"remaining": int(s.remaining),
					"stacks": int(s.stacks),
					"magnitude": int(s.magnitude),
				})
		var statuses1: Array = []
		var sc1 = sim.world().get_status_container(1)
		if sc1 != null:
			for s in sc1.all():
				statuses1.append({
					"status_id": String(s.status_id),
					"remaining": int(s.remaining),
					"stacks": int(s.stacks),
					"magnitude": int(s.magnitude),
				})
		var rng: Dictionary = sim.rng().snapshot()
		var emit: int = int(sim.emitter().peek_next_event_id())
		var root: int = int(sim.emitter().peek_next_root_action_id())
		var rd: Dictionary = {}
		if result != null:
			rd = {
				"outcome": int(result.outcome),
				"winner_team": int(result.winner_team),
				"termination_reason": int(result.termination_reason),
				"tick_count": int(result.tick_count),
			}
		if run == 0:
			first_norm = norm
			first_hp0 = hp0
			first_hp1 = hp1
			first_pos0 = pos0
			first_pos1 = pos1
			first_statuses0 = statuses0
			first_statuses1 = statuses1
			first_result = rd
			first_rng = rng
			first_emit = emit
			first_root = root
			continue
		if norm.size() != first_norm.size():
			_assert(false,
				"run %d: trace length %d != base %d"
				% [run, norm.size(), first_norm.size()])
			(C["guardian_def"] as Resource).reaction_ids = C["original"]
			return
		for i in norm.size():
			if not _dict_eq14(norm[i], first_norm[i]):
				_assert(false,
					"run %d: event[%d] 14-field mismatch" % [run, i])
				(C["guardian_def"] as Resource).reaction_ids = C["original"]
				return
		_assert(hp0 == first_hp0,
			"run %d: hp0 %d != base %d" % [run, hp0, first_hp0])
		_assert(hp1 == first_hp1,
			"run %d: hp1 %d != base %d" % [run, hp1, first_hp1])
		_assert(pos0 == first_pos0,
			"run %d: pos0 mismatch ('%s' vs '%s')"
			% [run, pos0, first_pos0])
		_assert(pos1 == first_pos1,
			"run %d: pos1 mismatch ('%s' vs '%s')"
			% [run, pos1, first_pos1])
		_assert(_status_eq(statuses0, first_statuses0),
			"run %d: entity 0 status snapshot mismatch" % run)
		_assert(_status_eq(statuses1, first_statuses1),
			"run %d: entity 1 status snapshot mismatch" % run)
		for k in rd.keys():
			if int(rd.get(k, -1)) != int(first_result[k]):
				_assert(false, "run %d: result[%s] mismatch" % [run, k])
				(C["guardian_def"] as Resource).reaction_ids = C["original"]
				return
		_assert(int(rng.get("draw_count", -1)) == int(first_rng.get("draw_count", -2)),
			"run %d: RNG draw_count mismatch" % run)
		_assert(str(rng.get("state", "")) == str(first_rng.get("state", "")),
			"run %d: RNG state mismatch" % run)
		_assert(emit == first_emit,
			"run %d: emitter next_id mismatch" % run)
		_assert(root == first_root,
			"run %d: emitter next_root mismatch" % run)
	_assert(true,
		"20 runs identical: full 14 fields, HP0+HP1, pos0+pos1, "
		+ "statuses, real BattleResult, RNG snapshot, emitter counters")
	(C["guardian_def"] as Resource).reaction_ids = C["original"]


func _status_eq(a, b) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		var sa = a[i]
		var sb = b[i]
		for k in sa.keys():
			if not sb.has(k):
				return false
			if str(sa[k]) != str(sb[k]):
				return false
	return true


# ============================================================
# E6 — No-reaction full parity with default provider
# ============================================================
func _test_no_reaction_parity_with_default_provider() -> void:
	print("[B62B-PARITY] no_reaction_parity_with_default_provider")
	# Two paired sims: one with INERT reaction_ids (unknown),
	# one with empty ownership. Both use default provider.
	# Default ContentReactionProvider must NOT alter the trace
	# when no entity owns an active reaction.
	# B6.2b: assert exact full 14-field equality.
	var BattleSetupScript = preload(
		"res://core/battle_ecs/battle_setup.gd")
	var BattleUnitSetupScript = preload(
		"res://core/battle_ecs/battle_unit_setup.gd")
	var p_with = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 3,
		[&"unknown_inert"])
	var p_without = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 3, [])
	var e_row = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 3), 100, 100, 20, 5, 3, [])
	var sim1 = BattleSimulationScript.new()
	sim1.initialize(BattleSetupScript.new(42, [p_with], [e_row], 7, 4))
	sim1.set_max_ticks(5)
	var sim2 = BattleSimulationScript.new()
	sim2.initialize(BattleSetupScript.new(42, [p_without], [e_row], 7, 4))
	sim2.set_max_ticks(5)
	var ev_a: Array = []
	var ev_b: Array = []
	while not sim1.is_finished():
		ev_a.append_array(sim1.step_tick())
	while not sim2.is_finished():
		ev_b.append_array(sim2.step_tick())
	_assert(ev_a.size() == ev_b.size(),
		"with/without INERT reaction_ids: trace length equal (%d vs %d)"
			% [ev_a.size(), ev_b.size()])
	# Normalize both traces using the canonical 14-field
	# helper.
	var norm_a: Array = []
	var norm_b: Array = []
	for e in ev_a:
		norm_a.append(_normalize_event_14(e))
	for e in ev_b:
		norm_b.append(_normalize_event_14(e))
	for i in mini(norm_a.size(), norm_b.size()):
		if not _dict_eq14(norm_a[i], norm_b[i]):
			# Print all 14 fields of the first mismatch.
			var msg: String = ""
			for k in norm_a[i].keys():
				if str(norm_a[i][k]) != str(norm_b[i][k]):
					msg += " %s=%s/%s" % [
						k, str(norm_a[i][k]), str(norm_b[i][k])]
			_assert(false,
				"event[%d] full 14-field mismatch:%s" % [i, msg])
			return
	_assert(true,
		"default provider does not alter non-participating battles (14 fields)")
