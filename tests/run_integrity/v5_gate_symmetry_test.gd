extends SceneTree

## The v5 load and save paths must apply the SAME semantic gate as
## the v4 paths.
##
## The third independent critic found:
##
## M-1: `_load_v5_canonical` runs only `SaveSchemaV5.validate_shape`.
##      It never calls the semantic gate, so the repository reports a
##      semantically invalid checkpoint as a VALID, loadable save.
##      The controller only fails closed because the mapper gates as a
##      backstop -- any other caller of the public facade gets an
##      unchecked DTO.
##
## M-2: the v5 branch of `_save_canonical` runs only `validate_shape`
##      too, so the real gate fires only AFTER the commit. On a fresh
##      slot the invalid file is deliberately left under the target and
##      the slot becomes unrecoverable.

const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const SemanticScript = preload("res://core/save/run_domain_semantic_validator.gd")

const PROBE_DIR: String = "user://run_integrity_gate_probe/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	# The probe repository writes into its OWN directory: it must exist,
	# or the write cannot happen and the assertions about the file on
	# disk would be vacuously true.
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(PROBE_DIR))
	await _test_A_the_v5_load_path_runs_the_semantic_gate()
	await _test_B_the_v5_save_path_runs_the_semantic_gate()
	await _test_C_a_bad_checkpoint_is_not_written()
	print("")
	print("=== STAGE 3E: V5 GATE SYMMETRY: %d pass / %d fail ===" % [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A checkpoint whose item names an owner that does not list it.
##
## The semantic gate rejects it. The repository must reject it too.
func _bad_dto() -> Dictionary:
	return {
		"schema_version": 5,
		"game_build": "",
		"run_id": "run_777",
		"seed": 777,
		"round_index": 1,
		"phase": "prep",
		"gold": 0,
		"units": [{
			"instance_id": "unit_000001", "definition_id": &"warrior",
			"current_hp": 10, "max_hp": 10, "bonus_attack": 0, "dead": false,
			"location": 0, "order": 0, "equipped_item_ids": [],
		}],
		"items": [{
			"instance_id": "item_000001", "definition_id": &"potion_strength",
			"owner_unit_id": "unit_000001",
		}],
		"next_unit_instance_seq": 2,
		"next_item_instance_seq": 2,
		"shop": {},
		"map": {},
		"rewards": {},
		"rng": {"seed": 777, "state": "1234567890123456789"},
		"wins": 0, "losses": 0, "units_killed": 0, "lives": 3, "xp": 0,
		"level": 1, "current_encounter_id": -1, "encounter_visited_ids": [],
		"meta_modifiers": {}, "just_visited_merchant": false,
	}


func _test_A_the_v5_load_path_runs_the_semantic_gate() -> void:
	var dto: Dictionary = _bad_dto()
	# The gate itself must reject the DTO.
	var gate: Dictionary = SemanticScript.validate(dto)
	_assert(not bool(gate.get("success", true)),
		"the semantic gate rejects the inconsistent checkpoint")

	var repo = RunSaveRepositoryScript.new(PROBE_DIR)
	var result: RefCounted = repo._load_v5_canonical(dto, "user://probe", 777)
	_assert(result != null, "the load returns a result")
	if result != null:
		_assert(not result.is_ok(),
			"the v5 load path rejects the semantically invalid checkpoint")


func _test_B_the_v5_save_path_runs_the_semantic_gate() -> void:
	var dto: Dictionary = _bad_dto()
	var repo = RunSaveRepositoryScript.new(PROBE_DIR)
	var result: RefCounted = repo._save_canonical(777, dto, "v5")
	_assert(result != null, "the save returns a result")
	if result != null:
		_assert(not result.is_ok(),
			"the v5 save path rejects the semantically invalid checkpoint")
	# The rejection must happen BEFORE the write. Without the pre-write
	# gate the save still fails, but only in the post-commit validation,
	# i.e. AFTER the atomic swap -- and then the invalid bytes are
	# already on disk.
	var path: String = PROBE_DIR + "run_777.tres"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	repo._save_canonical(777, dto, "v5")
	_assert(not FileAccess.file_exists(path),
		"the invalid checkpoint never reaches the disk")


## The invalid checkpoint must never reach the disk.
func _test_C_a_bad_checkpoint_is_not_written() -> void:
	var path: String = PROBE_DIR + "run_777.tres"
	# Remove a leftover from a previous run.
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var dto: Dictionary = _bad_dto()
	var repo = RunSaveRepositoryScript.new(PROBE_DIR)
	repo._save_canonical(777, dto, "v5")
	if FileAccess.file_exists(path):
		var f: FileAccess = FileAccess.open(path, FileAccess.READ)
		var text: String = f.get_as_text()
		f.close()
		_assert(not text.contains("item_000001"),
			"the invalid checkpoint is not written to the save slot")
	else:
		_assert(true, "the invalid checkpoint is not written to the save slot")


# ----------------------------------------------------------------


## Points the controller at a temporary save tree.
##
## Without this the suite would write into the PRODUCTION save tree
## (`user://saves/runs`) and overwrite `user://saves/meta.tres` with
## the throwaway profile -- destroying the developer's unlocked units,
## souls and run counters, and leaving orphan run files in the browse
## list.
func _isolate_saves(controller: Object) -> void:
	var dir: String = "user://run_integrity_isolated/"
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
		print("  [FAIL] Stage 3E: %s" % label)
