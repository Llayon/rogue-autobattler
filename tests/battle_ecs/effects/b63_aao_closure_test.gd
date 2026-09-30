extends SceneTree
## B6.3 final closure / spatial ownership RED tests.
## BLOCKERs 1, 2, 3, 4, 5, 6, 7, 8 + RunDomain cleanup.

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
const ContentReactionProviderScript = preload(
	"res://core/battle_ecs/triggers/content_reaction_provider.gd")
const DeterministicRngScript = preload(
	"res://core/rng/deterministic_rng.gd")
const StatusInstanceScript = preload(
	"res://core/battle_ecs/status/status_instance.gd")
const RunDomainStateScript = preload(
	"res://core/progression/run_domain_state.gd")
const RunUnitScript = preload(
	"res://core/progression/run_unit.gd")
const BattleSetupBuilderScript = preload(
	"res://core/battle_ecs/battle_setup_builder.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	await _test_spatial_non_owner_does_not_react()
	await _test_two_real_owners_produce_two_reactions()
	await _test_range_vs_attack_range_mismatch()
	await _test_stun_admission_real()
	await _test_excluded_tag_real_aoo_event()
	await _test_move_started_not_progress()
	await _test_aoo_counter_coexistence_permanent()
	await _test_20_run_aoo_determinism()
	await _test_complete_spatial_negative_matrix()
	await _test_rundomain_ownership_uses_shipping_knight()
	print("\n=== B6.3 final closure proofs: %d pass / %d fail ===\n"
		% [_passed, _failed])
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


# BLOCKER 1: non-owner cannot receive AoO despite geometry.
func _test_spatial_non_owner_does_not_react() -> void:
	print("[B63-CLOSED] spatial non-owner does not react")
	var reactions = _spatial_discover(
		Vector2i(2, 2), Vector2i(3, 2),
		[Vector2i(6, 6), Vector2i(1, 2)],
		[[&"attack_of_opportunity"], []],
		[1, 1])
	var saw_nonowner: bool = false
	var saw_knight: bool = false
	for r in reactions:
		var eid: int = int(r.reacting_entity)
		if eid == 1:
			saw_knight = true
		elif eid == 2:
			saw_nonowner = true
	_assert(not saw_nonowner,
		"non-owner (entity 2) MUST NOT receive AoO despite geometry")
	_assert(not saw_knight,
		"real owner (entity 1) also not spatially eligible here")
	_assert(reactions.size() == 0,
		"total reactions == 0 (no eligible AoO owner in fixture)")


# Multi-owner: two real eligible owners -> two reactions, no third.
func _test_two_real_owners_produce_two_reactions() -> void:
	print("[B63-CLOSED] two real owners ascending order")
	var reactions = _spatial_discover(
		Vector2i(2, 2), Vector2i(3, 2),
		[Vector2i(2, 1), Vector2i(2, 3), Vector2i(2, 0)],
		[[&"attack_of_opportunity"], [&"attack_of_opportunity"], []],
		[1, 1, 1])
	var saw_a: bool = false
	var saw_b: bool = false
	var saw_nonowner: bool = false
	for r in reactions:
		var eid: int = int(r.reacting_entity)
		if eid == 1:
			saw_a = true
		elif eid == 2:
			saw_b = true
		elif eid == 3:
			saw_nonowner = true
	_assert(saw_a, "knight_a AoO reaction present")
	_assert(saw_b, "knight_b AoO reaction present")
	_assert(not saw_nonowner,
		"non-owner (entity 3) MUST NOT receive AoO")
	_assert(reactions.size() == 2,
		"exactly 2 AoO reactions (no third)")


# BLOCKER 2: authored range vs attack range mismatch.
func _test_range_vs_attack_range_mismatch() -> void:
	print("[B63-CLOSED] authored range vs attack range mismatch")
	var knight_def = ContentDBScript.get_by_id_for_type(
		"reactions", &"attack_of_opportunity")
	if knight_def == null:
		_assert(false, "attack_of_opportunity def loaded")
		return
	var original_range: int = int(knight_def.range_cells)
	knight_def.range_cells = 2
	var results = _dispatch_at_pre_moven(
		Vector2i(2, 2), Vector2i(3, 2),
		[Vector2i(2, 0)],
		[[&"attack_of_opportunity"]],
		[1])
	knight_def.range_cells = original_range
	_assert(results["reactions_executed"] == 1,
		"dispatcher admits AoO intent (range_cells=2, authored)")
	var saw_aoo_atk: bool = false
	var saw_aoo_dmg: bool = false
	for e in results["sink"]:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and String(e.tag) == "attack_of_opportunity":
			saw_aoo_atk = true
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and String(e.tag) == "attack_of_opportunity":
			saw_aoo_dmg = true
	_assert(not saw_aoo_atk,
		"executor rejects: ZERO tagged AoO ATTACK (attack_range=1)")
	_assert(not saw_aoo_dmg,
		"executor rejects: ZERO tagged AoO DAMAGE")
	_assert(results["sink"].size() == 0,
		"sink has zero committed AoO events")
	_assert(results["mover_pos"] == Vector2i(2, 2),
		"mover still at from_cell (executor rejected AoO)")


# BLOCKER 3: real Stun admission via direct dispatch.
func _test_stun_admission_real() -> void:
	print("[B63-CLOSED] Stun admission real")
	var results = _dispatch_at_pre_moven_with_stun(
		Vector2i(2, 2), Vector2i(3, 2),
		[Vector2i(2, 1)],
		[[&"attack_of_opportunity"]],
		[1])
	_assert(results["reactions_executed"] == 1,
		"dispatcher admits AoO attempt under Stun")
	var saw_aoo_atk: bool = false
	var saw_aoo_dmg: bool = false
	for e in results["sink"]:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and String(e.tag) == "attack_of_opportunity":
			saw_aoo_atk = true
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and String(e.tag) == "attack_of_opportunity":
			saw_aoo_dmg = true
	_assert(not saw_aoo_atk, "no tagged AoO ATTACK committed (blocks_actions)")
	_assert(not saw_aoo_dmg, "no tagged AoO DAMAGE committed")
	_assert(results["sink"].size() == 0, "sink has zero committed AoO events under Stun")
	_assert(results["mover_alive"], "mover alive (executor rejected AoO)")
	_assert(results["mover_pos"] == Vector2i(2, 2),
		"mover position unchanged (dispatch did not commit)")


# BLOCKER 7: excluded-tag real proof (UNIT_MOVE_STARTED).
func _test_excluded_tag_real_aoo_event() -> void:
	print("[B63-CLOSED] excluded-tag real (UNIT_MOVE_STARTED)")
	var reactions = _spatial_discover(
		Vector2i(2, 2), Vector2i(3, 2),
		[Vector2i(2, 1)],
		[[&"attack_of_opportunity"]],
		[1])
	# Without exclusion tag=attack_of_opportunity on event,
	# geometry would trigger.
	var s_owner: Array = []
	for r in reactions:
		s_owner.append(r)
	_assert(s_owner.size() == 1,
		"baseline: geometry triggers AoO without exclusion")
	# Now mark the event with tag=attack_of_opportunity to
	# engage the excluded-tag filter. Provider must reject.
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(2, 2), 200, 200, 5, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(2, 1), 80, 80, 5, 5, 1,
		[&"attack_of_opportunity"])
	var setup = BattleSetupScript.new(42, [mover], [knight], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	var em = sim._event_emitter
	var s = em.emit(
		BattleEventTypeScript.UNIT_MOVE_STARTED,
		0, 1, "p0", "e0", 0, "",
		Vector2i(2, 2), Vector2i(3, 2))
	s.tag = StringName("attack_of_opportunity")
	var prov = ContentReactionProviderScript.new()
	var rng = DeterministicRngScript.new(0)
	var tagged_reactions: Array = prov.discover(sim.world(), s, rng)
	_assert(tagged_reactions.size() == 0,
		"excluded tag prevents AoO self-loop on MOVE_STARTED")


# BLOCKER 8: UNIT_MOVE_STARTED alone is NOT progress.
func _test_move_started_not_progress() -> void:
	print("[B63-CLOSED] MOVE_STARTED not progress")
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 200, 200, 5, 5, 1, [])
	var dummy = BattleUnitSetupScript.new(
		"e0", &"warrior", 1, Vector2i(3, 3), 80, 80, 5, 5, 1, [])
	var setup = BattleSetupScript.new(42, [mover], [dummy], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	var em = sim._event_emitter
	var s = em.emit(
		BattleEventTypeScript.UNIT_MOVE_STARTED,
		0, 1, "p0", "e0", 0, "",
		Vector2i(0, 0), Vector2i(1, 0))
	var synth_events: Array = [s]
	_assert(not sim._has_progressed(synth_events),
		"UNIT_MOVE_STARTED alone is NOT progress")


# BLOCKER 4: AoO + Counterattack permanent regression.
func _test_aoo_counter_coexistence_permanent() -> void:
	print("[B63-CLOSED] AoO + Counterattack permanent")
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(2, 2), 200, 200, 5, 5, 1,
		[&"counterattack"])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(2, 1), 80, 80, 5, 5, 1,
		[&"attack_of_opportunity"])
	var dummy = BattleUnitSetupScript.new(
		"e1", &"warrior", 1, Vector2i(3, 3), 80, 80, 5, 5, 1, [])
	var setup = BattleSetupScript.new(42, [mover], [knight, dummy], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	var events: Array = sim._resolve_or_move(0, 2)
	var S = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.UNIT_MOVE_STARTED \
				and int(e.source_entity) == 0:
			S = e
			break
	_assert(S != null, "S present")
	if S == null:
		return
	var s_id: int = int(S.event_id)
	var s_root: int = int(S.root_action_id)
	var A = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and String(e.tag) == "attack_of_opportunity" \
				and int(e.parent_event_id) == s_id \
				and int(e.root_action_id) == s_root:
			A = e
			break
	_assert(A != null, "AoO ATTACK_RESOLVED A with parent=S")
	if A == null:
		return
	var a_id: int = int(A.event_id)
	var C = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and String(e.tag) == "counterattack" \
				and int(e.parent_event_id) == a_id \
				and int(e.source_entity) == 0:
			C = e
			break
	_assert(C != null,
		"Counterattack ATTACK_RESOLVED C with parent=A (AoO ATK)")
	if C == null:
		return
	var CD = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and String(e.tag) == "counterattack" \
				and int(e.parent_event_id) == int(C.event_id):
			CD = e
			break
	_assert(CD != null, "Counterattack DAMAGE_APPLIED CD with parent=C")
	var ids_seen: Dictionary = {}
	var dup_found: bool = false
	for e in events:
		var eid: int = int(e.event_id)
		if ids_seen.has(eid):
			dup_found = true
		ids_seen[eid] = true
	_assert(not dup_found, "no duplicate event IDs")


# BLOCKER 5: 20-run AoO determinism.
func _test_20_run_aoo_determinism() -> void:
	print("[B63-CLOSED] 20-run AoO determinism")
	var fixtures: Array = []
	for i in 20:
		var mover = BattleUnitSetupScript.new(
			"p0", &"warrior", 0, Vector2i(2, 2), 200, 200, 5, 5, 1, [])
		var knight = BattleUnitSetupScript.new(
			"e0", &"knight", 1, Vector2i(2, 1), 80, 80, 5, 5, 1,
			[&"attack_of_opportunity"])
		var dummy = BattleUnitSetupScript.new(
			"e1", &"warrior", 1, Vector2i(3, 3), 80, 80, 5, 5, 1, [])
		fixtures.append(
			BattleSetupScript.new(42, [mover], [knight, dummy], 7, 4))
	var first_trace: Array = []
	for i in fixtures.size():
		var sim = BattleSimulationScript.new()
		sim.initialize(fixtures[i])
		var run_events: Array = sim._resolve_or_move(0, 2)
		var trace: Array = []
		for e in run_events:
			trace.append(_normalize_event_14(e))
		if i == 0:
			first_trace = trace
		else:
			_assert(trace.size() == first_trace.size(),
				"run %d trace size %d == first run size %d"
				% [i, trace.size(), first_trace.size()])
			for j in trace.size():
				var a = first_trace[j]
				var b = trace[j]
				_assert(_dict_eq14(a, b),
					"run %d event %d matches first run" % [i, j])
		_assert(_all_ids_unique(run_events),
			"all event IDs unique across trace (20 runs, this run)")
	_assert(not first_trace.is_empty(), "first trace non-empty")


# BLOCKER 6: complete spatial negative matrix (direct provider).
func _test_complete_spatial_negative_matrix() -> void:
	print("[B63-CLOSED] spatial negative matrix")
	# 1->2: TRIGGER.
	var r_1_2 = _spatial_discover(
		Vector2i(1, 1), Vector2i(2, 1),
		[Vector2i(1, 2)], [[&"attack_of_opportunity"]], [1])
	_assert(r_1_2.size() == 1, "1->2 TRIGGERS AoO")
	# 1->1: NO. d_to not > range.
	var r_1_1 = _spatial_discover(
		Vector2i(1, 1), Vector2i(2, 1),
		[Vector2i(2, 1)], [[&"attack_of_opportunity"]], [1])
	_assert(r_1_1.size() == 0, "1->1 NO trigger")
	# Outside->outside: NO.
	var r_far = _spatial_discover(
		Vector2i(2, 1), Vector2i(2, 2),
		[Vector2i(3, 3)], [[&"attack_of_opportunity"]], [1])
	_assert(r_far.size() == 0, "outside->outside NO trigger")
	# 2->1: NO (entering range).
	var r_2_1 = _spatial_discover(
		Vector2i(2, 1), Vector2i(3, 1),
		[Vector2i(4, 1)], [[&"attack_of_opportunity"]], [1])
	_assert(r_2_1.size() == 0, "2->1 NO trigger (entering)")
	# Same team.
	var r_same = _spatial_discover(
		Vector2i(1, 1), Vector2i(2, 1),
		[Vector2i(1, 2)], [[&"attack_of_opportunity"]], [0])
	_assert(r_same.size() == 0, "same-team owner NO trigger")
	# Malformed cells.
	var r_bad_from = _spatial_discover(
		Vector2i(-1, -1), Vector2i(2, 1),
		[Vector2i(1, 2)], [[&"attack_of_opportunity"]], [1])
	_assert(r_bad_from.size() == 0, "malformed from_cell NO trigger")
	var r_bad_to = _spatial_discover(
		Vector2i(1, 1), Vector2i(-1, -1),
		[Vector2i(1, 2)], [[&"attack_of_opportunity"]], [1])
	_assert(r_bad_to.size() == 0, "malformed to_cell NO trigger")
	# Unknown reaction ID.
	var r_unk = _spatial_discover(
		Vector2i(1, 1), Vector2i(2, 1),
		[Vector2i(1, 2)], [[&"nonexistent_reaction"]], [1])
	_assert(r_unk.size() == 0, "unknown reaction ID NO trigger")
	# ShieldBlock inert.
	var r_sb = _spatial_discover(
		Vector2i(1, 1), Vector2i(2, 1),
		[Vector2i(1, 2)], [[&"shield_block"]], [1])
	_assert(r_sb.size() == 0, "ShieldBlock inert (event_type=-1)")


# RUNDOMAIN: shipping knight.tres owns AoO (no mutation).
func _test_rundomain_ownership_uses_shipping_knight() -> void:
	print("[B63-CLOSED] RunDomain owns shipping AoO")
	var knight_def = ContentDBScript.get_by_id_for_type(
		"units", &"knight")
	_assert(knight_def != null, "knight UnitDef loaded")
	if knight_def == null:
		return
	var raw: Array = knight_def.reaction_ids
	var found: bool = false
	for id in raw:
		if String(id) == "attack_of_opportunity":
			found = true
			break
	_assert(found,
		"shipping knight.tres already owns attack_of_opportunity")
	var state = RunDomainStateScript.new()
	state.seed = 42
	state.round_index = 1
	state.meta_modifiers = {"rest_attack_bonus": 0, "shrine_attack_bonus": 0}
	state.create_unit(&"knight", 80, RunUnitScript.LOCATION_BOARD)
	var setup = BattleSetupBuilderScript.build(state, 42, 1, 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	var owned: Array = sim.world().reaction_ids_of(0)
	var has_aoo: bool = false
	for id in owned:
		if String(id) == "attack_of_opportunity":
			has_aoo = true
			break
	_assert(has_aoo,
		"BattleWorld.reaction_ids_of(0) includes attack_of_opportunity from RunDomain pipeline")


# Helper: provider-only spatial discovery with custom fixture.
# Returns the provider's reactions array.
func _spatial_discover(from: Vector2i, to: Vector2i,
		owner_positions: Array, owner_reactions_per: Array,
		owner_teams: Array) -> Array:
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, from, 200, 200, 5, 5, 1, [])
	var setup_units: Array = []
	for i in owner_positions.size():
		setup_units.append(BattleUnitSetupScript.new(
			"e%d" % (i + 1), &"knight", int(owner_teams[i]),
			owner_positions[i], 80, 80, 5, 5, 1,
			owner_reactions_per[i]))
	var setup = BattleSetupScript.new(42, [mover], setup_units, 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	var em = sim._event_emitter
	var target_id: int = 1
	if owner_positions.size() > 0:
		target_id = owner_positions.size()
	var s = em.emit(
		BattleEventTypeScript.UNIT_MOVE_STARTED,
		0, target_id, "p0", "e0", 0, "", from, to)
	var prov = ContentReactionProviderScript.new()
	var rng = DeterministicRngScript.new(0)
	return prov.discover(sim.world(), s, rng)


# Helper: provider + dispatcher with custom fixture. Returns dict.
func _dispatch_at_pre_moven(from: Vector2i, to: Vector2i,
		owner_positions: Array, owner_reactions_per: Array,
		owner_teams: Array) -> Dictionary:
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, from, 200, 200, 5, 5, 1, [])
	var setup_units: Array = []
	for i in owner_positions.size():
		setup_units.append(BattleUnitSetupScript.new(
			"e%d" % (i + 1), &"knight", int(owner_teams[i]),
			owner_positions[i], 80, 80, 5, 5, 1,
			owner_reactions_per[i]))
	var setup = BattleSetupScript.new(42, [mover], setup_units, 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	var em = sim._event_emitter
	var target_id: int = 1
	if owner_positions.size() > 0:
		target_id = owner_positions.size()
	var s = em.emit(
		BattleEventTypeScript.UNIT_MOVE_STARTED,
		0, target_id, "p0", "e0", 0, "", from, to)
	var sink: Array = []
	var dr = sim._trigger_dispatcher.process(
		[s], sim.world(), sim._rng, em, sink,
		sim._trigger_provider, null, sim._trigger_session)
	return {
		"reactions_executed": int(dr.reactions_executed),
		"sink": sink,
		"mover_pos": sim.world().position_of(0),
	}


# Helper: same but applies Stun to owner 1 before dispatch.
func _dispatch_at_pre_moven_with_stun(from: Vector2i, to: Vector2i,
		owner_positions: Array, owner_reactions_per: Array,
		owner_teams: Array) -> Dictionary:
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, from, 200, 200, 5, 5, 1, [])
	var setup_units: Array = []
	for i in owner_positions.size():
		setup_units.append(BattleUnitSetupScript.new(
			"e%d" % (i + 1), &"knight", int(owner_teams[i]),
			owner_positions[i], 80, 80, 5, 5, 1,
			owner_reactions_per[i]))
	var setup = BattleSetupScript.new(42, [mover], setup_units, 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	var container = sim.world().create_status_container(1)
	var stun = StatusInstanceScript.new(&"stun", 0, 1, 1, 99, 0)
	container.add(stun, "unique", 1)
	var em = sim._event_emitter
	var s = em.emit(
		BattleEventTypeScript.UNIT_MOVE_STARTED,
		0, 1, "p0", "e0", 0, "", from, to)
	var sink: Array = []
	var dr = sim._trigger_dispatcher.process(
		[s], sim.world(), sim._rng, em, sink,
		sim._trigger_provider, null, sim._trigger_session)
	return {
		"reactions_executed": int(dr.reactions_executed),
		"sink": sink,
		"mover_pos": sim.world().position_of(0),
		"mover_alive": sim.world().is_alive(0),
	}


func _normalize_event_14(e) -> Dictionary:
	return {
		"type": int(e.type),
		"tag": String(e.tag),
		"source_entity": int(e.source_entity),
		"target_entity": int(e.target_entity),
		"amount": int(e.amount),
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
		if a[k] != b[k]:
			return false
	return true


func _all_ids_unique(events: Array) -> bool:
	var seen: Dictionary = {}
	for e in events:
		var eid: int = int(e.event_id)
		if seen.has(eid):
			return false
		seen[eid] = true
	return true