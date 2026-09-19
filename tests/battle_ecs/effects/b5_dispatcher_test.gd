extends SceneTree
## B5 / Phase-3 / TriggerDispatcher foundation tests.
##
## Empty-pipeline smoke + ancestry + depth-limit + per-root
## budget + events-per-tick + no-redispatch + failed-effect
## + dead-target + 20-run determinism + two-simulation
## isolation.

const TriggerDispatcherScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatcher.gd")
const TriggerLimitsScript = preload(
	"res://core/battle_ecs/triggers/trigger_limits.gd")
const TriggerReactionScript = preload(
	"res://core/battle_ecs/triggers/trigger_reaction.gd")
const DispatchResultScript = preload(
	"res://core/battle_ecs/triggers/dispatch_result.gd")
const EffectContextScript = preload(
	"res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload(
	"res://core/battle_ecs/effects/effect_executor.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const EffectKindScript = preload(
	"res://core/battle_ecs/effects/effect_kind.gd")
const DeterministicRngScript = preload(
	"res://core/rng/deterministic_rng.gd")
const BattleEventEmitterScript = preload(
	"res://core/battle_ecs/events/battle_event_emitter.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const BattleWorldScript = preload(
	"res://core/battle_ecs/world/battle_world.gd")
const BattleSetupScript = preload(
	"res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload(
	"res://core/battle_ecs/battle_unit_setup.gd")
const B5HelpersScript = preload(
	"res://tests/battle_ecs/effects/b5_helpers.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_empty_pipeline_no_reactions()
	await _test_empty_pipeline_no_events_emitted()
	await _test_damage_triggers_heal_ancestry()
	await _test_heal_emitted_with_chain_depth_1()
	await _test_damage_root_action_id_preserved_through_chain()
	await _test_depth_limit_stops_ping_pong()
	await _test_per_root_reaction_budget_isolates_roots()
	await _test_events_per_tick_limit()
	await _test_no_event_redispatch()
	await _test_failed_effect_emits_no_event()
	await _test_dead_target_does_not_block_remaining_events()
	await _test_20_run_same_seed_identical_traces()
	await _test_two_simulation_isolation()
	print("\n=== B5 focused tests: %d passed, %d failed ===\n" % [_passed, _failed])
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


func _setup_world_and_emitter() -> Dictionary:
	var w = BattleWorldScript.new(7, 4)
	var em = BattleEventEmitterScript.new()
	em.reset()
	var rng = DeterministicRngScript.new(0)
	return {"world": w, "emitter": em, "rng": rng}


func _setup_world_with_two_units(p_world, p_emitter) -> Dictionary:
	# E0 (the damage target, which the reaction heals) starts
	# at 1 HP (1 below max) so regen of 1 HP actually heals
	# and emits HEAL_APPLIED.
	var p0_setup = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 20, 5, 1)
	var e0_setup = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 1, 100, 20, 5, 1)
	var s = BattleSetupScript.new(42, [p0_setup], [e0_setup], 7, 4)
	p_world.spawn_from_setup(s)
	var sink: Array = []
	var rng = DeterministicRngScript.new(0)
	var damage = B5HelpersScript.EventBuilder.damage_event(
		p_emitter, 0, 1, 5)
	return {"damage": damage, "rng": rng, "sink": sink}


# === Empty pipeline ===

func _test_empty_pipeline_no_reactions() -> void:
	print("[EMPTY-1] empty_pipeline_no_reactions")
	var info = _setup_world_and_emitter()
	var provider = B5HelpersScript.NoopProvider.new()
	var limits = TriggerLimitsScript.new()
	var d = TriggerDispatcherScript.new()
	var result = d.process([], info["world"], info["rng"], info["emitter"],
		[], provider, limits)
	_assert(result.reactions_executed == 0,
		"empty pipeline -> 0 reactions_executed")


func _test_empty_pipeline_no_events_emitted() -> void:
	print("[EMPTY-2] empty_pipeline_no_events_emitted")
	var info = _setup_world_and_emitter()
	var provider = B5HelpersScript.NoopProvider.new()
	var limits = TriggerLimitsScript.new()
	var d = TriggerDispatcherScript.new()
	var result = d.process([], info["world"], info["rng"], info["emitter"],
		[], provider, limits)
	_assert(result.events.size() == 0,
		"empty pipeline -> 0 new committed events")
	_assert(not result.truncated,
		"empty pipeline -> truncated=false")
	_assert(result.reason == DispatchResultScript.REASON_NONE,
		"empty pipeline -> reason=NONE")


# === Ancestry ===

func _test_damage_triggers_heal_ancestry() -> void:
	print("[ANC-1] damage_triggers_heal_ancestry")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var damage = setup["damage"]
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = false  # one-shot heal
	var limits = TriggerLimitsScript.new()
	var d = TriggerDispatcherScript.new()
	var result = d.process([damage], w, info["rng"], em, [], provider, limits)
	_assert(result.events.size() >= 1,
		"at least one reaction event emitted")
	var heal_ev = result.events[0]
	_assert(int(heal_ev.type) == BattleEventTypeScript.HEAL_APPLIED,
		"first reaction event is HEAL_APPLIED")
	_assert(int(heal_ev.parent_event_id) == int(damage.event_id),
		"HEAL.parent_event_id == damage.event_id (ancestry)")
	_assert(int(heal_ev.root_action_id) == int(damage.root_action_id),
		"HEAL.root_action_id == damage.root_action_id")
	_assert(int(heal_ev.chain_depth) == int(damage.chain_depth) + 1,
		"HEAL.chain_depth == damage.chain_depth + 1")


func _test_heal_emitted_with_chain_depth_1() -> void:
	print("[ANC-2] heal_emitted_with_chain_depth_1")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var damage = setup["damage"]
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = false
	var limits = TriggerLimitsScript.new()
	var d = TriggerDispatcherScript.new()
	var result = d.process([damage], w, info["rng"], em, [], provider, limits)
	var heal_ev = result.events[0]
	_assert(int(damage.chain_depth) == 0,
		"root damage chain_depth=0")
	_assert(int(heal_ev.chain_depth) == 1,
		"child heal chain_depth=1")


func _test_damage_root_action_id_preserved_through_chain() -> void:
	print("[ANC-3] damage_root_action_id_preserved_through_chain")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var damage = setup["damage"]
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = true
	var limits = TriggerLimitsScript.new()
	limits.max_events_per_tick = 64
	var d = TriggerDispatcherScript.new()
	var result = d.process([damage], w, info["rng"], em, [], provider, limits)
	var expected_root: int = int(damage.root_action_id)
	for ev in result.events:
		_assert(int(ev.root_action_id) == expected_root,
			"all reaction events share root_action_id (chain_depth=%d)" % int(ev.chain_depth))


# === Depth limit ===

func _test_depth_limit_stops_ping_pong() -> void:
	print("[DEPTH-1] depth_limit_stops_ping_pong")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var damage = setup["damage"]
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = true
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 4      # tight
	limits.max_reactions_per_root = 100000
	limits.max_events_per_tick = 100000
	var d = TriggerDispatcherScript.new()
	var result = d.process([damage], w, info["rng"], em, [], provider, limits)
	_assert(result.truncated,
		"ping-pong terminated (truncated=true)")
	_assert(result.reason == DispatchResultScript.REASON_MAX_DEPTH \
			or result.reason == DispatchResultScript.REASON_MAX_EVENTS,
		"limit reason is depth or events (got %d)" % int(result.reason))
	var max_depth: int = -1
	for ev in result.events:
		if int(ev.chain_depth) > max_depth:
			max_depth = int(ev.chain_depth)
	_assert(max_depth <= 4,
		"deepest accepted event chain_depth <= 4 (got %d)" % max_depth)


# === Per-root budget ===

func _test_per_root_reaction_budget_isolates_roots() -> void:
	print("[BUDGET-1] per_root_reaction_budget_isolates_roots")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var damage_a = setup["damage"]
	var damage_b = em.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 5, "")
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = true
	var limits = TriggerLimitsScript.new()
	limits.max_reactions_per_root = 4
	limits.max_events_per_tick = 10000
	limits.max_chain_depth = 32
	var d = TriggerDispatcherScript.new()
	var result = d.process([damage_b, damage_a], w, info["rng"], em, [],
		provider, limits)
	_assert(result.truncated,
		"reached per-root reaction budget (truncated=true)")
	_assert(result.reason == DispatchResultScript.REASON_MAX_REACTIONS_PER_ROOT,
		"reason is per-root budget (got %d)" % int(result.reason))


# === Events-per-tick + no-redispatch ===

func _test_events_per_tick_limit() -> void:
	print("[EVENTS-1] events_per_tick_limit")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var damage = setup["damage"]
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = true
	var limits = TriggerLimitsScript.new()
	limits.max_chain_depth = 32
	limits.max_reactions_per_root = 100000
	limits.max_events_per_tick = 8
	var d = TriggerDispatcherScript.new()
	# Build a fresh sink for this test so parity assertion
	# can read all committed reaction events.
	var sink: Array = []
	var result = d.process([damage], w, info["rng"], em, sink, provider, limits)
	# Spec B5.1: max_events_per_tick is the cap on unique
	# committed events PROCESSED FOR TRIGGER DISCOVERY.
	# It does NOT bound DispatchResult.events (those
	# contain every committed reaction event at commit
	# time, even when the dispatcher stops before further
	# processing).
	_assert(result.truncated,
		"events_per_tick cap reached (truncated=true)")
	_assert(int(result.reason) == int(
			DispatchResultScript.REASON_MAX_EVENTS),
		"reason is MAX_EVENTS (got %d)" % int(result.reason))
	_assert(len(result.events) >= 1,
		"at least one committed reaction event remains visible")
	# Discovery bound: seen-set size == max_events_per_tick
	# exactly (the cap stops further processing).
	_assert(len(d._seen) == int(limits.max_events_per_tick),
		"dispatcher._seen.size() == max_events_per_tick (got %d, cap %d)" % [len(d._seen), int(limits.max_events_per_tick)])
	# result.events has no duplicates (proves commit-time
	# recording does not produce duplicate emitted
	# BattleEvents).
	var unique_count: int = 0
	var unique_ids: Dictionary = {}
	for ev in result.events:
		var eid: int = int(ev.event_id)
		if not unique_ids.has(eid):
			unique_ids[eid] = true
			unique_count += 1
	_assert(unique_count == len(result.events),
		"result.events contains no duplicate event_ids (unique=%d total=%d)" % [unique_count, len(result.events)])
	# Sink parity: sink contains at least result.events
	# (caller may pre-fill; the dispatcher only APPENDS).
	_assert(len(sink) >= len(result.events),
		"sink contains all result.events (sink=%d result=%d)" % [len(sink), len(result.events)])


func _test_no_event_redispatch() -> void:
	print("[RE-DISPATCH] no_event_redispatch")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var damage = setup["damage"]
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = false
	var limits = TriggerLimitsScript.new()
	var d = TriggerDispatcherScript.new()
	var result = d.process([damage], w, info["rng"], em, [], provider, limits)
	_assert(result.events.size() == 1,
		"one reaction event emitted (no re-dispatch)")
	var seen_count: int = 0
	for k in d._seen.keys():
		seen_count += 1
	_assert(seen_count >= 2,
		"seen-set contains damage + heal (got %d)" % seen_count)


# === Failed-effect + dead-target ===

func _test_failed_effect_emits_no_event() -> void:
	print("[FAILED-1] failed_effect_emits_no_event")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var damage = setup["damage"]
	var provider = B5HelpersScript.NoopProvider.new()
	var limits = TriggerLimitsScript.new()
	var d = TriggerDispatcherScript.new()
	var result = d.process([damage], w, info["rng"], em, [], provider, limits)
	_assert(result.events.size() == 0,
		"no-op provider -> 0 reaction events")
	_assert(result.reactions_executed == 0,
		"no-op provider -> 0 reactions executed")


func _test_dead_target_does_not_block_remaining_events() -> void:
	print("[DEAD-1] dead_target_does_not_block_remaining_events")
	var info = _setup_world_and_emitter()
	var w = info["world"]
	var em = info["emitter"]
	var setup = _setup_world_with_two_units(w, em)
	var damage_a = setup["damage"]
	var damage_b = em.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 5, "")
	# Kill entity 1 BEFORE dispatch.
	w.apply_damage(1, 99999)
	_assert(not w.is_alive(1), "entity 1 dead")
	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = false
	var limits = TriggerLimitsScript.new()
	var d = TriggerDispatcherScript.new()
	var result = d.process([damage_a, damage_b], w, info["rng"], em, [],
		provider, limits)
	# Dispatcher must terminate cleanly even though heal
	# targets dead 1.
	_assert(result.events.size() == 0,
		"no reaction events emitted (heal of dead target rejected)")
	_assert(not result.truncated,
		"dead-target rejection is not a 'limit reached' truncation")


# === 20-run determinism ===

func _test_20_run_same_seed_identical_traces() -> void:
	print("[DET-1] 20_run_same_seed_identical_traces")
	var first_norm: Array = []
	var first_reactions: int = -1
	var first_truncated: bool = false
	var first_reason: int = -1
	for run in 20:
		var info = _setup_world_and_emitter()
		var w = info["world"]
		var em = info["emitter"]
		var setup = _setup_world_with_two_units(w, em)
		var damage = setup["damage"]
		var provider = B5HelpersScript.PingPongProvider.new()
		provider.mirror = true
		var limits = TriggerLimitsScript.new()
		limits.max_chain_depth = 8
		limits.max_reactions_per_root = 5
		limits.max_events_per_tick = 100
		var d = TriggerDispatcherScript.new()
		var result = d.process([damage], w, info["rng"], em, [], provider, limits)
		var norm = _normalize(result.events)
		if run == 0:
			first_norm = norm
			first_reactions = result.reactions_executed
			first_truncated = result.truncated
			first_reason = result.reason
		else:
			_assert(result.reactions_executed == first_reactions,
				"run %d reactions_executed matches" % run)
			_assert(result.truncated == first_truncated,
				"run %d truncated matches" % run)
			_assert(result.reason == first_reason,
				"run %d reason matches" % run)
			_assert(norm.size() == first_norm.size(),
				"run %d size matches (got %d, expected %d)" % [run, norm.size(), first_norm.size()])
			for i in norm.size():
				var diff: String = _field_diff(first_norm[i], norm[i])
				if diff != "":
					_assert(false, "run %d event %d differs: %s" % [run, i, diff])
					return
	_assert(true, "20 runs identical (normalized events + counters + reason)")


func _normalize(events: Array) -> Array:
	var out: Array = []
	for e in events:
		out.append({
			"event_id": int(e.event_id),
			"type": int(e.type),
			"tick": int(e.tick),
			"source_entity": int(e.source_entity),
			"target_entity": int(e.target_entity),
			"amount": int(e.amount),
			"tag": String(e.tag),
			"parent_event_id": int(e.parent_event_id),
			"root_action_id": int(e.root_action_id),
			"chain_depth": int(e.chain_depth),
		})
	return out


func _field_diff(a, b) -> String:
	var fields: Array = [
		"event_id", "type", "tick",
		"source_entity", "target_entity",
		"amount", "tag",
		"parent_event_id", "root_action_id", "chain_depth",
	]
	for f in fields:
		if not b.has(f):
			return "missing %s" % f
		if a.get(f) != b.get(f):
			return "%s: a=%s b=%s" % [f, str(a.get(f)), str(b.get(f))]
	return ""


# === Two-simulation isolation ===

func _test_two_simulation_isolation() -> void:
	print("[ISO-1] two_simulation_isolation")
	var info_a = _setup_world_and_emitter()
	var w_a = info_a["world"]
	var em_a = info_a["emitter"]
	var setup_a = _setup_world_with_two_units(w_a, em_a)
	var info_b = _setup_world_and_emitter()
	var w_b = info_b["world"]
	var em_b = info_b["emitter"]
	var setup_b = _setup_world_with_two_units(w_b, em_b)

	var damage_a = setup_a["damage"]
	var damage_b2 = em_b.emit(
		BattleEventTypeScript.DAMAGE_APPLIED,
		0, 1, "", "", 3, "")

	var provider = B5HelpersScript.PingPongProvider.new()
	provider.mirror = false
	var limits = TriggerLimitsScript.new()
	var d_a = TriggerDispatcherScript.new()
	var d_b = TriggerDispatcherScript.new()
	var res_a = d_a.process([damage_a], w_a, info_a["rng"], em_a, [],
		provider, limits)
	var res_b = d_b.process([damage_b2], w_b, info_b["rng"], em_b, [],
		provider, limits)
	_assert(res_a.events.size() == 1,
		"sim A emits 1 reaction event")
	_assert(res_b.events.size() == 1,
		"sim B emits 1 reaction event")
	var id_a: int = -1
	var id_b: int = -1
	if res_a.events.size() >= 1:
		id_a = int(res_a.events[0].event_id)
	if res_b.events.size() >= 1:
		id_b = int(res_b.events[0].event_id)
	_assert(id_a != id_b,
		"sim A and sim B have distinct event_ids")
	_assert(int(em_a.peek_next_event_id()) != int(em_b.peek_next_event_id()),
		"emitter counters are independent (peek_next_event_id differs)")
