extends SceneTree
## B6.4c / A-H SEMANTIC DIFFERENTIAL PROBE.
##
## Runs the SAME 8 fixtures (A-H) on the CLEAN a5dd87d baseline
## and on the B6.4c candidate, and dumps a JSON snapshot per
## fixture:
##
##   world        (HP, alive, positions for both entities)
##   rng          (seed, draw_count, internal state hex)
##   emitter      (next_event_id, next_root_action_id, tick)
##   battle_result (when the battle finished)
##   events       (14-field legacy trace)
##
## The probe is API-compatible with BOTH trees so the SAME file
## can be copied into the baseline worktree and the candidate
## worktree.
##
## The comparator then projects the candidate back to legacy form
## (strip DAMAGE_STARTED, reparent, shift depth, renumber ids)
## and requires EXACT equality of everything except the inserted
## layer.

const DeterministicRngScript = preload(
	"res://core/rng/deterministic_rng.gd")
const BattleSimulationScript = preload(
	"res://core/battle_ecs/battle_simulation.gd")
const BattleSetupScript = preload(
	"res://core/battle_ecs/battle_setup.gd")
const BattleUnitSetupScript = preload(
	"res://core/battle_ecs/battle_unit_setup.gd")
const BattleEventTypeScript = preload(
	"res://core/battle_ecs/battle_event_type.gd")
const ContentDBScript = preload(
	"res://core/utils/content_db.gd")
const EffectRequestScript = preload(
	"res://core/battle_ecs/effects/effect_request.gd")
const EffectContextScript = preload(
	"res://core/battle_ecs/effects/effect_context.gd")
const EffectExecutorScript = preload(
	"res://core/battle_ecs/effects/effect_executor.gd")
const TriggerProviderScript = preload(
	"res://core/battle_ecs/triggers/trigger_provider.gd")
const TriggerLimitsScript = preload(
	"res://core/battle_ecs/triggers/trigger_limits.gd")
const TriggerDispatchSessionScript = preload(
	"res://core/battle_ecs/triggers/trigger_dispatch_session.gd")

var _out: Array = []


func _initialize() -> void:
	ContentDBScript.load_all()
	await _probe_a_scheduled_nonlethal()
	await _probe_b_scheduled_lethal()
	await _probe_c_counterattack()
	await _probe_d_aoo()
	await _probe_e_aoo_counter_coexistence()
	await _probe_f_direct_damage()
	await _probe_g_real_burn()
	await _probe_h_full_battle()
	for line in _out:
		print(line)
	quit(0)


func _rng_snap_full(p_sim) -> Dictionary:
	var s: Dictionary = p_sim._rng.snapshot()
	var state = s.get("state", PackedByteArray())
	var state_str: String = ""
	if state is PackedByteArray:
		state_str = String((state as PackedByteArray).hex_encode())
	else:
		state_str = str(state)
	return {
		"seed": int(s.get("seed", 0)),
		"draw_count": int(s.get("draw_count", 0)),
		"state_hex": state_str,
	}


func _events_to_lines(p_events: Array) -> Array:
	var lines: Array = []
	for e in p_events:
		lines.append(JSON.stringify({
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
		}))
	return lines


func _result_to_dict(p_sim) -> Dictionary:
	if not bool(p_sim.is_finished()):
		return {}
	var r = p_sim.get_result()
	if r == null:
		return {}
	return {
		"winner_team": int(r.winner_team),
		"termination_reason": int(r.termination_reason),
		"tick_count": int(r.tick_count),
		"outcome": int(r.outcome),
		"surviving_player_ids": str(r.surviving_player_ids),
		"surviving_enemy_ids": str(r.surviving_enemy_ids),
	}


func _record(p_name: String, p_sim, p_events: Array) -> void:
	var em = p_sim._event_emitter
	var snap: Dictionary = {
		"name": String(p_name),
		"world": {
			"0_hp": int(p_sim.world().current_hp_of(0)),
			"0_alive": bool(p_sim.world().is_alive(0)),
			"0_pos": str(p_sim.world().position_of(0)),
			"1_hp": int(p_sim.world().current_hp_of(1)),
			"1_alive": bool(p_sim.world().is_alive(1)),
			"1_pos": str(p_sim.world().position_of(1)),
		},
		"rng": _rng_snap_full(p_sim),
		"emitter": {
			"next_event_id": int(em.peek_next_event_id()),
			"next_root_action_id": int(em.peek_next_root_action_id()),
			"current_tick": int(em.current_tick()),
		},
		"result": _result_to_dict(p_sim),
		"events": _events_to_lines(p_events),
	}
	_out.append(JSON.stringify(snap))


func _make_pair(p_p0_hp: int, p_p0_atk: int, p_e0_hp: int, p_e0_atk: int,
		p_mover_pos: Vector2i = Vector2i(1, 1),
		p_knight_pos: Vector2i = Vector2i(1, 2),
		p_knight_reactions: Array = []) -> RefCounted:
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, p_mover_pos, p_p0_hp, p_p0_hp,
		p_p0_atk, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, p_knight_pos, p_e0_hp, p_e0_hp,
		p_e0_atk, 5, 1, p_knight_reactions)
	var setup = BattleSetupScript.new(42,
		[mover], [knight], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	return sim


# The legacy pump entry point differs between the two trees:
#   baseline a5dd87d : sim._trigger_dispatcher.process(...)
#   B6.4c candidate   : sim._trigger_dispatcher.process_work(...)
# We detect the available one at runtime so the SAME probe file
# works on both.
func _pump(p_sim, p_items: Array, p_sink: Array, p_limits) -> void:
	var dispatcher = p_sim._trigger_dispatcher
	if dispatcher.has_method("process_work"):
		dispatcher.process_work(
			p_items, p_sim.world(), p_sim._rng, p_sim._event_emitter,
			p_sink, TriggerProviderScript.new(), p_limits, null)
		return
	dispatcher.process(
		p_items, p_sim.world(), p_sim._rng, p_sim._event_emitter,
		p_sink, TriggerProviderScript.new(), p_limits, null)


# A. scheduled nonlethal
#
# NOTE: we drive the battle through the PUBLIC step_tick() entry
# point, not through the internal _drive_team_action() helper.
# In B6.4c _drive_team_action() places the window work item into
# a sink that step_tick() drains; calling the helper directly
# would leave the window open and the damage uncommitted. The
# baseline (a5dd87d) has no such indirection, but step_tick()
# exists on BOTH trees and is the production path, so the probe
# is API-compatible with both.
func _probe_a_scheduled_nonlethal() -> void:
	print("=== A. scheduled nonlethal ===")
	var sim = _make_pair(200, 5, 80, 5)
	sim._rng = DeterministicRngScript.new(7)
	var events: Array = sim.step_tick()
	_record("A_scheduled_nonlethal", sim, events)


# B. scheduled lethal
func _probe_b_scheduled_lethal() -> void:
	print("=== B. scheduled lethal ===")
	var sim = _make_pair(200, 5, 80, 5)
	sim._rng = DeterministicRngScript.new(7)
	var events: Array = sim.step_tick()
	_record("B_scheduled_lethal", sim, events)


# C. counterattack
func _probe_c_counterattack() -> void:
	print("=== C. counterattack ===")
	var sim = _make_pair(200, 5, 80, 5, Vector2i(1, 1), Vector2i(1, 2),
		[&"counterattack"])
	sim._rng = DeterministicRngScript.new(7)
	var events: Array = sim.step_tick()
	_record("C_counterattack", sim, events)


# D. AoO
func _probe_d_aoo() -> void:
	print("=== D. AoO ===")
	var sim = _make_pair(200, 5, 80, 5, Vector2i(1, 1), Vector2i(0, 1),
		[&"attack_of_opportunity"])
	sim._rng = DeterministicRngScript.new(7)
	var em = sim._event_emitter
	var s = em.emit(
		BattleEventTypeScript.UNIT_MOVE_STARTED,
		0, 1, "p0", "e0", 0, "",
		Vector2i(1, 1), Vector2i(2, 1))
	var prov = load(
		"res://core/battle_ecs/triggers/content_reaction_provider.gd").new()
	var limits = load(
		"res://core/battle_ecs/triggers/trigger_limits.gd").new(32, 10000, 256)
	var session = sim._trigger_dispatcher.begin_session(limits)
	var sink: Array = []
	if sim._trigger_dispatcher.has_method("process_work"):
		sim._trigger_dispatcher.process_work(
			[s], sim.world(), sim._rng, em, sink,
			prov, limits, session)
	else:
		sim._trigger_dispatcher.process(
			[s], sim.world(), sim._rng, em, sink,
			prov, limits, session)
	em.emit(
		BattleEventTypeScript.UNIT_MOVED,
		0, 1, "p0", "e0", 0, "",
		Vector2i(1, 1), Vector2i(2, 1))
	_record("D_aoo", sim, [s] + sink)


# E. AoO + counter coexistence
func _probe_e_aoo_counter_coexistence() -> void:
	print("=== E. AoO + counter coexistence ===")
	var sim = _make_pair(200, 5, 80, 5, Vector2i(1, 1), Vector2i(0, 1),
		[&"attack_of_opportunity", &"counterattack"])
	sim._rng = DeterministicRngScript.new(7)
	var em = sim._event_emitter
	var s = em.emit(
		BattleEventTypeScript.UNIT_MOVE_STARTED,
		0, 1, "p0", "e0", 0, "",
		Vector2i(1, 1), Vector2i(2, 1))
	var prov = load(
		"res://core/battle_ecs/triggers/content_reaction_provider.gd").new()
	var limits = load(
		"res://core/battle_ecs/triggers/trigger_limits.gd").new(32, 10000, 256)
	var session = sim._trigger_dispatcher.begin_session(limits)
	var sink: Array = []
	if sim._trigger_dispatcher.has_method("process_work"):
		sim._trigger_dispatcher.process_work(
			[s], sim.world(), sim._rng, em, sink,
			prov, limits, session)
	else:
		sim._trigger_dispatcher.process(
			[s], sim.world(), sim._rng, em, sink,
			prov, limits, session)
	em.emit(
		BattleEventTypeScript.UNIT_MOVED,
		0, 1, "p0", "e0", 0, "",
		Vector2i(1, 1), Vector2i(2, 1))
	_record("E_aoo_counter", sim, [s] + sink)


# F. direct damage
func _probe_f_direct_damage() -> void:
	print("=== F. direct damage ===")
	var sim = _make_pair(200, 5, 80, 5)
	sim._rng = DeterministicRngScript.new(7)
	var em = sim._event_emitter
	var req = EffectRequestScript.root(0, 0, 1, 10)
	req.source_entity = 0
	req.target_entity = 1
	req.amount = 10
	req.payload = {"skip_balance": true}
	var ctx = EffectContextScript.new(
		sim.world(), sim._rng, em, [])
	var res = EffectExecutorScript.new().execute(ctx, req)
	var trace: Array = []
	for ev in res.events:
		trace.append(ev)
	# On the B6.4c candidate the damage is committed by the
	# window work item, so drain it through the canonical pump.
	if res != null and res.get("dispatch_work") != null:
		var dw = res.get("dispatch_work")
		if dw.size() > 0:
			var limits = TriggerLimitsScript.new()
			var session = TriggerDispatchSessionScript.from_limits(limits)
			var sink: Array = []
			_pump(sim, dw, sink, limits)
			for ev2 in sink:
				trace.append(ev2)
	_record("F_direct_damage", sim, trace)


# G. real burn (status pre-baked)
func _probe_g_real_burn() -> void:
	print("=== G. real burn ===")
	var sim = _make_pair(200, 5, 80, 5)
	sim._rng = DeterministicRngScript.new(7)
	var em = sim._event_emitter
	var req = EffectRequestScript.root(2, 0, 1, 5)  # APPLY_STATUS
	req.payload = {"status_id": "burn", "magnitude": 5, "duration": 5, "period": 1, "is_dot": true}
	var ctx = EffectContextScript.new(sim.world(), sim._rng, em, [])
	EffectExecutorScript.new().execute(ctx, req)
	# NOTE: the burn tick's events come from step_tick()'s return
	# value. There is no sim.events field on either tree.
	var events: Array = sim.step_tick()
	_record("G_real_burn", sim, events)


# H. full battle
func _probe_h_full_battle() -> void:
	print("=== H. full battle ===")
	var sim = _make_pair(200, 5, 80, 5, Vector2i(1, 1), Vector2i(1, 2),
		[&"counterattack"])
	sim._rng = DeterministicRngScript.new(7)
	sim.set_max_ticks(8)
	var events: Array = []
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	_record("H_full_battle", sim, events)
