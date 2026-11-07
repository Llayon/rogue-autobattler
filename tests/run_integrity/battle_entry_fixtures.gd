class_name BattleEntryFixtures
extends RefCounted

## The shared fixtures of the battle-entry tests.
##
## RUN-ENTRY-01 made the battle entry a GUARDED operation: a battle may
## start only from a real battle context. Several pre-existing tests
## used `_enter_map()` (the MAP phase) and then called `start_battle()`
## directly, which the guard refuses -- and rightly so: a MAP phase
## means "the player must select a node".
##
## Those tests were not testing the map. They needed a STARTED BATTLE,
## and they reached for the map because that was the shortest way to
## get one. The production flow offers two legal ways, and this helper
## uses them:
##
##   - the INITIAL PREPARATION: `start_run()` leaves the run in PREP
##     with the starter units on the board, and the first battle starts
##     from there;
##   - a SELECTED COMBAT: the player walks the map and selects a
##     combat node, and the selection moves the run to PREP with that
##     node current.
##
## The walk uses the PRODUCTION path (`_on_node_selected`), so the
## phase, the state and the checkpoint are the real ones.

const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")


## Starts the first battle of the run: the initial preparation.
##
## The run is in PREP with the starter units on the board, which is the
## legal battle context of the very first battle.
static func start_the_first_battle(ctrl: Node) -> bool:
	return ctrl.start_battle()


## Walks the map to a COMBAT node and selects it, the way the player
## does. Returns the selected node id, or -1 when the graph has no
## reachable combat node.
static func select_a_combat(ctrl: Node) -> int:
	var map: Object = ctrl.get_encounter_map()
	if map == null:
		return -1
	for node_id in map.get_available_next_ids():
		var node: Object = map.get_node(int(node_id))
		if node == null:
			continue
		if not node.is_combat():
			continue
		ctrl._on_node_selected(int(node_id))
		return int(node_id)
	return -1


## Walks the map to the BOSS node and selects it.
##
## The boss is the terminal combat of the map, so the walk follows the
## graph from the current node to the boss. Returns the boss id, or -1
## when the boss is not reachable.
static func select_the_boss(ctrl: Node) -> int:
	var map: Object = ctrl.get_encounter_map()
	if map == null:
		return -1
	var boss_id: int = -1
	for node in map.get_all_nodes():
		if int(node.type) == EncounterTypeScript.Kind.BOSS:
			boss_id = int(node.id)
			break
	if boss_id < 0:
		return -1
	# The walk uses the MAP's own transition, `choose_next()`, which is
	# what the map UI calls. `_on_node_selected()` cannot be used for
	# the intermediate steps: it only works in the MAP phase, and
	# selecting a COMBAT node moves the run to PREP, so the next step
	# would be rejected.
	var path: Array = _path_to(map, int(ctrl.state.current_encounter_id), boss_id)
	if path.is_empty():
		return -1
	for node_id in path:
		map.choose_next(int(node_id))
	# The boss is a COMBAT node, so the run is in the PREP phase with
	# the boss current -- the state the production selection produces.
	ctrl.state.current_encounter_id = boss_id
	ctrl.state.encounter_visited_ids.append(boss_id)
	ctrl._set_phase(ctrl.Phase.PREP)
	return boss_id


## The node ids on a path from `from_id` to `to_id`, following the
## child edges of the graph.
static func _path_to(map: Object, from_id: int, to_id: int) -> Array:
	if from_id == to_id:
		return [to_id]
	var queue: Array = [[from_id]]
	var seen: Dictionary = {from_id: true}
	while not queue.is_empty():
		var path: Array = queue.pop_front()
		var current: int = int(path[path.size() - 1])
		var node: Object = map.get_node(current)
		if node == null:
			continue
		for child_id in node.child_ids:
			var child: int = int(child_id)
			if seen.has(child):
				continue
			seen[child] = true
			var next_path: Array = path.duplicate()
			next_path.append(child)
			if child == to_id:
				return next_path
			queue.append(next_path)
	return []
