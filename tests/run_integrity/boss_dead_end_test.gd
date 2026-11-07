extends SceneTree

## H-07: a service dead end must NOT produce a false victory.
##
## `_apply_service_effect()` ends the run with `_end_run(true)` when
## `encounter_map.get_available_next_ids()` is empty. An empty list of
## next moves does NOT mean the boss was defeated: a malformed graph
## whose service node has no children reaches the same branch.
##
## The production invariant:
##
##   available_next_ids.is_empty() DOES NOT IMPLY boss defeated
##
## The scenario drives the REAL `_on_node_selected()` on a malformed
## graph: a reachable service node whose children were removed, so no
## path to the boss exists. The service is processed, and then:
##
##   no false GAMEOVER
##   no meta unlock
##   no total_wins increment
##   no duplicate progression
##   no deleted checkpoint caused by a false victory
##
## The corrupted map is a CONTROLLED FAILURE, not a game loss and not
## a victory.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const BattleEntryFixturesScript = preload("res://tests/run_integrity/battle_entry_fixtures.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const EncounterMapScript = preload("res://core/encounter/encounter_map.gd")
const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")

const ISOLATED_DIR: String = "user://run_integrity_h07/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_a_service_dead_end_is_not_a_victory()
	await _test_B_a_service_dead_end_does_not_unlock_or_count()
	await _test_C_the_corrected_map_still_reaches_the_boss()
	await _test_D_a_boss_victory_still_ends_the_run()
	print("")
	print("=== STAGE H07: A SERVICE DEAD END IS NOT A VICTORY: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. The malformed map: the service is processed and the run is NOT
## ended as a victory.
func _test_A_a_service_dead_end_is_not_a_victory() -> void:
	var ctrl: Node = await _make_controller(670301)
	ctrl._enter_map()
	await process_frame
	var map: Object = ctrl.encounter_map
	_assert(map != null, "the map exists")

	# The malformed graph: a reachable SERVICE node whose children are
	# removed, so there is no path to the boss.
	var service_id: int = _make_service_dead_end(map)
	_assert(service_id >= 0, "the malformed service node was created")
	_assert(not _reaches_boss(map, service_id, _boss_id(map)),
		"the malformed service node has no path to the boss")

	var phase_before: int = int(ctrl.phase)
	var wins_before: int = ctrl.state.wins
	var ended: Array = []
	ctrl.run_ended.connect(func(won: bool) -> void: ended.append(won))

	# The REAL path: the node is selected through the production
	# handler.
	ctrl._on_node_selected(service_id)
	await process_frame

	_assert(int(ctrl.phase) != 3,
		"the run was NOT ended as GAMEOVER (the phase is %d, it was %d)"
			% [int(ctrl.phase), phase_before])
	_assert(ended.is_empty(),
		"no run_ended was emitted (the emitted list is %s)" % str(ended))
	_assert(ctrl.state.wins == wins_before,
		"the wins did not change")


## B. The false victory must not unlock anything, count a win or delete
## the checkpoint.
func _test_B_a_service_dead_end_does_not_unlock_or_count() -> void:
	var ctrl: Node = await _make_controller(670302)
	ctrl._enter_map()
	await process_frame
	var map: Object = ctrl.encounter_map
	var service_id: int = _make_service_dead_end(map)
	_assert(service_id >= 0, "the malformed service node was created")

	var total_runs_before: int = ctrl.profile.total_runs
	var total_wins_before: int = ctrl.profile.total_wins
	var unlocked_before: int = ctrl.profile.unlocked_units.size()
	var wins_before: int = ctrl.state.wins
	ctrl.save_now()
	await process_frame

	ctrl._on_node_selected(service_id)
	await process_frame

	_assert(ctrl.profile.total_runs == total_runs_before,
		"the total runs did not change")
	_assert(ctrl.profile.total_wins == total_wins_before,
		"the total wins did not change")
	_assert(ctrl.profile.unlocked_units.size() == unlocked_before,
		"nothing was unlocked")
	_assert(ctrl.state.wins == wins_before, "the run wins did not change")
	# The checkpoint of the run was NOT deleted by a false victory.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(670302)
	_assert(loaded != null and loaded.is_ok(),
		"the checkpoint was not deleted by the false victory")


## C. The correctly generated map still reaches the boss: the fix must
## not break the normal flow.
func _test_C_the_corrected_map_still_reaches_the_boss() -> void:
	var ctrl: Node = await _make_controller(670303)
	ctrl._enter_map()
	await process_frame
	var map: Object = ctrl.encounter_map
	var boss_id: int = _boss_id(map)
	_assert(boss_id >= 0, "the map has a boss")
	var orphans: int = 0
	for node_id in _reachable_nodes(map):
		if not _reaches_boss(map, int(node_id), boss_id):
			orphans += 1
	_assert(orphans == 0,
		"every reachable node of a correct map reaches the boss")


## D. The boss victory still ends the run: the fix must not remove the
## real terminator.
func _test_D_a_boss_victory_still_ends_the_run() -> void:
	var ctrl: Node = await _make_controller(670304)
	ctrl._enter_map()
	await process_frame
	var map: Object = ctrl.encounter_map
	var boss_id: int = _boss_id(map)
	_assert(boss_id >= 0, "the map has a boss")
	# The boss is the current encounter, and the battle is won.
	# RUN-ENTRY-01: the battle entry is guarded, so the run walks the
	# map to the boss -- the production path leaves the run in PREP
	# with the boss current, which is the battle context.
	var selected: int = BattleEntryFixturesScript.select_the_boss(ctrl)
	_assert(selected == boss_id, "the boss is the current encounter")
	var ended: Array = []
	ctrl.run_ended.connect(func(won: bool) -> void: ended.append(won))
	ctrl.start_battle()
	await process_frame
	# The runner is simulated: the outcome is a win for the player.
	if ctrl.runner != null:
		ctrl.runner.state.winner_team = 0
		ctrl.runner.state.phase = 6
		ctrl._on_battle_ended()
	await process_frame
	_assert(ended.size() == 1 and bool(ended[0]),
		"the boss victory ends the run once as a win (the emitted list is %s)"
			% str(ended))
	_assert(int(ctrl.phase) == 3, "the phase is GAMEOVER")


# ----------------------------------------------------------------


## Builds a malformed graph: a selectable SERVICE node with no
## successors, so there is no path to the boss from it.
##
## The corruption takes a CHILD of the current node -- a node the
## player can actually select -- turns it into a service node, and
## removes ITS successors. The link FROM the parent is kept: the node
## must stay selectable, otherwise the scenario never runs and the test
## proves nothing.
func _make_service_dead_end(map: Object) -> int:
	var current_id: int = int(map.get_current_node_id())
	if current_id < 0:
		return -1
	var current: Object = map.get_node(current_id)
	if current == null:
		return -1
	var service_id: int = -1
	for child_id in current.child_ids:
		var child: Object = map.get_node(int(child_id))
		if child == null:
			continue
		if int(child.type) != int(EncounterTypeScript.Kind.BOSS):
			service_id = int(child_id)
			break
	if service_id < 0:
		return -1
	var service: Object = map.get_node(service_id)
	# The CORRUPTION: the node becomes a SERVICE node and it has no
	# successors, so no path to the boss exists from it.
	service.type = int(EncounterTypeScript.Kind.REST)
	var no_children: Array[int] = []
	service.child_ids = no_children
	return service_id


func _boss_id(map: Object) -> int:
	for node in map.get_all_nodes():
		if int(node.type) == int(EncounterTypeScript.Kind.BOSS):
			return int(node.id)
	return -1


func _reachable_nodes(map: Object) -> Array:
	var visited: Dictionary = {}
	var stack: Array = []
	var start: int = int(map.get_current_node_id())
	if start < 0:
		return []
	stack.append(start)
	while not stack.is_empty():
		var node_id: int = int(stack.pop_back())
		if visited.has(node_id):
			continue
		visited[node_id] = true
		var node: Object = map.get_node(node_id)
		if node == null:
			continue
		for child_id in node.child_ids:
			stack.append(int(child_id))
	var out: Array = []
	for key in visited.keys():
		out.append(key)
	return out


func _reaches_boss(map: Object, from_id: int, boss_id: int) -> bool:
	if from_id == boss_id:
		return true
	var visited: Dictionary = {}
	var stack: Array = [from_id]
	while not stack.is_empty():
		var node_id: int = int(stack.pop_back())
		if visited.has(node_id):
			continue
		visited[node_id] = true
		var node: Object = map.get_node(node_id)
		if node == null:
			continue
		for child_id in node.child_ids:
			if int(child_id) == boss_id:
				return true
			stack.append(int(child_id))
	return false


func _has_no_boss_path(map: Object) -> bool:
	var boss_id: int = _boss_id(map)
	if boss_id < 0:
		return true
	for node_id in _reachable_nodes(map):
		if _reaches_boss(map, int(node_id), boss_id):
			return false
	return true


func _make_controller(seed_value: int) -> Node:
	var ctrl: Node = RunControllerScript.new()
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR)
	ctrl.meta_writer = _MetaWriter.new()
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]
	ctrl.start_run(seed_value)
	await process_frame
	return ctrl


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
		print("  [FAIL] Stage H07: %s" % label)
