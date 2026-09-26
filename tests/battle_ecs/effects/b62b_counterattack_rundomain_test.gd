extends SceneTree
## B6.2b / Gauntlet E — Real RunDomain shipping E2E.
##
## Uses REAL RunDomainState, real board guardian RunUnit, real
## ContentDB (guardian.tres owns counterattack), real
## BattleSetupBuilder, real BattleSimulation default provider.
##
## PROVES: ownership pipeline (UnitDef -> BattleSetupBuilder ->
## BattleUnitSetup -> BattleSetup -> BattleWorld) flows end-to-end
## and the shipped Counterattack fires with correct ancestry +
## tagged events.

const BattleSimulationScript = preload(
	"res://core/battle_ecs/battle_simulation.gd")
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
const RunDomainStateScript = preload(
	"res://core/progression/run_domain_state.gd")
const RunUnitScript = preload(
	"res://core/progression/run_unit.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	ContentDBScript.load_all()
	await _test_ownership_pipeline_proven_via_real_builder()
	await _test_default_provider_runs_counterattack_e2e()
	await _test_reinit_drops_custom_provider()
	print("\n=== B6.2b shipping E2E: %d pass / %d fail ===\n" % [_passed, _failed])
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


func _assert_causal_trace_integrity(events: Array) -> void:
	# Every event_id unique.
	var seen: Dictionary = {}
	for e in events:
		var id: int = int(e.event_id)
		if seen.has(id):
			_assert(false, "duplicate event_id %d in trace" % id)
			return
		seen[id] = true
	# Every root: parent_event_id == -1, chain_depth == 0.
	# Every child: parent exists earlier; shares root; depth+1.
	var ev_by_id: Dictionary = {}
	for i in events.size():
		ev_by_id[int(events[i].event_id)] = events[i]
	for i in events.size():
		var e = events[i]
		var pid: int = int(e.parent_event_id)
		if pid == -1:
			_assert(int(e.chain_depth) == 0,
				"root event id=%d chain_depth==0" % int(e.event_id))
		else:
			if not ev_by_id.has(pid):
				_assert(false,
					"event id=%d parent_event_id=%d not in trace"
					% [int(e.event_id), pid])
				return
			var p = ev_by_id[pid]
			_assert(int(e.root_action_id) == int(p.root_action_id),
				"event id=%d shares root with parent" % int(e.event_id))
			_assert(int(e.chain_depth) == int(p.chain_depth) + 1,
				"event id=%d chain_depth==parent+1" % int(e.event_id))


func _test_ownership_pipeline_proven_via_real_builder() -> void:
	print("[B62B-PIPE] ownership_pipeline_via_real_builder")
	# Save original guardian def reaction_ids so we can restore.
	var guardian_def = ContentDBScript.get_by_id_for_type(
		"units", &"guardian")
	_assert(guardian_def != null, "guardian UnitDef loaded")
	if guardian_def == null:
		return
	var original_guardian_ids: Array[StringName] = \
		Array(guardian_def.reaction_ids) as Array[StringName]
	# Guardian SHOULD already own [&"counterattack"] per
	# shipping content. Verify without mutating.
	_assert(String(guardian_def.reaction_ids[0]) == "counterattack",
		"guardian.reaction_ids[0] == 'counterattack' (got '%s')"
		% String(guardian_def.reaction_ids[0]))
	# Construct real RunDomainState with board guardian.
	var state: RefCounted = RunDomainStateScript.new()
	state.seed = 42
	state.round_index = 1
	state.meta_modifiers = {
		"rest_attack_bonus": 0, "shrine_attack_bonus": 0,
	}
	var guardian_unit = state.create_unit(&"guardian", 250,
		RunUnitScript.LOCATION_BOARD)
	_assert(guardian_unit != null, "guardian RunUnit created")
	if guardian_unit == null:
		guardian_def.reaction_ids = original_guardian_ids
		return
	# Real builder call.
	var setup = BattleSetupBuilderScript.build(state, 42, 1, 7, 4)
	_assert(setup != null, "BattleSetupBuilder.build() returned a setup")
	if setup == null:
		guardian_def.reaction_ids = original_guardian_ids
		return
	_assert(setup.player_units.size() >= 1,
		"setup has at least 1 player unit")
	if setup.player_units.is_empty():
		guardian_def.reaction_ids = original_guardian_ids
		return
	var prow = setup.player_units[0]
	_assert(String(prow.definition_id) == "guardian",
		"player row built from guardian (got '%s')"
		% String(prow.definition_id))
	# Row owns counterattack via builder.
	var prow_reactions: Array = Array(prow.reaction_ids)
	_assert(prow_reactions.size() == 1
			and String(prow_reactions[0]) == "counterattack",
		"player row owns [counterattack] (got %s)"
		% str(prow_reactions))
	# source_run_unit_id preserved.
	_assert(prow.source_run_unit_id == guardian_unit.instance_id,
		"player row preserves guardian instance_id")
	# BattleWorld spawn copies the snapshot.
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(setup)
	var w_reactions: Array = w.reaction_ids_of(0)
	_assert(w_reactions.size() == 1
			and String(w_reactions[0]) == "counterattack",
		"BattleWorld entity 0 owns [counterattack] (got %s)"
		% str(w_reactions))
	# Source Run identity from world accessor.
	_assert(String(w.source_run_unit_id_of(0))
			== guardian_unit.instance_id,
		"world source_run_unit_id preserves guardian instance_id")
	# Restore content (test must not leave global mutated).
	guardian_def.reaction_ids = original_guardian_ids


func _test_default_provider_runs_counterattack_e2e() -> void:
	print("[B62B-E2E] default_provider_runs_counterattack_e2e")
	# Save original guardian reaction_ids.
	var guardian_def = ContentDBScript.get_by_id_for_type(
		"units", &"guardian")
	var original_guardian_ids: Array[StringName] = \
		Array(guardian_def.reaction_ids) as Array[StringName]
	# Confirm shipping content (already set in B6.2b, do not
	# mutate this test runs against).
	_assert(String(guardian_def.reaction_ids[0]) == "counterattack",
		"guardian owns counterattack (shipping content)")
	# Construct real RunDomainState with board guardian.
	var state: RefCounted = RunDomainStateScript.new()
	state.seed = 42
	state.round_index = 1
	state.meta_modifiers = {
		"rest_attack_bonus": 0, "shrine_attack_bonus": 0,
	}
	state.create_unit(&"guardian", 250,
		RunUnitScript.LOCATION_BOARD)
	var setup = BattleSetupBuilderScript.build(state, 42, 1, 7, 4)
	# Initialize BattleSimulation (default provider installed).
	var sim = BattleSimulationScript.new()
	var ok: bool = sim.initialize(setup)
	_assert(ok == true, "BattleSimulation.initialize() ok")
	if not ok:
		guardian_def.reaction_ids = original_guardian_ids
		return
	# Force a small but real tick budget so termination is
	# deterministic.
	sim.set_max_ticks(8)
	# Run until finished.
	var events: Array = []
	while not sim.is_finished():
		events.append_array(sim.step_tick())
	_assert(events.size() > 0, "battle produced events")
	if events.is_empty():
		guardian_def.reaction_ids = original_guardian_ids
		return
	# Find an enemy ATTACK_RESOLVED (target=0 guardian) that
	# was successfully countered. Iterate enemy ATKs and check
	# that at least one of them has a counter ATTACK child.
	# This matches the B6.2b spec: counter fires on ATTACK_RESOLVED
	# and is parented to the ATK that triggered it.
	var normal_atk = null
	var counter_atk = null
	for e in events:
		if int(e.type) == BattleEventTypeScript.ATTACK_RESOLVED \
				and int(e.target_entity) == 0 \
				and int(e.source_entity) == 1 \
				and int(e.chain_depth) == 0 \
				and int(e.parent_event_id) == -1:
			# Look for a counter ATTACK child whose parent is
			# this enemy ATK.
			var atk_eid: int = int(e.event_id)
			for child in events:
				if int(child.type) == BattleEventTypeScript.ATTACK_RESOLVED \
						and int(child.parent_event_id) == atk_eid \
						and int(child.source_entity) == 0 \
						and String(child.tag) == "counterattack":
					normal_atk = e
					counter_atk = child
					break
			if normal_atk != null:
				break
	_assert(normal_atk != null and counter_atk != null,
		"enemy normal ATTACK_RESOLVED with counterattack child found")
	# Find counter DAMAGE_APPLIED whose parent is counter_atk.
	if counter_atk != null:
		var counter_dmg = null
		for e in events:
			if int(e.type) == BattleEventTypeScript.DAMAGE_APPLIED \
					and int(e.parent_event_id) == int(counter_atk.event_id) \
					and int(e.root_action_id) == int(counter_atk.root_action_id) \
					and int(e.chain_depth) == int(counter_atk.chain_depth) + 1:
				counter_dmg = e
				break
		_assert(counter_dmg != null,
			"counterattack DAMAGE_APPLIED under counter_atk")
		_assert(counter_dmg != null and String(counter_dmg.tag) == "counterattack",
			"counterattack DAMAGE_APPLIED tagged 'counterattack'")
	# Causal trace integrity.
	_assert_causal_trace_integrity(events)
	# Real BattleResult produced.
	var result = sim.get_result()
	_assert(result != null, "real BattleResult produced")
	# Guardian source_run_unit_id preserved on counter events.
	if counter_atk != null:
		_assert(String(counter_atk.source_run_unit_id)
				== state.units[0].instance_id,
			"counter ATTACK source_run_unit_id = guardian instance_id")
	# Restore global content.
	guardian_def.reaction_ids = original_guardian_ids


func _test_reinit_drops_custom_provider() -> void:
	print("[B62B-REINIT] reinitialize_drops_custom_provider")
	# Build a tiny counter-less battle.
	var BattleSetupScript = preload(
		"res://core/battle_ecs/battle_setup.gd")
	var BattleUnitSetupScript = preload(
		"res://core/battle_ecs/battle_unit_setup.gd")
	var p = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 3, [])
	var e = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 3), 100, 100, 20, 5, 3, [])
	var setup_a = BattleSetupScript.new(42, [p], [e], 7, 4)
	var setup_b = BattleSetupScript.new(42, [p], [e], 7, 4)
	var sim = BattleSimulationScript.new()
	sim.initialize(setup_a)
	# Install a custom counting provider.
	var CountingProvider = preload(
		"res://core/battle_ecs/triggers/trigger_provider.gd")
	# We can't easily create an inline provider script here
	# without writing it as a separate file. Instead, we test
	# that reinitialize replaces whatever provider was set,
	# including a different default-style provider. We can
	# reuse the no-op base class — reinitialize will overwrite
	# it with ContentReactionProvider.
	var custom = CountingProvider.new()  # base no-op
	sim.set_trigger_provider(custom)
	# Confirm custom is in place by inspecting trigger_provider
	# accessor (none exists publicly — we trust via reinitialize).
	sim.initialize(setup_b)
	# After re-init, sim must be on ContentReactionProvider.
	# We check indirectly: the type of the provider object is
	# a ContentReactionProvider.
	var prov = sim._trigger_provider
	_assert(prov != null, "provider installed after reinitialize")
	_assert(prov.get_script().resource_path.ends_with(
			"content_reaction_provider.gd"),
		"provider is ContentReactionProvider (got '%s')"
		% str(prov.get_script().resource_path))
