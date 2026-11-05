extends SceneTree
const ISOLATED_DIR: String = "user://run_integrity_critic_findings/"
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")

## Run Integrity — the critic's findings, pinned as regressions.
##
## H-1 (HIGH): a v4 save taken AFTER the map was entered can never be
## continued. The v4->v5 migration cannot rebuild the map, but the
## domain state still references a node, so the transactional resume
## fails closed on the missing map snapshot. The player's progress is
## lost.
##
## m-1 (MAJOR): the encounter-map overlay reseeds the GLOBAL run RNG
## stream to its constant preview seed in _ready(), before the run
## restores the persisted continuation.
##
## m-2 (MAJOR): the v5 load path has no semantic validation of the
## unit and item collections: the required unit keys, a duplicate
## instance_id, an invalid location and an inconsistent equipment
## link are all accepted.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunStateV4MapperScript = preload("res://core/progression/run_state_v4_mapper.gd")
const RunCheckpointV5MapperScript = preload("res://core/progression/run_checkpoint_v5_mapper.gd")
const SaveSchemaV5Script = preload("res://core/save/save_schema_v5.gd")
const SaveServiceScript = preload("res://core/save/save_service.gd")
const EncounterMapScript = preload("res://core/encounter/encounter_map.gd")
const EncounterMapSceneScript = preload("res://scenes/encounter/encounter_map_scene.gd")
const RngServiceScript = preload("res://core/utils/rng_service.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_H1_a_v4_map_save_can_still_be_continued()
	await _test_m1_the_overlay_does_not_reseed_the_run_stream()
	await _test_m2_the_v5_gate_validates_the_unit_collection()
	print("")
	print("=== STAGE 3D: CRITIC FINDINGS: %d pass / %d fail ===" % [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


func _make_controller(seed_value: int) -> Node:
	var ctrl: Node = RunControllerScript.new()
	_isolate_saves(ctrl)
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]
	ctrl.start_run(seed_value)
	await process_frame
	return ctrl


# ---------------------------------------------------------------- H-1


## A v4 save taken after the map was entered must still be continuable.
##
## The v4 file carries no map snapshot. The migration must therefore
## reconstruct the map from the seed — deterministically, and it MUST
## be the same graph the v4 run had, because the v4 map was also
## generated from that seed.
func _test_H1_a_v4_map_save_can_still_be_continued() -> void:
	var seed_value: int = 890002
	var ctrl: Node = await _make_controller(seed_value)

	# Enter the map: the domain state now references a node.
	ctrl.encounter_map = EncounterMapScript.new()
	ctrl.encounter_map.generate(seed_value)
	ctrl.encounter_map.start_run()
	ctrl.state.current_encounter_id = ctrl.encounter_map.get_current_node_id()
	ctrl._set_phase(ctrl.Phase.MAP)

	# Write a REAL v4 save through the production v4 facade, into the
	# SAME isolated repository the resume reads from: the write and the
	# read must use one repository, otherwise the resume finds nothing.
	var v4_dto: Dictionary = RunStateV4MapperScript.to_v4_dto(ctrl.state)
	var repo: Object = ctrl.save_repository
	var written: RefCounted = repo.save_run(seed_value, v4_dto)
	_assert(written != null and written.is_ok(), "the v4 save is written")
	# The values are captured BEFORE the controller is freed.
	var saved_gold: int = ctrl.state.gold
	var saved_node: int = ctrl.state.current_encounter_id
	ctrl.queue_free()
	await process_frame

	# The run must be continuable.
	var resumed_ctrl: Node = RunControllerScript.new()
	_isolate_saves(resumed_ctrl)
	get_root().add_child(resumed_ctrl)
	await process_frame
	resumed_ctrl.profile = MetaProfileScript.new()
	resumed_ctrl.profile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]
	var resumed: bool = resumed_ctrl.resume_run(seed_value)
	await process_frame
	_assert(resumed, "a v4 save taken after the map was entered can be continued")

	if resumed:
		_assert(resumed_ctrl.encounter_map != null,
			"the continued v4 run has the encounter map")
		if resumed_ctrl.encounter_map != null:
			_assert(resumed_ctrl.encounter_map.get_current_node_id() == saved_node,
				"the continued v4 run keeps the saved current node")
		_assert(resumed_ctrl.state.gold == saved_gold,
			"the continued v4 run keeps the domain state")
	resumed_ctrl.queue_free()
	await process_frame


# ---------------------------------------------------------------- m-1


## The encounter-map overlay must NOT reseed the global run stream.
##
## The overlay is a VIEW. It generates a preview map, but it must not
## touch the run's random stream: the stream carries the persisted
## continuation, and a preview must not consume or reset it.
func _test_m1_the_overlay_does_not_reseed_the_run_stream() -> void:
	RngServiceScript.seed_run(424242)
	for _i in 3:
		RngServiceScript.randf()
	var before: int = int(RngServiceScript.snapshot().get("state", 0))
	var seed_before: int = RngServiceScript.current_seed

	var overlay: Control = EncounterMapSceneScript.new()
	get_root().add_child(overlay)
	await process_frame

	var after: int = int(RngServiceScript.snapshot().get("state", 0))
	_assert(before == after,
		"the encounter-map overlay does not consume the run RNG stream")
	_assert(seed_before == RngServiceScript.current_seed,
		"the encounter-map overlay does not reseed the run RNG stream")

	overlay.queue_free()
	await process_frame


# ---------------------------------------------------------------- m-2


## The v5 load path must validate the unit and item collections.
func _test_m2_the_v5_gate_validates_the_unit_collection() -> void:
	# A v5 DTO with a unit that misses a required key.
	var broken: Dictionary = SaveSchemaV5Script.empty_dto()
	broken["seed"] = 12345
	broken["run_id"] = "run_12345"
	var bad_unit: Dictionary = {
		"instance_id": "unit_000001",
		"def_id": &"warrior",
		"location": 0,
	}
	broken["units"] = [bad_unit]

	var result: Dictionary = RunCheckpointV5MapperScript.from_v5_dto(broken)
	_assert(not bool(result.get("ok", false)),
		"a v5 DTO with a malformed unit is rejected")

	# A v5 DTO with a duplicate unit instance_id.
	var duplicate: Dictionary = SaveSchemaV5Script.empty_dto()
	duplicate["seed"] = 12345
	duplicate["run_id"] = "run_12345"
	var unit_a: Dictionary = {
		"instance_id": "unit_000001",
		"def_id": &"warrior",
		"location": 0,
		"order": 0,
		"level": 1,
		"current_hp": 10,
		"max_hp": 10,
	}
	var unit_b: Dictionary = unit_a.duplicate(true)
	duplicate["units"] = [unit_a, unit_b]
	var result_dup: Dictionary = RunCheckpointV5MapperScript.from_v5_dto(duplicate)
	_assert(not bool(result_dup.get("ok", false)),
		"a v5 DTO with a duplicate unit instance_id is rejected")


# ----------------------------------------------------------------


## Points the controller at a temporary save tree.
##
## Without this the suite would write into the PRODUCTION save tree
## (`user://saves/runs`) and overwrite `user://saves/meta.tres` with
## the throwaway profile -- destroying the developer's unlocked units,
## souls and run counters, and leaving orphan run files in the browse
## list.
func _isolate_saves(controller: Object) -> void:
	var dir: String = ISOLATED_DIR
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(dir))
	controller.save_repository = RunSaveRepositoryScript.new(dir)
	controller.meta_writer = _MetaWriter.new()


## A meta writer that does NOT touch the production meta file.
class _MetaWriter:
	extends RefCounted

	func write_meta(profile: Object) -> bool:
		# The suites never need a persisted profile, so nothing is
		# written: the production `user://saves/meta.tres` stays intact.
		return true


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage 3D: %s" % label)
