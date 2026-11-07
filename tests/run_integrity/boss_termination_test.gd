extends SceneTree

## RI-08: the run must terminate on the BOSS, not only on the round
## count.
##
## The finding: the run ends only when `state.round_index >
## BalanceScript.MAX_ROUND` (the number of WON BATTLES). The boss node
## does not drive the completion: the BOSS is a combat node on the map
## layer 10, it is fought like any other node, and the run happens to
## end when the round counter passes MAX_ROUND.
##
## The two counters are DIFFERENT:
## - `round_index` grows by one per WON BATTLE;
## - the map depth grows by one per SELECTED NODE.
##
## So the boss is not what ends the run: the count is. A run can
## reach the boss and lose, and the boss is not the last thing that
## happened. Or the count can run out before the boss is reached.
##
## The invariant: the run ends when the boss is defeated, and the
## boss defeat is what the completion depends on.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const BattleEntryFixturesScript = preload("res://tests/run_integrity/battle_entry_fixtures.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")
const BalanceScript = preload("res://core/balance.gd")

const ISOLATED_DIR: String = "user://run_integrity_ri08/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_the_map_has_a_boss()
	await _test_B_the_boss_defeat_ends_the_run()
	await _test_C_the_run_does_not_end_without_the_boss()
	await _test_D_the_counters_are_separate()
	print("")
	print("=== STAGE 4G: THE BOSS ENDS THE RUN: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## The map must have a boss, and it must be on the last layer.
func _test_A_the_map_has_a_boss() -> void:
	var ctrl: Node = await _make_controller(630001)
	ctrl._enter_map()
	var boss_ids: Array = []
	for depth in range(1, BalanceScript.MAP_MAX_DEPTH + 1):
		for node in ctrl.encounter_map.get_layer_nodes(depth):
			if node.type == EncounterTypeScript.Kind.BOSS:
				boss_ids.append(node.id)
	_assert(boss_ids.size() == 1,
		"the map has exactly one boss (got %d)" % boss_ids.size())
	_assert(boss_ids.size() > 0, "the boss exists")


## The boss defeat must end the run.
func _test_B_the_boss_defeat_ends_the_run() -> void:
	var ctrl: Node = await _make_controller(630002)
	# The run is on the last round, and the boss is the encounter.
	ctrl.state.round_index = BalanceScript.MAX_ROUND
	# RUN-ENTRY-01: the battle entry is guarded, so the boss is
	# REACHED through the map: the walk leaves the run in PREP with
	# the boss current, which is the battle context. The boss id was
	# written into the state by hand before, which is not a state the
	# game can produce.
	ctrl._enter_map()
	await process_frame
	var boss_id: int = _boss_node_id(ctrl)
	_assert(boss_id >= 0, "the boss node was found")
	_assert(BattleEntryFixturesScript.select_the_boss(ctrl) == boss_id,
		"the boss is the current encounter")
	# The boss is fought and won.
	await _finish_battle(ctrl, 0)
	_assert(ctrl.phase == ctrl.Phase.GAMEOVER,
		"the boss defeat ends the run (the phase is %d)" % ctrl.phase)
	_assert(ctrl.profile.current_run_seed == 0,
		"the run is not continuable after the boss")


## The run must NOT end by the round count alone.
##
## The completion depends on the number of WON BATTLES, and the map
## has 10 layers with 2..4 nodes each, so the count can run out on the
## EARLY layers: the run ended on round 11 with the boss never fought.
func _test_C_the_run_does_not_end_without_the_boss() -> void:
	var ctrl: Node = await _make_controller(630004)
	# The run is at the last round.
	ctrl.state.round_index = BalanceScript.MAX_ROUND
	ctrl._enter_map()
	var boss_id: int = _boss_node_id(ctrl)
	# The case fights an ORDINARY opponent, so the run must NOT walk
	# to the boss: the boss has no children, and the walk would empty
	# the available list.
	# The player starts ON a combat node of the first layer. The
	# available next ids are the nodes of the NEXT layer, so the walk
	# is: pick the next node, and the run fights it.
	var ids: Array = ctrl.encounter_map.get_available_next_ids()
	var combat_id: int = -1
	for nid in ids:
		var node: Object = ctrl.encounter_map.get_node(int(nid))
		if node != null and node.type == EncounterTypeScript.Kind.COMBAT:
			combat_id = int(nid)
			break
	if combat_id < 0:
		# No COMBAT node in the next layer for this seed.
		#
		# RUN-ENTRY-01: the battle entry is guarded, so a SERVICE node
		# is NOT a battle context: the fallback used to take the first
		# reachable node and fight it, and that node can be a service
		# node. The case needs a real COMBAT node, so the walk goes
		# deeper into the graph until it finds one.
		combat_id = await _walk_to_a_combat(ctrl)
	_assert(combat_id >= 0, "a combat node is reachable")
	if combat_id < 0:
		return
	_assert(boss_id != combat_id, "the combat node is not the boss")
	# The battle is won.
	await _finish_battle(ctrl, 0)
	_assert(ctrl.phase != ctrl.Phase.GAMEOVER,
		"winning a battle that is not the boss does not end the run "
			+ "(the phase is %d)" % ctrl.phase)


## The two counters are different: the round grows by a WON BATTLE, the
## depth by a SELECTED NODE. The completion must not depend on the
## round count alone.
func _test_D_the_counters_are_separate() -> void:
	var ctrl: Node = await _make_controller(630003)
	ctrl._enter_map()
	var round_at_map: int = ctrl.state.round_index
	var picked: int = 0
	for _step in 3:
		var ids: Array = ctrl.encounter_map.get_available_next_ids()
		if ids.is_empty():
			break
		var node: Object = ctrl.encounter_map.get_node(int(ids[0]))
		if node != null and node.type != EncounterTypeScript.Kind.COMBAT \
				and node.type != EncounterTypeScript.Kind.ELITE:
			# A service node: it does not fight, so the round does not
			# grow, but the depth does.
			ctrl._on_node_selected(int(ids[0]))
			picked += 1
			if ctrl.phase != ctrl.Phase.MAP:
				break
			continue
		ctrl._on_node_selected(int(ids[0]))
		picked += 1
		if ctrl.phase != ctrl.Phase.MAP:
			break
	_assert(picked > 0, "the map was walked")
	_assert(ctrl.state.round_index <= round_at_map,
		"the round did not grow by the depth (the round is %d, it was %d)"
			% [ctrl.state.round_index, round_at_map])


# ----------------------------------------------------------------


func _make_controller(seed_value: int) -> Node:
	var ctrl: Node = RunControllerScript.new()
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR)
	ctrl.meta_writer = _MetaWriter.new()
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer", &"cleric",
		&"mage", &"knight", &"druid"] as Array[StringName]
	ctrl.start_run(seed_value)
	await process_frame
	return ctrl


## The id of the boss node of the map.
func _boss_node_id(ctrl: Node) -> int:
	if ctrl.encounter_map == null:
		ctrl._enter_map()
	for depth in range(1, BalanceScript.MAP_MAX_DEPTH + 1):
		for node in ctrl.encounter_map.get_layer_nodes(depth):
			if node.type == EncounterTypeScript.Kind.BOSS:
				return int(node.id)
	return -1


## Walks the map to a reachable COMBAT node, the way the player does.
##
## The kind of a selectable node is drawn, so a seed can offer a
## SERVICE node where the case needs a combat one. The walk follows
## the graph until it finds a COMBAT node.
func _walk_to_a_combat(ctrl: Node) -> int:
	var map: Object = ctrl.encounter_map
	if map == null:
		return -1
	# The walk uses the MAP's own transition, `choose_next()`, which is
	# what the map UI calls. `_on_node_selected()` cannot be used for
	# the intermediate steps: it only works in the MAP phase, and
	# selecting a node moves the run out of it.
	var walked: Dictionary = {}
	for _step in range(12):
		var current: int = int(ctrl.state.current_encounter_id)
		if walked.has(current):
			break
		walked[current] = true
		for node_id in map.get_available_next_ids():
			var node: Object = map.get_node(int(node_id))
			if node == null:
				continue
			if not node.is_combat():
				continue
			map.choose_next(int(node_id))
			ctrl.state.current_encounter_id = int(node_id)
			ctrl.state.encounter_visited_ids.append(int(node_id))
			ctrl._set_phase(ctrl.Phase.PREP)
			return int(node_id)
		# No combat child: step one node deeper.
		var moved: bool = false
		for node_id in map.get_available_next_ids():
			map.choose_next(int(node_id))
			ctrl.state.current_encounter_id = int(node_id)
			ctrl.state.encounter_visited_ids.append(int(node_id))
			moved = true
			break
		if not moved:
			break
	return -1


## Fights a battle and applies the outcome, the way the scene does.
func _finish_battle(ctrl: Node, winner: int) -> void:
	# RUN-ENTRY-01: the battle entry is guarded, so the encounter must
	# already be a real battle context. The cases that fight the boss
	# reach it through `BattleEntryFixturesScript.select_the_boss()`,
	# which leaves the run in PREP with the boss current; the cases
	# that fight an ordinary opponent select their node themselves.
	ctrl.start_battle()
	await process_frame
	var losing_team: int = 1 if winner == 0 else 0
	for combatant in ctrl.runner.ctx.combatants_of_team(losing_team):
		combatant.health.current_hp = 0
	ctrl.runner._cleanup_dead()
	ctrl.runner._end_battle()
	ctrl.tick_battle(0.016)
	await process_frame


## A meta writer that does NOT touch the production meta file.
class _MetaWriter:
	extends RefCounted

	func write_meta(profile: Object) -> bool:
		return true


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage 4G: %s" % label)
