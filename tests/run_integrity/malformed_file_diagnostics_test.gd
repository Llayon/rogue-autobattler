extends SceneTree

## A malformed save file must produce an ERROR RESULT, never a crash.
##
## The v5 load path passed the shape-validation diagnostics to
## `SaveLoadResult.add_diagnostic()`, which expects a RefCounted. The
## diagnostics were plain Dictionaries, because the schema's `_err`
## helper tested `ClassDB.class_exists("MigrationDiagnostic")` — and
## ClassDB never knows a project `class_name` script. The load path
## therefore CRASHED on a shape-invalid file instead of reporting it.
##
## The same flaw existed in the v4 schema.

const SaveSchemaV5Script = preload("res://core/save/save_schema_v5.gd")
const SaveSchemaV4Script = preload("res://core/save/save_schema_v4.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const SaveLoadResultScript = preload("res://core/save/save_load_result.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_A_the_v5_diagnostics_are_refcounted()
	await _test_B_the_v4_diagnostics_are_refcounted()
	await _test_C_a_shape_invalid_file_does_not_crash_the_load()
	print("")
	print("=== STAGE 3E: MALFORMED FILE DIAGNOSTICS: %d pass / %d fail ===" % [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## Every diagnostic must be a RefCounted, because the caller passes it
## to SaveLoadResult.add_diagnostic().
func _test_A_the_v5_diagnostics_are_refcounted() -> void:
	var bad: Dictionary = {"schema_version": 5, "seed": 1}
	var result: Dictionary = SaveSchemaV5Script.validate_shape(bad)
	_assert(not bool(result.get("success", true)), "the invalid DTO is rejected")
	var diagnostics: Array = result.get("diagnostics", []) as Array
	_assert(not diagnostics.is_empty(), "the rejection carries diagnostics")
	var all_objects: bool = true
	for d in diagnostics:
		if not (d is Object):
			all_objects = false
	_assert(all_objects,
		"every v5 diagnostic is an Object, so add_diagnostic() accepts it")


func _test_B_the_v4_diagnostics_are_refcounted() -> void:
	var bad: Dictionary = {"schema_version": 4, "seed": 1}
	var result: Dictionary = SaveSchemaV4Script.validate_shape(bad)
	_assert(not bool(result.get("success", true)), "the invalid DTO is rejected")
	var diagnostics: Array = result.get("diagnostics", []) as Array
	_assert(not diagnostics.is_empty(), "the rejection carries diagnostics")
	var all_objects: bool = true
	for d in diagnostics:
		if not (d is Object):
			all_objects = false
	_assert(all_objects,
		"every v4 diagnostic is an Object, so add_diagnostic() accepts it")


## The load path must REPORT the failure, not crash.
func _test_C_a_shape_invalid_file_does_not_crash_the_load() -> void:
	var repo = RunSaveRepositoryScript.new("user://run_integrity_probe")
	# A DTO that fails the shape validation but passes the seed and
	# run_id checks, so the load reaches the diagnostic hand-off.
	var parsed: Dictionary = {
		"schema_version": 5,
		"game_build": "",
		"run_id": "run_777",
		"seed": 777,
		"round_index": 1.0,
		"phase": "prep",
		"gold": 0.0,
		"units": [],
		"items": [],
		"next_unit_instance_seq": 1.0,
		"next_item_instance_seq": 1.0,
		"shop": {},
		"map": {},
		"rewards": {},
		"rng": {},
		"wins": 0.0,
		"losses": 0.0,
		"units_killed": 0.0,
		"lives": 3.0,
		"xp": 0.0,
		"level": 1.0,
		"current_encounter_id": -1.0,
		"encounter_visited_ids": [],
		"meta_modifiers": {},
		"just_visited_merchant": false,
	}
	# Break the shape: the phase must be a known wire name.
	parsed["phase"] = "not_a_phase"
	var result: RefCounted = repo._load_v5_canonical(parsed, "user://probe", 777)
	_assert(result != null, "the load returns a result instead of crashing")
	if result != null:
		_assert(not result.is_ok(), "the malformed file is reported as a failure")
		var diagnostics: Array = []
		if result.diagnostics != null:
			diagnostics = result.diagnostics as Array
		_assert(not diagnostics.is_empty(),
			"the failure carries the diagnostics of the rejection")
		var all_objects: bool = true
		for d in diagnostics:
			if not (d is Object):
				all_objects = false
		_assert(all_objects, "every reported diagnostic is an Object")


# ----------------------------------------------------------------


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage 3E: %s" % label)
