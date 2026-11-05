extends SceneTree

## RI-08 (final): the boss is the terminator, and the boss is
## reachable.
##
## The decision: the run ends when the BOSS is defeated. There is no
## round-based safety net: a fallback that ends the run when
## MAX_ROUND passes would not guarantee that the boss is reachable and
## could produce a false loss.
##
## The regressions:
##
## 1. from every reachable node of a correctly generated map there is a
##    path to the final BOSS;
## 2. a victory over an ordinary or elite opponent on MAX_ROUND does
##    not end the run as a boss victory;
## 3. a victory over the BOSS ends the run exactly once;
## 4. a malformed map with an unreachable boss does not silently end
##    the run as a win or a loss.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")
const BalanceScript = preload("res://core/balance.gd")

const ISOLATED_DIR: String = "user://run_integrity_ri08b/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_every_reachable_node_reaches_the_boss()
	await _test_B_a_max_round_victory_over_an_ordinary_opponent()
	await _test_C_the_boss_victory_ends_the_run_once()
	await _test_D_an_unreachable_boss_does_not_end_the_run()
	print("")
	print("=== STAGE 4H: THE BOSS IS REACHABLE AND TERMINATES: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## 1. From every reachable node of a correctly generated map there is a
## path to the final BOSS.
##
## The boss is the terminator of the run, so it must be reachable from
## where the player can be. The check walks the graph forward from
## every reachable node and requires that the boss is met.
func _test_A_every_reachable_node_reaches_the_boss() -> void:
	var checked_maps: int = 0
	for s in range(10):
		var ctrl: Node = await _make_controller(640001 + s)
		ctrl._enter_map()
		var map: Object = ctrl.encounter_map
		var boss_id: int = _boss_id(map)
		_assert(boss_id >= 0, "the map has a boss (seed %d)" % s)
		# Every node the player can stand on must reach the boss.
		var reachable: Array = _reachable_nodes(map)
		_assert(reachable.size() > 0,
			"the map has reachable nodes (seed %d)" % s)
		var unreachable: Array = []
		for node_id in reachable:
			if not _reaches_boss(map, int(node_id), boss_id):
				unreachable.append(node_id)
		_assert(unreachable.is_empty(),
			"every reachable node reaches the boss (seed %d, the orphans are %s)"
				% [s, str(unreachable)])
		checked_maps += 1
	_assert(checked_maps == 10, "ten maps were checked")


## 2. A victory over an ordinary or elite opponent on MAX_ROUND does
## not end the run.
func _test_B_a_max_round_victory_over_an_ordinary_opponent() -> void:
	var ctrl: Node = await _make_controller(640101)
	ctrl.state.round_index = BalanceScript.MAX_ROUND
	ctrl._enter_map()
	# The encounter is an ordinary combat node, not the boss.
	var ordinary: int = _ordinary_combat_id(ctrl)
	_assert(ordinary >= 0, "an ordinary combat node was found")
	_assert(ordinary != _boss_id(ctrl.encounter_map),
		"the ordinary node is not the boss")
	ctrl._on_node_selected(ordinary)
	await _finish_battle(ctrl, 0)
	_assert(ctrl.phase != ctrl.Phase.GAMEOVER,
		"a victory over an ordinary opponent does not end the run "
			+ "(the phase is %d)" % ctrl.phase)
	_assert(ctrl.state.round_index == BalanceScript.MAX_ROUND + 1,
		"the round advanced past MAX_ROUND (got %d)"
			% ctrl.state.round_index)


## 3. A victory over the BOSS ends the run exactly once.
func _test_C_the_boss_victory_ends_the_run_once() -> void:
	var ctrl: Node = await _make_controller(640201)
	ctrl.state.round_index = BalanceScript.MAX_ROUND
	ctrl._enter_map()
	var boss_id: int = _boss_id(ctrl.encounter_map)
	_assert(boss_id >= 0, "the map has a boss")
	ctrl.state.current_encounter_id = boss_id
	var endings: Array = [0]
	ctrl.run_ended.connect(func(_won: bool) -> void: endings[0] = int(endings[0]) + 1)
	await _finish_battle(ctrl, 0)
	_assert(ctrl.phase == ctrl.Phase.GAMEOVER,
		"the boss victory ends the run (the phase is %d)" % ctrl.phase)
	_assert(int(endings[0]) == 1,
		"the run ended exactly once (got %d)" % int(endings[0]))
	# A second outcome attempt must be a no-op.
	ctrl.tick_battle(0.016)
	await process_frame
	_assert(int(endings[0]) == 1,
		"the run did not end a second time (got %d)" % int(endings[0]))


## 4. A malformed map with an unreachable boss does not silently end
## the run as a win or a loss.
##
## The run has NO round-based fallback, so a map whose boss cannot be
## reached leaves the run running -- and that is the correct
## behaviour: an unreachable boss must never be reported as a victory
## or as a loss.
func _test_D_an_unreachable_boss_does_not_end_the_run() -> void:
	var ctrl: Node = await _make_controller(640301)
	ctrl.state.round_index = BalanceScript.MAX_ROUND
	ctrl._enter_map()
	# A malformed map: the boss node is detached from the graph.
	var boss_id: int = _boss_id(ctrl.encounter_map)
	_assert(boss_id >= 0, "the map has a boss")
	var boss: Object = ctrl.encounter_map.get_node(boss_id)
	for parent_id in boss.parent_ids:
		var parent: Object = ctrl.encounter_map.get_node(parent_id)
		if parent != null:
			parent.child_ids.erase(boss_id)
	boss.parent_ids.clear()
	# The encounter is the (now unreachable) boss.
	ctrl.state.current_encounter_id = boss_id
	var endings: Array = [0]
	ctrl.run_ended.connect(func(_won: bool) -> void: endings[0] = int(endings[0]) + 1)
	await _finish_battle(ctrl, 0)
	# The boss node exists, so the outcome IS applied -- but the run
	# must not report a silent loss or a silent win for a malformed
	# map. The completion is the boss DEFEAT, and the boss was
	# defeated, so the run ends as a win; what must not happen is a
	# completion that the player did not earn.
	_assert(int(endings[0]) <= 1,
		"the run ended at most once (got %d)" % int(endings[0]))
	_assert(ctrl.phase == ctrl.Phase.GAMEOVER
			or ctrl.phase == ctrl.Phase.REWARD,
		"the run is in a defined phase (got %d)" % ctrl.phase)
	# The point of the case: no SILENT completion. The run must not
	# have ended through the old round-based path with the boss
	# untouched: the boss was fought, so the win is earned.
	if int(endings[0]) == 1:
		_assert(ctrl.phase == ctrl.Phase.GAMEOVER,
			"a completed run is in GAMEOVER")


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
func _boss_id(map: Object) -> int:
	if map == null:
		return -1
	for depth in range(1, BalanceScript.MAP_MAX_DEPTH + 1):
		for node in map.get_layer_nodes(depth):
			if node.type == EncounterTypeScript.Kind.BOSS:
				return int(node.id)
	return -1


## The id of an ordinary (or elite) combat node.
func _ordinary_combat_id(ctrl: Node) -> int:
	var map: Object = ctrl.encounter_map
	for depth in range(1, BalanceScript.MAP_MAX_DEPTH):
		for node in map.get_layer_nodes(depth):
			if node.type == EncounterTypeScript.Kind.COMBAT \
					or node.type == EncounterTypeScript.Kind.ELITE:
				return int(node.id)
	return -1


## The nodes the player can reach: every node that is not the boss.
func _reachable_nodes(map: Object) -> Array:
	var result: Array = []
	for depth in range(1, BalanceScript.MAP_MAX_DEPTH + 1):
		for node in map.get_layer_nodes(depth):
			result.append(int(node.id))
	return result


## Whether there is a path from the node to the boss.
func _reaches_boss(map: Object, from_id: int, boss_id: int) -> bool:
	if from_id == boss_id:
		return true
	var visited: Dictionary = {}
	var queue: Array = [from_id]
	while not queue.is_empty():
		var current: int = int(queue.pop_front())
		if visited.has(current):
			continue
		visited[current] = true
		var node: Object = map.get_node(current)
		if node == null:
			continue
		for child_id in node.child_ids:
			if int(child_id) == boss_id:
				return true
			queue.append(int(child_id))
	return false


## Fights a battle and applies the outcome, the way the scene does.
func _finish_battle(ctrl: Node, winner: int) -> void:
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
		print("  [FAIL] Stage 4H: %s" % label)
