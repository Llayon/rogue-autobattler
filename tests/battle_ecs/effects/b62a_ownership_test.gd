extends SceneTree
## B6.2a — BattleUnitSetup / BattleSetup / BattleSetupBuilder /
## BattleWorld reaction ownership and immutability proofs.
##
## Each ownership boundary is independently tested:
##   1) BattleUnitSetup snapshots reaction_ids into an OWN
##      array (caller mutation must not leak).
##   2) BattleSetup defensive-copies each unit row, including
##      reaction_ids (independent array per layer).
##   3) BattleSetup.validate rejects per-unit duplicate IDs
##      and empty &"" entries; preserves caller order; does
##      NOT depend on ContentDB.
##   4) BattleSetupBuilder snapshots UnitDef.reaction_ids
##      into BattleUnitSetup. Later UnitDef mutation must
##      NOT alter the produced BattleSetup.
##   5) BattleSimulation.initialize -> BattleWorld spawn copies
##      reaction_ids into a NEW per-entity array. Mutating
##      BattleSetup after spawn must NOT alter world ownership.
##   6) reaction_ids_of() returns a defensive copy so caller
##      mutation does not leak.

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
const DeterministicRngScript = preload(
	"res://core/rng/deterministic_rng.gd")
const RunDomainStateScript = preload(
	"res://core/progression/run_domain_state.gd")
const RunUnitScript = preload(
	"res://core/progression/run_unit.gd")
const ContentDBScript = preload(
	"res://core/utils/content_db.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_battle_unit_setup_owns_its_array()
	await _test_battle_unit_setup_preserves_order()
	await _test_battle_setup_defensive_copy_isolation()
	await _test_battle_setup_validate_duplicate_ids_rejected()
	await _test_battle_setup_validate_empty_id_rejected()
	await _test_battle_setup_validate_unknown_id_accepted_structurally()
	await _test_battle_setup_builder_unitdef_mutation_isolated()
	await _test_battle_world_spawn_snapshot_isolated()
	await _test_reaction_ids_of_returns_defensive_copy()
	await _test_unknown_entity_returns_empty_array()
	await _test_duplicate_units_can_share_reaction_id_across_entities()
	await _test_no_gameplay_trace_change_no_provider()
	print("\n=== B6.2a ownership + snapshot: %d pass / %d fail ===\n" % [_passed, _failed])
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


func _arr_eq(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if String(a[i]) != String(b[i]):
			return false
	return true


func _arr_alias(a, b) -> bool:
	# GDScript 4 has no public identity check for Array. We
	# exploit Dictionary key storage: store each array in a
	# fresh Dictionary as a key, then look up the second array
	# in the first Dictionary. If the dictionaries are the
	# same instance, lookup is O(1). The cleanest portable
	# check is: if a and b share storage, mutating a's first
	# element also mutates b's first element. Use that.
	if a.size() == 0 and b.size() == 0:
		return false  # both empty, can't distinguish by mutation
	var first = a[0]
	a[0] = "ALIAS_PROBE"
	var aliased: bool = (b.size() > 0 and str(b[0]) == "ALIAS_PROBE")
	a[0] = first
	return aliased


# ============================================================
# 1) BattleUnitSetup owns its own reaction_ids array.
# ============================================================
func _test_battle_unit_setup_owns_its_array() -> void:
	print("[B62A-BUS] battle_unit_setup_owns_its_array")
	var src: Array = [&"reaction_a", &"reaction_b"]
	var bus = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1, src)
	# src and bus.reaction_ids are INDEPENDENT arrays.
	_assert(not _arr_alias(bus.reaction_ids, src),
		"reaction_ids storage is NOT the caller array alias")
	# Mutate caller; bus must not change.
	src.append(&"reaction_evil")
	_assert(bus.reaction_ids.size() == 2,
		"bus.reaction_ids unaffected by caller append (got size %d)"
		% bus.reaction_ids.size())
	_assert(String(bus.reaction_ids[0]) == "reaction_a",
		"bus.reaction_ids[0] preserved")
	_assert(String(bus.reaction_ids[1]) == "reaction_b",
		"bus.reaction_ids[1] preserved")
	# Mutate bus; caller must not change.
	bus.reaction_ids.append(&"reaction_x")
	_assert(src.size() == 3,
		"caller src unaffected by bus append (got size %d)" % src.size())
	_assert(String(src[2]) == "reaction_evil",
		"caller src preserved its own appended entry")


# ============================================================
# 2) BattleUnitSetup preserves order.
# ============================================================
func _test_battle_unit_setup_preserves_order() -> void:
	print("[B62A-BUS] battle_unit_setup_preserves_order")
	var src: Array = [&"reaction_c", &"reaction_a", &"reaction_b"]
	var bus = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1, src)
	_assert(_arr_eq(bus.reaction_ids, [&"reaction_c", &"reaction_a", &"reaction_b"]),
		"reaction_ids preserved in caller order")


# ============================================================
# 3) BattleSetup defensive copy isolation.
# ============================================================
func _test_battle_setup_defensive_copy_isolation() -> void:
	print("[B62A-BS] battle_setup_defensive_copy_isolation")
	var bus1 = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1,
		[&"reaction_a", &"reaction_b"])
	var bus2 = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1,
		[&"reaction_a"])
	var setup = BattleSetupScript.new(42, [bus1], [bus2], 7, 4)
	# setup.player_units[0].reaction_ids is NOT the same array
	# as bus1.reaction_ids.
	var player_row = setup.player_units[0]
	_assert(not _arr_alias(player_row.reaction_ids, bus1.reaction_ids),
		"setup row's reaction_ids is NOT a caller alias")
	# Mutate the original bus1; setup must not change.
	bus1.reaction_ids.append(&"reaction_evil")
	_assert(player_row.reaction_ids.size() == 2,
		"setup row unaffected by caller mutation (got size %d)"
		% player_row.reaction_ids.size())
	# Mutate the setup row; bus1 must not change.
	player_row.reaction_ids.append(&"reaction_x")
	_assert(bus1.reaction_ids.size() == 3,
		"original caller unaffected by setup row mutation "
		+ "(got size %d)" % bus1.reaction_ids.size())
	_assert(String(bus1.reaction_ids[2]) == "reaction_evil",
		"original caller preserved its own appended entry")


# ============================================================
# 4) BattleSetup.validate rejects per-unit duplicate IDs.
# ============================================================
func _test_battle_setup_validate_duplicate_ids_rejected() -> void:
	print("[B62A-VAL] validate_duplicate_ids_rejected")
	var bus = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1,
		[&"reaction_a", &"reaction_a"])
	var ebus = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1, [])
	var setup = BattleSetupScript.new(42, [bus], [ebus], 7, 4)
	var msg: String = setup.validate()
	_assert(msg != "",
		"validate rejects per-unit duplicate reaction IDs")
	_assert(String(msg).find("reaction_a") >= 0
			or String(msg).find("duplicate") >= 0
			or String(msg).find("reaction") >= 0,
		"validate message mentions the duplicate (got '%s')" % msg)


# ============================================================
# 5) BattleSetup.validate rejects empty &"" IDs.
# ============================================================
func _test_battle_setup_validate_empty_id_rejected() -> void:
	print("[B62A-VAL] validate_empty_id_rejected")
	var bus = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1,
		[&"reaction_a", &""])
	var ebus = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1, [])
	var setup = BattleSetupScript.new(42, [bus], [ebus], 7, 4)
	var msg: String = setup.validate()
	_assert(msg != "",
		"validate rejects empty &'' reaction ID")


# ============================================================
# 6) BattleSetup.validate accepts unknown reaction IDs
#    structurally (does NOT depend on ContentDB).
# ============================================================
func _test_battle_setup_validate_unknown_id_accepted_structurally() -> void:
	print("[B62A-VAL] validate_unknown_id_accepted_structurally")
	var bus = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1,
		[&"future_reaction_not_yet_authored"])
	var ebus = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1, [])
	var setup = BattleSetupScript.new(42, [bus], [ebus], 7, 4)
	var msg: String = setup.validate()
	_assert(msg == "",
		"validate accepts unknown reaction IDs structurally "
		+ "(no ContentDB dependency). got '%s'" % msg)


# ============================================================
# 7) BattleSetupBuilder.build() snapshots UnitDef.reaction_ids.
#    Mutating UnitDef.reaction_ids after build must NOT alter
#    the produced BattleSetup. Uses the REAL builder path with
#    real loaded ContentDB definitions (warrior unit +
#    deterministic round-1 enemy pick). Restores all mutated
#    content definitions before returning.
# ============================================================
func _test_battle_setup_builder_unitdef_mutation_isolated() -> void:
	print("[B62A-BSB] builder_unitdef_mutation_isolated")
	# Ensure ContentDB is loaded.
	ContentDBScript.ensure_loaded()
	# Resolve real player def from ContentDB. Save original
	# reaction_ids so we can restore them on every path.
	var warrior_def = ContentDBScript.get_by_id_for_type(
		"units", &"warrior")
	_assert(warrior_def != null,
		"warrior UnitDef loaded from ContentDB (units)")
	if warrior_def == null:
		return
	var original_player_ids: Array[StringName] = \
		Array(warrior_def.reaction_ids) as Array[StringName]
	# We'll snapshot enemy defs lazily (after build inspects
	# which definition was actually picked).
	var picked_enemy_def = null
	var original_enemy_ids: Array[StringName] = []
	# Set the warrior def to a known reaction_ids before build.
	warrior_def.reaction_ids = ([&"reaction_a", &"reaction_b"]
		as Array[StringName])
	# Construct minimal RunDomainState with one board warrior.
	var state: RefCounted = RunDomainStateScript.new()
	state.seed = 42
	state.round_index = 1
	state.meta_modifiers = {
		"rest_attack_bonus": 0, "shrine_attack_bonus": 0,
	}
	var warrior_unit = state.create_unit(&"warrior", 100,
		RunUnitScript.LOCATION_BOARD)
	_assert(warrior_unit != null,
		"created warrior RunUnit on the board")
	if warrior_unit == null:
		# Restore before return.
		warrior_def.reaction_ids = original_player_ids
		return
	# Call the real BattleSetupBuilder.build().
	var setup = BattleSetupBuilderScript.build(state, 42, 1, 7, 4)
	_assert(setup != null,
		"BattleSetupBuilder.build() returned a BattleSetup")
	if setup == null:
		warrior_def.reaction_ids = original_player_ids
		return
	_assert(setup.player_units.size() >= 1,
		"setup has at least 1 player unit")
	_assert(setup.enemy_units.size() >= 1,
		"setup has at least 1 enemy unit")
	if setup.player_units.is_empty() or setup.enemy_units.is_empty():
		warrior_def.reaction_ids = original_player_ids
		return
	# Player snapshot: real builder path produced a row whose
	# reaction_ids mirror the warrior def AT BUILD TIME.
	var player_row = setup.player_units[0]
	_assert(String(player_row.definition_id) == "warrior",
		"player row built from warrior definition_id")
	_assert(_arr_eq(Array(player_row.reaction_ids) as Array,
			[&"reaction_a", &"reaction_b"]),
		"player row reaction_ids mirror warrior def at build time")
	_assert(player_row.source_run_unit_id == warrior_unit.instance_id,
		"player row preserves stable source_run_unit_id from RunUnit")
	# Enemy snapshot: inspect which enemy definition was
	# picked and snapshot its original reaction_ids.
	var enemy_row = setup.enemy_units[0]
	var picked_id: StringName = StringName(enemy_row.definition_id)
	picked_enemy_def = ContentDBScript.get_by_id_for_type(
		"enemies", picked_id)
	if picked_enemy_def != null:
		original_enemy_ids = Array(picked_enemy_def.reaction_ids) \
			as Array[StringName]
		# Now set enemy def to a known reaction_ids and rebuild.
		picked_enemy_def.reaction_ids = ([&"enemy_reaction_a"]
			as Array[StringName])
		setup = BattleSetupBuilderScript.build(state, 42, 1, 7, 4)
		_assert(setup.enemy_units.size() >= 1,
			"rebuild produced at least 1 enemy unit")
		if not setup.enemy_units.is_empty():
			var enemy_row2 = setup.enemy_units[0]
			_assert(String(enemy_row2.definition_id) == String(picked_id),
				"rebuild picks the same enemy definition_id "
				+ "(deterministic seed)")
			_assert(_arr_eq(Array(enemy_row2.reaction_ids) as Array,
					[&"enemy_reaction_a"]),
				"enemy row reaction_ids mirror picked enemy def "
				+ "at build time")
	# MUTATE warrior_def AFTER build. The already-built
	# BattleSetup MUST NOT change.
	var warrior_new_ids: Array[StringName] = (
		[&"completely_different_after_build"] as Array[StringName])
	warrior_def.reaction_ids = warrior_new_ids
	# Re-read the player row from the EXISTING setup object.
	var player_reactions_after_mutation: Array = \
		Array(player_row.reaction_ids)
	_assert(_arr_eq(player_reactions_after_mutation,
			[&"reaction_a", &"reaction_b"]),
		"player row unaffected by post-build warrior_def mutation "
		+ "(got %s)" % str(player_reactions_after_mutation))
	# Re-build to compare: the NEW setup's player row reflects
	# the POST-mutation def. The OLD setup's player row does NOT.
	var new_setup = BattleSetupBuilderScript.build(state, 42, 1, 7, 4)
	if new_setup != null and not new_setup.player_units.is_empty():
		_assert(_arr_eq(
				Array(new_setup.player_units[0].reaction_ids) as Array,
				[&"completely_different_after_build"]),
			"new build reflects post-mutation warrior_def "
			+ "(proves builder reads CURRENT def, not snapshot)")
	# Also mutate picked enemy def AFTER build (if any).
	if picked_enemy_def != null:
		picked_enemy_def.reaction_ids = (
			[&"enemy_changed"] as Array[StringName])
		if not setup.enemy_units.is_empty():
			var enemy_after: Array = \
				Array(setup.enemy_units[0].reaction_ids)
			_assert(_arr_eq(enemy_after, [&"enemy_reaction_a"]),
				"old enemy row unaffected by post-build enemy_def mutation")
	# RESTORE all mutated content (success path).
	warrior_def.reaction_ids = original_player_ids
	if picked_enemy_def != null:
		picked_enemy_def.reaction_ids = original_enemy_ids
	_assert(_arr_eq(Array(warrior_def.reaction_ids) as Array,
			Array(original_player_ids) as Array),
		"warrior_def.reaction_ids restored to original")


# ============================================================
# 8) BattleWorld spawn copies reaction_ids into per-entity
#    storage. Mutating the BattleSetup after spawn must NOT
#    alter world ownership.
# ============================================================
func _test_battle_world_spawn_snapshot_isolated() -> void:
	print("[B62A-BW] world_spawn_snapshot_isolated")
	var p_row = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1,
		[&"counterattack", &"taunt"])
	var e_row = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1, [&"howl"])
	var setup = BattleSetupScript.new(42, [p_row], [e_row], 7, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(setup)
	# Snapshot world ownership BEFORE mutation.
	var world_player_before: Array = Array(w.reaction_ids_of(0))
	var world_enemy_before: Array = Array(w.reaction_ids_of(1))
	_assert(_arr_eq(world_player_before, [&"counterattack", &"taunt"]),
		"world player entity owns [counterattack, taunt]")
	_assert(_arr_eq(world_enemy_before, [&"howl"]),
		"world enemy entity owns [howl]")
	# Mutate the BattleSetup row arrays AFTER spawn.
	setup.player_units[0].reaction_ids.append(&"new_reaction")
	setup.enemy_units[0].reaction_ids.append(&"new_enemy_reaction")
	# World ownership MUST NOT change.
	var world_player_after: Array = Array(w.reaction_ids_of(0))
	var world_enemy_after: Array = Array(w.reaction_ids_of(1))
	_assert(_arr_eq(world_player_after, world_player_before),
		"world player entity unaffected by BattleSetup mutation")
	_assert(_arr_eq(world_enemy_after, world_enemy_before),
		"world enemy entity unaffected by BattleSetup mutation")


# ============================================================
# 9) reaction_ids_of() returns a defensive copy.
# ============================================================
func _test_reaction_ids_of_returns_defensive_copy() -> void:
	print("[B62A-BW] reaction_ids_of_returns_defensive_copy")
	var p_row = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1,
		[&"counterattack"])
	var e_row = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1, [])
	var setup = BattleSetupScript.new(42, [p_row], [e_row], 7, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(setup)
	var returned: Array = w.reaction_ids_of(0)
	returned.append(&"evil")
	var after: Array = w.reaction_ids_of(0)
	_assert(after.size() == 1,
		"caller mutation of returned array did NOT mutate world "
		+ "(got size %d)" % after.size())
	_assert(String(after[0]) == "counterattack",
		"world canonical reaction_ids preserved")


# ============================================================
# 10) reaction_ids_of() for unknown entity returns [].
# ============================================================
func _test_unknown_entity_returns_empty_array() -> void:
	print("[B62A-BW] unknown_entity_returns_empty_array")
	var p_row = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1, [])
	var e_row = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1, [])
	var setup = BattleSetupScript.new(42, [p_row], [e_row], 7, 4)
	var w = BattleWorldScript.new(7, 4)
	w.spawn_from_setup(setup)
	var r: Array = w.reaction_ids_of(99999)
	_assert(r.size() == 0,
		"unknown entity_id returns empty array (got size %d)" % r.size())


# ============================================================
# 11) Two distinct entities with the same reaction ID:
#     VALID (each instance can own the same static reaction).
# ============================================================
func _test_duplicate_units_can_share_reaction_id_across_entities() -> void:
	print("[B62A-VAL] duplicate_units_can_share_reaction_id")
	var p1 = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1,
		[&"counterattack"])
	var p2 = BattleUnitSetupScript.new(
		"p1", &"warrior", 0, Vector2i(0, 1), 100, 100, 50, 5, 1,
		[&"counterattack"])
	var e_row = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 2), 100, 100, 20, 5, 1, [])
	var setup = BattleSetupScript.new(42, [p1, p2], [e_row], 7, 4)
	var msg: String = setup.validate()
	_assert(msg == "",
		"two distinct entities both owning counterattack is VALID "
		+ "(got '%s')" % msg)


# ============================================================
# 12) No gameplay trace change: BattleSimulation with no
#     provider installed produces the same baseline events.
# ============================================================
func _test_no_gameplay_trace_change_no_provider() -> void:
	print("[B62A-NOP] no_gameplay_trace_change_no_provider")
	# Build a battle with reaction_ids attached to player (would-be
	# future reaction). Without a provider installed, those IDs
	# are inert. The trace must be identical to a battle without
	# any reaction_ids.
	var p_with = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1,
		[&"counterattack"])
	var p_without = BattleUnitSetupScript.new(
		"p0", &"warrior", 0, Vector2i(0, 0), 100, 100, 50, 5, 1, [])
	var e_row_a = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1, [])
	var e_row_b = BattleUnitSetupScript.new(
		"e0", &"orc", 1, Vector2i(0, 1), 100, 100, 20, 5, 1, [])
	var setup_with = BattleSetupScript.new(42, [p_with], [e_row_a], 7, 4)
	var setup_without = BattleSetupScript.new(42, [p_without], [e_row_b], 7, 4)
	var sim1 = BattleSimulationScript.new()
	sim1.initialize(setup_with)
	var sim2 = BattleSimulationScript.new()
	sim2.initialize(setup_without)
	sim1.set_max_ticks(5)
	sim2.set_max_ticks(5)
	var events_a: Array = []
	var events_b: Array = []
	while not sim1.is_finished():
		events_a.append_array(sim1.step_tick())
	while not sim2.is_finished():
		events_b.append_array(sim2.step_tick())
	_assert(events_a.size() == events_b.size(),
		"trace length identical with / without reaction_ids "
		+ "(got %d vs %d)" % [events_a.size(), events_b.size()])
	# Compare 9 stable fields per event (excluding event_id).
	var n: int = mini(events_a.size(), events_b.size())
	for i in n:
		for k in [
			"type", "source_entity", "target_entity",
			"amount", "root_action_id", "parent_event_id",
			"chain_depth", "tag",
		]:
			var va = events_a[i].get(k)
			var vb = events_b[i].get(k)
			if str(va) != str(vb):
				_assert(false,
					"event[%d].%s differs with/without reaction_ids "
					+ "(%s vs %s)" % [i, k, str(va), str(vb)])
				return
	_assert(true,
		"all event fields identical with / without reaction_ids")
