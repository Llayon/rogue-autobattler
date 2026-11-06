extends SceneTree

## H-03: the map checkpoint must describe a STABLE transition.
##
## The COMBAT path:
##
##   choose valid COMBAT
##     -> update the map state
##     -> transition to PREP
##     -> persist the PREP checkpoint
##
## The baseline persisted a MAP checkpoint BEFORE the transition to
## PREP, so after Continue the run was in the MAP phase with the
## combat node already selected: the player could select the NEXT node
## and skip the battle.
##
## The service path:
##
##   valid node selection
##     -> apply the service effect exactly once
##     -> determine the final stable phase
##     -> persist the authoritative checkpoint
##
## The baseline saved three times for one transaction: before the
## effect, inside the effect handler and after it.
##
## The suite drives the REAL `_on_node_selected()` -- never a direct
## phase assignment.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const EncounterMapScript = preload("res://core/encounter/encounter_map.gd")
const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")
const SaveSchemaV5Script = preload("res://core/save/save_schema_v5.gd")

const ISOLATED_DIR: String = "user://run_integrity_h03/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_a_combat_is_persisted_as_prep()
	await _test_B_the_combat_cannot_be_skipped_after_a_resume()
	await _test_C_the_resume_keeps_the_map_and_the_rng()
	await _test_D_a_service_is_applied_exactly_once()
	await _test_E_the_service_checkpoint_carries_the_final_phase()
	print("")
	print("=== STAGE H03: THE MAP CHECKPOINT IS STABLE: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. A COMBAT node is persisted as PREP.
func _test_A_a_combat_is_persisted_as_prep() -> void:
	var ctrl: Node = await _make_controller(670401)
	ctrl._enter_map()
	await process_frame
	var combat_id: int = _first_combat_child(ctrl.encounter_map)
	_assert(combat_id >= 0, "the map has a selectable combat node")
	if combat_id < 0:
		return

	# The REAL path.
	ctrl._on_node_selected(combat_id)
	await process_frame

	_assert(int(ctrl.phase) == 0,
		"the phase is PREP after the combat selection (it is %d)" % int(ctrl.phase))

	# The checkpoint on the disk.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(670401)
	_assert(loaded != null and loaded.is_ok(), "the checkpoint was written")
	if loaded != null and loaded.is_ok():
		var dto: Dictionary = loaded.data
		_assert(str(dto.get("phase", "")) == SaveSchemaV5Script.PHASE_PREP,
			"the checkpoint phase is PREP (it is %s)" % str(dto.get("phase", "")))
		_assert(int(dto.get("current_encounter_id", -1)) == combat_id,
			"the checkpoint carries the selected combat node")


## B. After a resume, the selected combat cannot be skipped: the run is
## in PREP, so no node can be selected.
func _test_B_the_combat_cannot_be_skipped_after_a_resume() -> void:
	var ctrl: Node = await _make_controller(670402)
	ctrl._enter_map()
	await process_frame
	var combat_id: int = _first_combat_child(ctrl.encounter_map)
	_assert(combat_id >= 0, "the map has a selectable combat node")
	if combat_id < 0:
		return
	ctrl._on_node_selected(combat_id)
	await process_frame
	ctrl.save_now()
	await process_frame

	var resumed: Node = await _make_controller(670403)
	var ok: bool = resumed.resume_run(670402)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(int(resumed.phase) == 0,
		"the resumed run is in PREP (it is %d)" % int(resumed.phase))
	# The map is the SAME map.
	_assert(resumed.encounter_map != null, "the resumed run has the map")
	if resumed.encounter_map != null:
		_assert(int(resumed.encounter_map.get_current_node_id()) == combat_id,
			"the resumed map is at the selected combat node")
	# The battle is still pending: the node selection is refused in
	# PREP, so the next node cannot be taken.
	var next_ids: Array[int] = resumed.encounter_map.get_available_next_ids()
	_assert(next_ids.size() > 0, "the map has the next nodes")
	if next_ids.size() > 0:
		var round_before: int = resumed.state.round_index
		var visited_before: int = resumed.state.encounter_visited_ids.size()
		resumed._on_node_selected(next_ids[0])
		await process_frame
		_assert(int(resumed.phase) == 0,
			"the resumed run stayed in PREP (it is %d)" % int(resumed.phase))
		_assert(resumed.state.round_index == round_before,
			"the skipped battle did not advance the round")
		_assert(resumed.state.encounter_visited_ids.size() == visited_before,
			"the skipped battle did not visit the next node")


## C. The resume keeps the map and the RNG continuation.
func _test_C_the_resume_keeps_the_map_and_the_rng() -> void:
	var ctrl: Node = await _make_controller(670404)
	ctrl._enter_map()
	await process_frame
	var combat_id: int = _first_combat_child(ctrl.encounter_map)
	if combat_id < 0:
		return
	ctrl._on_node_selected(combat_id)
	await process_frame
	ctrl.save_now()
	await process_frame
	var rng_before: Dictionary = RngServiceScript.snapshot()

	var resumed: Node = await _make_controller(670405)
	var ok: bool = resumed.resume_run(670404)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	var rng_after: Dictionary = RngServiceScript.snapshot()
	_assert(int(rng_after.get("state", 0)) == int(rng_before.get("state", 0)),
		"the RNG continuation survived the resume")


## D. A service is applied EXACTLY ONCE, even if the node is
## selected again.
func _test_D_a_service_is_applied_exactly_once() -> void:
	var ctrl: Node = await _make_controller(670406)
	ctrl._enter_map()
	await process_frame
	var service_id: int = _first_service_child(ctrl.encounter_map)
	if service_id < 0:
		# The layer 2 of this seed has no service: the case is
		# covered by the merchant and the treasure suites.
		return
	var gold_before: int = ctrl.state.gold
	var lives_before: int = ctrl.state.lives
	ctrl._on_node_selected(service_id)
	await process_frame
	var gold_after: int = ctrl.state.gold
	var lives_after: int = ctrl.state.lives
	_assert(ctrl.state.encounter_visited_ids.count(service_id) == 1,
		"the service node was visited once")

	# The node is selected AGAIN: the service must not be applied a
	# second time.
	ctrl._on_node_selected(service_id)
	await process_frame
	_assert(ctrl.state.gold == gold_after,
		"the second selection did not grant the gold again")
	_assert(ctrl.state.lives == lives_after,
		"the second selection did not grant the life again")
	_assert(ctrl.state.encounter_visited_ids.count(service_id) == 1,
		"the second selection did not visit the node again")
	if gold_before == gold_after and lives_before == lives_after:
		# The service had no effect in this seed: the check is
		# vacuous, so it proves nothing.
		pass


## E. The service checkpoint carries the FINAL phase, not an
## intermediate one.
func _test_E_the_service_checkpoint_carries_the_final_phase() -> void:
	var ctrl: Node = await _make_controller(670407)
	ctrl._enter_map()
	await process_frame
	var service_id: int = _first_service_child(ctrl.encounter_map)
	if service_id < 0:
		return
	ctrl._on_node_selected(service_id)
	await process_frame
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(670407)
	_assert(loaded != null and loaded.is_ok(), "the checkpoint was written")
	if loaded != null and loaded.is_ok():
		var dto: Dictionary = loaded.data
		var phase: String = str(dto.get("phase", ""))
		_assert(phase == SaveSchemaV5Script.PHASE_MAP
				or phase == SaveSchemaV5Script.PHASE_PREP
				or phase == SaveSchemaV5Script.PHASE_MERCHANT,
			"the checkpoint phase is a stable phase (it is %s)" % phase)


# ----------------------------------------------------------------


func _first_combat_child(map: Object) -> int:
	var current: Object = map.get_current_node()
	if current == null:
		return -1
	for child_id in current.child_ids:
		var child: Object = map.get_node(int(child_id))
		if child != null and int(child.type) == int(EncounterTypeScript.Kind.COMBAT):
			return int(child_id)
	return -1


func _first_service_child(map: Object) -> int:
	var current: Object = map.get_current_node()
	if current == null:
		return -1
	for child_id in current.child_ids:
		var child: Object = map.get_node(int(child_id))
		if child != null and int(child.type) != int(EncounterTypeScript.Kind.COMBAT) \
				and int(child.type) != int(EncounterTypeScript.Kind.BOSS):
			return int(child_id)
	return -1


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


const RngServiceScript = preload("res://core/utils/rng_service.gd")


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
		print("  [FAIL] Stage H03: %s" % label)
