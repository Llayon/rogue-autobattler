extends SceneTree

## The v5 rng contract must hold on the SAVE path too.
##
## m-2 (fourth critic): a machine state of 0 is not a valid
## continuation. `DeterministicRng.restore` does `seed_with(seed)` and
## then assigns `_rng.state = 0`, which OVERWRITES the correctly
## seeded state with a degenerate one: the first draw is exactly 0.0
## for EVERY seed. A migrated v4 checkpoint carries `state = 0`,
## because v4 never persisted the continuation, so a migrated run
## resumes on that degenerate stream.
##
## The fix: a checkpoint that carries NO continuation must not claim
## the state 0. It must re-seed from the run seed instead, which is
## exactly what a fresh run does.
##
## m-4 (fourth critic): the v5 schema did not validate `rng.state` at
## the shape level, so a DTO with a NUMERIC state passed the shape
## gate AND the semantic gate (the gate does not look at `rng`), was
## written to the disk, and then could not be read back: the load
## rejected it. A save that cannot be read back is a poison slot.

const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const SaveSchemaV5Script = preload("res://core/save/save_schema_v5.gd")
const RunCheckpointV5MapperScript = preload("res://core/progression/run_checkpoint_v5_mapper.gd")
const RngServiceScript = preload("res://core/utils/rng_service.gd")

const PROBE_DIR: String = "user://run_integrity_rng_contract/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(PROBE_DIR))
	await _test_A_a_state_of_zero_is_not_a_continuation()
	await _test_B_the_migrated_checkpoint_carries_no_continuation()
	await _test_C_the_schema_rejects_a_numeric_state()
	await _test_D_a_numeric_state_is_never_written()
	print("")
	print("=== STAGE 3E: RNG WIRE CONTRACT: %d pass / %d fail ===" % [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A state of 0 is the degenerate state: the first draw is exactly
## 0.0 for every seed, so it cannot be a continuation.
func _test_A_a_state_of_zero_is_not_a_continuation() -> void:
	RngServiceScript.seed_run(999)
	RngServiceScript.restore({"seed": 999, "state": 0})
	var first: float = RngServiceScript.randf()
	_assert(first != 0.0,
		"a state of 0 does not produce a degenerate first draw (got %f)" % first)
	RngServiceScript.seed_run(12345)
	RngServiceScript.restore({"seed": 12345, "state": 0})
	var other: float = RngServiceScript.randf()
	_assert(other != 0.0,
		"a state of 0 does not produce a degenerate first draw for another seed (got %f)" % other)


## The migrated v4 checkpoint must NOT claim the state 0: v4 never
## persisted the continuation, so the migrated run has to re-seed.
func _test_B_the_migrated_checkpoint_carries_no_continuation() -> void:
	var migrated: Dictionary = RunCheckpointV5MapperScript.migrate_v4_to_v5(
		_dto_with_rng({"seed": 7, "state": ""}))
	var rng_out: Dictionary = migrated.get("rng", {}) as Dictionary
	var state: String = String(rng_out.get("state", ""))
	_assert(state != "0",
		"the migrated checkpoint does not claim the degenerate state 0 (got %s)" % state)


## The v5 schema must validate the rng state at the shape level.
func _test_C_the_schema_rejects_a_numeric_state() -> void:
	var bad: Dictionary = _dto_with_rng({"seed": 888, "state": 12345})
	var shape: Dictionary = SaveSchemaV5Script.validate_shape(bad)
	_assert(not bool(shape.get("success", true)),
		"the v5 schema rejects a numeric rng state")
	var good: Dictionary = _dto_with_rng({"seed": 888, "state": "12345"})
	var good_shape: Dictionary = SaveSchemaV5Script.validate_shape(good)
	_assert(bool(good_shape.get("success", false)),
		"the v5 schema accepts the canonical decimal string state")


## A numeric state must never reach the disk.
func _test_D_a_numeric_state_is_never_written() -> void:
	var path: String = PROBE_DIR + "run_888.tres"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var bad: Dictionary = _dto_with_rng({"seed": 888, "state": 12345})
	var repo = RunSaveRepositoryScript.new(PROBE_DIR)
	var result: RefCounted = repo.save_run_v5(888, bad)
	_assert(result != null and not result.is_ok(),
		"the save path rejects a numeric rng state")
	_assert(not FileAccess.file_exists(path),
		"the unreadable checkpoint never reaches the disk")


# ----------------------------------------------------------------


func _dto_with_rng(rng: Dictionary) -> Dictionary:
	return {
		"schema_version": 5, "game_build": "", "run_id": "run_888", "seed": 888,
		"round_index": 1, "phase": "prep", "gold": 0,
		"units": [], "items": [],
		"next_unit_instance_seq": 1, "next_item_instance_seq": 1,
		"shop": {}, "map": {}, "rewards": {},
		"rng": rng,
		"wins": 0, "losses": 0, "units_killed": 0, "lives": 3, "xp": 0,
		"level": 1, "current_encounter_id": -1, "encounter_visited_ids": [],
		"meta_modifiers": {}, "just_visited_merchant": false,
	}


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage 3E: %s" % label)
