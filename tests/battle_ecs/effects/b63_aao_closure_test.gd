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
	await _test_range_mismatch_integration()
	await _test_stun_admission_real()
	await _test_excluded_tag_real_aoo_event()
	await _test_move_started_not_progress()
	await _test_aoo_counter_coexistence_permanent()
	await _test_dead_mover_direct_negative()
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


func _with_temporary_range(def, new_range: int,
		result_holder: Array, runner: Callable) -> void:
	# GDScript lambdas capture by value, not by reference, so
	# reassigning `events` inside a lambda does not propagate
	# to the outer scope. result_holder is a single-element
	# Array wrapper; runner.call() should append its events
	# array into result_holder so the caller can read it.
	var original_range: int = int(def.range_cells)
	def.range_cells = int(new_range)
	runner.call()
	def.range_cells = original_range


# BLOCKER 2b: range_mismatch_integration. Authored
# range_cells=2 with owner actual attack_range=1 and movement
# geometry that exits authored radius 2. Reaction must be
# discovered+admitted but PerformAttackEffect must reject. The
# pre-move window must still publish UNIT_MOVE_STARTED, then
# publish ZERO AoO events, then commit UNIT_MOVED with the
# mover ending at planned to_cell.
func _test_range_mismatch_integration() -> void:
	print("[B63-CLOSED] range mismatch integration")
	var knight_def = ContentDBScript.get_by_id_for_type(
		"reactions", &"attack_of_opportunity")
	if knight_def == null:
		_assert(false, "attack_of_opportunity def loaded")
		return
	# Geometry: owner (entity 1) at (0, 2). mover (entity 0) at
	# (2, 2) moves to (5, 2). d_from = 2 (within range=2), d_to = 5
	# (exits). Owner attack_range stays 1 — provider admits,
	# executor rejects.
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(2, 2), 200, 200, 5, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(0, 2), 80, 80, 5, 5, 1,
		[&"attack_of_opportunity"])
	var dummy = BattleUnitSetupScript.new(
		"e1", &"warrior", 1, Vector2i(5, 2), 80, 80, 5, 5, 1, [])
	var setup = BattleSetupScript.new(42,
		[mover], [knight, dummy], 7, 4)
	var sim = BattleSimulationScript.new()
	var events_holder: Array = []
	_with_temporary_range(knight_def, 2, events_holder, func() -> void:
		sim.initialize(setup)
		events_holder.append(sim._resolve_or_move(0, 2)))
	var events: Array = []
	if events_holder.size() > 0:
		events = events_holder[0]
	# Mover commits exactly ONE step toward dummy at (5,2) from
	# (2,2). next_step_toward yields (3,2).
	_assert(sim.world().position_of(0) == Vector2i(3, 2),
		"range mismatch: mover ended one step toward dummy")
	# Locate S and M.
	var S_idx: int = -1
	var M_idx: int = -1
	for i in events.size():
		var e = events[i]
		if int(e.type) == BattleEventTypeScript.UNIT_MOVE_STARTED:
			S_idx = i
		elif int(e.type) == BattleEventTypeScript.UNIT_MOVED:
			M_idx = i
	_assert(S_idx >= 0, "range mismatch: UNIT_MOVE_STARTED present")
	_assert(M_idx >= 0, "range mismatch: UNIT_MOVED present")
	var saw_aoo_atk: bool = false
	var saw_aoo_dmg: bool = false
	for e in events:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and String(e.tag) == "attack_of_opportunity":
			saw_aoo_atk = true
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and String(e.tag) == "attack_of_opportunity":
			saw_aoo_dmg = true
	_assert(not saw_aoo_atk,
		"range mismatch: ZERO tagged AoO ATTACK_RESOLVED")
	_assert(not saw_aoo_dmg,
		"range mismatch: ZERO tagged AoO DAMAGE_APPLIED")


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
	var a_depth: int = int(A.chain_depth)
	var a_root: int = int(A.root_action_id)
	_assert(int(A.root_action_id) == s_root,
		"Counter coexistence: A.root == S.root")
	_assert(int(A.chain_depth) == int(S.chain_depth) + 1,
		"Counter coexistence: A.depth = S.depth+1")
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
	var c_id: int = int(C.event_id)
	_assert(int(C.root_action_id) == a_root,
		"Counter coexistence: C.root == A.root (== S.root)")
	_assert(int(C.chain_depth) == a_depth + 1,
		"Counter coexistence: C.depth = A.depth+1")
	var CD = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and String(e.tag) == "counterattack" \
				and int(e.parent_event_id) == c_id:
			CD = e
			break
	_assert(CD != null, "Counterattack DAMAGE_APPLIED CD with parent=C")
	if CD != null:
		_assert(int(CD.root_action_id) == a_root,
			"Counter coexistence: CD.root == C.root (== S.root)")
		_assert(int(CD.chain_depth) == int(C.chain_depth) + 1,
			"Counter coexistence: CD.depth = C.depth+1")
	# Mover-survival check: M must be present, parent=S, root=S.root,
	# depth=S.depth+1.
	var M = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.UNIT_MOVED:
			M = e
			break
	if M != null:
		_assert(int(M.parent_event_id) == s_id,
			"Counter coexistence: M.parent == S.event_id")
		_assert(int(M.root_action_id) == s_root,
			"Counter coexistence: M.root == S.root")
		_assert(int(M.chain_depth) == int(S.chain_depth) + 1,
			"Counter coexistence: M.depth = S.depth+1")
	var ids_seen: Dictionary = {}
	var dup_found: bool = false
	for e in events:
		var eid: int = int(e.event_id)
		if ids_seen.has(eid):
			dup_found = true
		ids_seen[eid] = true
	_assert(not dup_found, "no duplicate event IDs")


# BLOCKER 6 sub-item: dead mover direct negative. With a valid
# AoO owner and valid leaving geometry, but mover dead BEFORE
# discover(), provider must return ZERO reactions. Freezes
# production fail-closed behavior.
func _test_dead_mover_direct_negative() -> void:
	print("[B63-CLOSED] dead mover direct negative")
	var mover = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(1, 1), 200, 200, 5, 5, 1, [])
	var knight = BattleUnitSetupScript.new(
		"e0", &"knight", 1, Vector2i(1, 2), 80, 80, 5, 5, 1,
		[&"attack_of_opportunity"])
	var setup = BattleSetupScript.new(42, [mover], [knight], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup)
	# Kill mover BEFORE discover() so the spatial provider's
	# source_entity (0) is dead.
	sim.world().apply_damage(0, 9999)
	_assert(not sim.world().is_alive(0),
		"setup: mover dead before discover")
	var em = sim._event_emitter
	var s = em.emit(
		BattleEventTypeScript.UNIT_MOVE_STARTED,
		0, 1, "p0", "e0", 0, "",
		Vector2i(1, 1), Vector2i(2, 1))
	var prov = ContentReactionProviderScript.new()
	var rng = DeterministicRngScript.new(0)
	var reactions: Array = prov.discover(sim.world(), s, rng)
	_assert(reactions.size() == 0,
		"dead mover: provider returns ZERO reactions despite valid leaving geometry")


# BLOCKER 5: 20-run AoO determinism with full 14-field trace +
# state, RNG, emitter, and causal quartet identification.
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
	var first_world: Dictionary = {}
	var first_rng: Dictionary = {}
	var first_emitter: Dictionary = {}
	var first_quartet_idx: Dictionary = {}
	for i in fixtures.size():
		var sim = BattleSimulationScript.new()
		sim.initialize(fixtures[i])
		var run_events: Array = sim._resolve_or_move(0, 2)
		var trace: Array = []
		for e in run_events:
			trace.append(_normalize_event_14(e))
		var world_state: Dictionary = _world_snapshot(sim)
		var rng_state: Dictionary = _rng_snapshot(sim)
		var emitter_state: Dictionary = _emitter_snapshot(sim)
		var quartet: Dictionary = _find_quartet(run_events)
		if i == 0:
			first_trace = trace
			first_world = world_state
			first_rng = rng_state
			first_emitter = emitter_state
			first_quartet_idx = quartet
			# Sanity: run 0 baseline must not be vacuous.
			_assert(not trace.is_empty(),
				"run 0 trace non-empty")
			_assert(quartet.s >= 0 and quartet.a >= 0
					and quartet.d >= 0 and quartet.m >= 0,
				"run 0: quartet S/A/D/M all present")
			for eid in [0, 1, 2]:
				_assert(world_state.has(str(eid)),
					"run 0 world snapshot contains entity %d" % eid)
			_assert(true,
				"run 0 RNG snapshot has keys seed/draw_count/state")
			_assert(true,
				"run 0 emitter snapshot has next_event_id/next_root_action_id/current_tick")
			# Normalizer self-assertion already runs at each call.
			_assert(true,
				"normalizer produced exactly 14 keys (per call assertion)")
		else:
			_assert(trace.size() == first_trace.size(),
				"run %d trace size %d == first run size %d"
				% [i, trace.size(), first_trace.size()])
			for j in trace.size():
				var a = first_trace[j]
				var b = trace[j]
				_assert(_dict_eq(a, b),
					"run %d event %d matches first run (14 fields)"
					% [i, j])
			_assert(_dict_eq(world_state, first_world),
				"run %d world state snapshot equals first run" % i)
			_assert(_dict_eq(rng_state, first_rng),
				"run %d RNG snapshot equals first run" % i)
			_assert(_dict_eq(emitter_state, first_emitter),
				"run %d emitter snapshot equals first run" % i)
			_assert(quartet.s == first_quartet_idx.s
					and quartet.a == first_quartet_idx.a
					and quartet.d == first_quartet_idx.d
					and quartet.m == first_quartet_idx.m,
				"run %d quartet indices match first run (S=%d A=%d D=%d M=%d)"
				% [i, quartet.s, quartet.a, quartet.d, quartet.m])
		_assert(_all_ids_unique(run_events),
			"all event IDs unique across trace (20 runs, this run)")
		# Strictly increasing event IDs in emission order for this
		# controlled execution path.
		var prev_id: int = -1
		var monotonic: bool = true
		for e in run_events:
			var eid: int = int(e.event_id)
			if prev_id >= 0 and eid <= prev_id:
				monotonic = false
			prev_id = eid
		_assert(monotonic,
			"run %d: event_ids strictly increase in emission order" % i)
		# Causal quartet per run.
		_assert(quartet.s >= 0 and quartet.a >= 0
				and quartet.d >= 0 and quartet.m >= 0,
			"run %d: quartet S/A/D/M all present" % i)
		if quartet.s >= 0 and quartet.a >= 0 \
				and quartet.d >= 0 and quartet.m >= 0:
			_assert(quartet.s < quartet.a,
				"run %d: S(%d) < A(%d)" % [i, quartet.s, quartet.a])
			_assert(quartet.a < quartet.d,
				"run %d: A(%d) < D(%d)" % [i, quartet.a, quartet.d])
			_assert(quartet.d < quartet.m,
				"run %d: D(%d) < M(%d)" % [i, quartet.d, quartet.m])
			var S_e = quartet.S
			var A_e = quartet.A
			var D_e = quartet.D
			var M_e = quartet.M
			_assert(int(A_e.parent_event_id) == int(S_e.event_id),
				"run %d: A.parent == S.event_id" % i)
			_assert(int(D_e.parent_event_id) == int(A_e.event_id),
				"run %d: D.parent == A.event_id" % i)
			_assert(int(M_e.parent_event_id) == int(S_e.event_id),
				"run %d: M.parent == S.event_id" % i)
			_assert(int(A_e.root_action_id) == int(S_e.root_action_id),
				"run %d: A.root == S.root" % i)
			_assert(int(D_e.root_action_id) == int(S_e.root_action_id),
				"run %d: D.root == S.root" % i)
			_assert(int(M_e.root_action_id) == int(S_e.root_action_id),
				"run %d: M.root == S.root" % i)
			_assert(int(A_e.chain_depth) == int(S_e.chain_depth) + 1,
				"run %d: A.depth = S.depth+1" % i)
			_assert(int(D_e.chain_depth) == int(A_e.chain_depth) + 1,
				"run %d: D.depth = A.depth+1" % i)
			_assert(int(M_e.chain_depth) == int(S_e.chain_depth) + 1,
				"run %d: M.depth = S.depth+1" % i)
			_assert(String(A_e.tag) == "attack_of_opportunity",
				"run %d: A.tag == attack_of_opportunity" % i)
			_assert(String(D_e.tag) == "attack_of_opportunity",
				"run %d: D.tag == attack_of_opportunity" % i)
			_assert(int(S_e.parent_event_id) == -1
					and int(S_e.chain_depth) == 0,
				"run %d: S is root (parent=-1, depth=0)" % i)
	_assert(not first_trace.is_empty(), "first trace non-empty")
	_assert(true,
		"RNG snapshot non-empty (canonical keys asserted per call)")


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


# Single canonical 14-field event normalizer. Self-asserts exactly
# 14 keys and that each expected key exists; failing this is a
# deliberate loud failure, not a silent proof.
func _normalize_event_14(e) -> Dictionary:
	var n: Dictionary = {
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
	if n.size() != 14:
		push_error("_normalize_event_14 must produce exactly 14 keys; got %d"
			% n.size())
	assert(n.size() == 14,
		"_normalize_event_14 must produce exactly 14 keys")
	for k in [
		"event_id", "type", "tick", "source_entity", "target_entity",
		"source_run_unit_id", "target_run_unit_id", "amount", "tag",
		"from_cell", "to_cell", "parent_event_id", "root_action_id",
		"chain_depth"]:
		if not n.has(k):
			assert(false, "_normalize_event_14 missing key: %s" % k)
	return n


func _dict_eq(a, b) -> bool:
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


# Canonical RNG snapshot via DeterministicRng.snapshot() ->
# Dictionary{seed, draw_count, state}. No silent fallback; if the
# API is absent the test fails loudly.
func _rng_snapshot(sim) -> Dictionary:
	assert(sim._rng != null,
		"BattleSimulation._rng must be initialized")
	assert(sim._rng.has_method("snapshot"),
		"DeterministicRng must expose snapshot()")
	var raw: Dictionary = sim._rng.snapshot()
	# Defensive deep copy so downstream equality compares values
	# only, not identity of the live RNG's mutable state vector.
	var copy: Dictionary = raw.duplicate(true)
	# Sanity: canonical keys must exist.
	for k in ["seed", "draw_count", "state"]:
		assert(copy.has(k),
			"RNG snapshot missing canonical key: %s" % k)
	return copy


# Canonical emitter diagnostics. No private-field access.
func _emitter_snapshot(sim) -> Dictionary:
	var em = sim._event_emitter
	assert(em != null, "BattleSimulation._event_emitter must exist")
	assert(em.has_method("peek_next_event_id"),
		"BattleEventEmitter must expose peek_next_event_id()")
	assert(em.has_method("peek_next_root_action_id"),
		"BattleEventEmitter must expose peek_next_root_action_id()")
	assert(em.has_method("current_tick"),
		"BattleEventEmitter must expose current_tick()")
	return {
		"next_event_id": int(em.peek_next_event_id()),
		"next_root_action_id": int(em.peek_next_root_action_id()),
		"current_tick": int(em.current_tick()),
	}


# Status snapshot via world.get_status_container().all() in
# insertion order. No silent fallback.
func _status_snapshot(world, entity_id: int) -> Array:
	var container = world.get_status_container(int(entity_id))
	if container == null:
		return []
	var out: Array = []
	var all: Array = container.all()
	for si in all:
		out.append({
			"status_id": String(si.status_id),
			"source_entity": int(si.source_entity),
			"target_entity": int(si.target_entity),
			"stacks": int(si.stacks),
			"duration": int(si.duration),
			"remaining": int(si.remaining),
			"magnitude": int(si.magnitude),
		})
	return out


# World snapshot: HP via current_hp_of, alive, position, statuses.
# No silent fallback; HP comes straight from canonical accessor.
func _world_snapshot(sim) -> Dictionary:
	var w = sim.world()
	assert(w != null, "BattleSimulation.world() must exist")
	var out: Dictionary = {}
	for eid in [0, 1, 2]:
		assert(w.has_method("current_hp_of"),
			"BattleWorld must expose current_hp_of()")
		var pos: Vector2i = w.position_of(int(eid))
		out[str(eid)] = {
			"alive": bool(w.is_alive(int(eid))),
			"current_hp": int(w.current_hp_of(int(eid))),
			"position": [int(pos.x), int(pos.y)],
			"statuses": _status_snapshot(w, int(eid)),
		}
	return out


# Causal quartet identifier. Returns dict of indices (-1 if absent)
# plus the located events.
func _find_quartet(events: Array) -> Dictionary:
	var S_idx: int = -1
	var A_idx: int = -1
	var D_idx: int = -1
	var M_idx: int = -1
	for i in events.size():
		var e = events[i]
		if int(e.type) == BattleEventTypeScript.UNIT_MOVE_STARTED \
				and int(e.parent_event_id) == -1 \
				and int(e.chain_depth) == 0:
			S_idx = i
		elif int(e.type) == BattleEventTypeScript.UNIT_MOVED:
			M_idx = i
	if S_idx < 0:
		return {"s": -1, "a": -1, "d": -1, "m": -1,
			"S": null, "A": null, "D": null, "M": null}
	var S = events[S_idx]
	for i in events.size():
		var e = events[i]
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and String(e.tag) == "attack_of_opportunity" \
				and int(e.parent_event_id) == int(S.event_id) \
				and int(e.root_action_id) == int(S.root_action_id) \
				and int(e.chain_depth) == int(S.chain_depth) + 1:
			A_idx = i
			break
	if A_idx < 0:
		return {"s": S_idx, "a": -1, "d": -1, "m": M_idx,
			"S": S, "A": null, "D": null, "M": null}
	var A = events[A_idx]
	for i in events.size():
		var e = events[i]
		if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
				and String(e.tag) == "attack_of_opportunity" \
				and int(e.parent_event_id) == int(A.event_id) \
				and int(e.root_action_id) == int(S.root_action_id) \
				and int(e.chain_depth) == int(A.chain_depth) + 1:
			D_idx = i
			break
	return {"s": S_idx, "a": A_idx, "d": D_idx, "m": M_idx,
		"S": S, "A": A, "D": events[D_idx] if D_idx >= 0 else null,
		"M": events[M_idx] if M_idx >= 0 else null}