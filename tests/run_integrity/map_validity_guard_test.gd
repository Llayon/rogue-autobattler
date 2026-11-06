extends SceneTree

## R-05 (independent critic, MAJOR): the H-07 guard uses
## `EncounterMap.is_valid()`, which is a WHOLE-GRAPH validator. A
## generated map can contain a childless non-boss node, and then
## `is_valid()` is false for the WHOLE map -- so the service dead-end
## branch returns early and the run NEITHER wins nor loses: a soft
## lock, not a controlled failure.
##
## The probe: generate many maps and check whether `is_valid()` is
## true for each of them. If a LEGITIMATE map is invalid, the H-07
## fix turns a normal run into a stall.
##
## The second part: a legitimate map that reaches the boss must still
## END THE RUN as a victory.

const EncounterMapScript = preload("res://core/encounter/encounter_map.gd")
const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_A_the_generated_maps_are_valid()
	await _test_B_a_childless_non_boss_node_makes_the_map_invalid()
	print("")
	print("=== STAGE R05: THE MAP VALIDITY GUARD: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. The generated maps must be valid: the H-07 guard must not turn
## a legitimate run into a stall.
func _test_A_the_generated_maps_are_valid() -> void:
	var invalid: int = 0
	var checked: int = 0
	for s in range(200):
		var map: Object = EncounterMapScript.new()
		map.generate(672000 + s)
		checked += 1
		if not map.is_valid():
			invalid += 1
			if invalid <= 3:
				print("  the seed %d produced an INVALID map" % (672000 + s))
	_assert(checked == 200, "two hundred maps were checked")
	_assert(invalid == 0,
		"every generated map is valid (%d of %d were invalid)"
			% [invalid, checked])


## B. The validation is REACHABLE: a childless non-boss node makes the
## map invalid, so the guard does detect the corruption.
func _test_B_a_childless_non_boss_node_makes_the_map_invalid() -> void:
	var map: Object = EncounterMapScript.new()
	map.generate(672999)
	map.start_run()
	_assert(map.get_current_node() != null, "the map was started")
	_assert(map.is_valid(), "the generated map starts valid")
	# The corruption: a non-boss node with no successors.
	var corrupted: bool = false
	for node in map.get_all_nodes():
		if int(node.type) != int(EncounterTypeScript.Kind.BOSS) \
				and int(node.depth) < 10 and node.child_ids.is_empty():
			corrupted = true
			break
	if not corrupted:
		# The generator did not produce a childless node in this map:
		# the corruption is applied explicitly.
		var current: Object = map.get_current_node()
		if current != null and current.child_ids.size() > 0:
			var child: Object = map.get_node(int(current.child_ids[0]))
			if child != null and int(child.type) != int(EncounterTypeScript.Kind.BOSS):
				var no_children: Array[int] = []
				child.child_ids = no_children
				corrupted = true
	_assert(corrupted, "the corruption was applied")
	_assert(not map.is_valid(),
		"the corrupted map is invalid, so the guard detects it")


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage R05: %s" % label)
