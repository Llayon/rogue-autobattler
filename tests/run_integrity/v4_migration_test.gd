extends SceneTree
const ISOLATED_DIR: String = "user://run_integrity_v4_migration/"
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")

## Run Integrity — a v4 save must stay recoverable through the v5
## migration.
##
## v4 did NOT persist the real phase, the shop offer, the map
## snapshot, the reward offer or the RNG continuation. The migration
## therefore CANNOT recreate them truthfully, and it must not pretend
## to. It applies a documented conservative fallback:
##
##   phase  -> "prep"
##   shop   -> empty
##   map    -> empty
##   rewards-> empty
##   rng    -> the continuation is lost
##
## and every loss is diagnosed. The migration is non-destructive: the
## source save is never overwritten.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunStateV4MapperScript = preload("res://core/progression/run_state_v4_mapper.gd")
const RunCheckpointV5MapperScript = preload("res://core/progression/run_checkpoint_v5_mapper.gd")
const SaveSchemaV5Script = preload("res://core/save/save_schema_v5.gd")
const SaveServiceScript = preload("res://core/save/save_service.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_A_a_v4_dto_migrates_to_v5()
	await _test_B_the_migration_reports_the_information_loss()
	await _test_C_the_migrated_checkpoint_is_a_valid_v5()
	print("")
	print("=== STAGE 3C: V4 TO V5 MIGRATION: %d pass / %d fail ===" % [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## Builds a v4 DTO for a real domain state.
func _make_v4_dto() -> Dictionary:
	var ctrl: Node = RunControllerScript.new()
	_isolate_saves(ctrl)
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]
	ctrl.start_run(880001)
	await process_frame
	ctrl.state.gold = 42
	ctrl.state.round_index = 3
	var dto: Dictionary = RunStateV4MapperScript.to_v4_dto(ctrl.state)
	ctrl.queue_free()
	await process_frame
	return dto


# ---------------------------------------------------------------- A


## A v4 DTO must migrate into a valid v5 DTO.
func _test_A_a_v4_dto_migrates_to_v5() -> void:
	var v4_dto: Dictionary = await _make_v4_dto()
	_assert(int(v4_dto.get("schema_version", 0)) == 4,
		"the source DTO is a v4 DTO")

	var result: Dictionary = RunCheckpointV5MapperScript.migrate_v4_to_v5(v4_dto)
	_assert(bool(result.get("ok", false)), "the v4 DTO migrates to v5")
	if not bool(result.get("ok", false)):
		return
	var v5_dto: Dictionary = result.get("dto", {}) as Dictionary
	_assert(int(v5_dto.get("schema_version", 0)) == SaveSchemaV5Script.SCHEMA_VERSION,
		"the migrated DTO is a v5 DTO")

	# The DOMAIN data survives the migration.
	_assert(int(v5_dto.get("gold", 0)) == 42,
		"the gold survives the migration")
	_assert(int(v5_dto.get("round_index", 0)) == 3,
		"the round survives the migration")
	_assert(int(v5_dto.get("seed", 0)) == 880001,
		"the seed survives the migration")


# ---------------------------------------------------------------- B


## Every field that v4 could not persist must be reported as lost.
func _test_B_the_migration_reports_the_information_loss() -> void:
	var v4_dto: Dictionary = await _make_v4_dto()
	var result: Dictionary = RunCheckpointV5MapperScript.migrate_v4_to_v5(v4_dto)
	_assert(bool(result.get("ok", false)), "the v4 DTO migrates to v5")
	if not bool(result.get("ok", false)):
		return
	var diagnostics: Array = result.get("diagnostics", []) as Array
	_assert(not diagnostics.is_empty(),
		"the migration reports the information loss")
	var text: String = ""
	for d in diagnostics:
		text += str(d)
	_assert(text.findn("phase") >= 0,
		"the migration reports the lost phase")
	_assert(text.findn("rng") >= 0,
		"the migration reports the lost rng continuation")


# ---------------------------------------------------------------- C


## The migrated checkpoint must be a valid v5 checkpoint.
func _test_C_the_migrated_checkpoint_is_a_valid_v5() -> void:
	var v4_dto: Dictionary = await _make_v4_dto()
	var result: Dictionary = RunCheckpointV5MapperScript.migrate_v4_to_v5(v4_dto)
	if not bool(result.get("ok", false)):
		_assert(false, "the v4 DTO migrates to v5")
		return
	var v5_dto: Dictionary = result.get("dto", {}) as Dictionary

	# The conservative fallback: the phase is "prep" and the
	# checkpoint layers are empty. The migration must NOT invent state.
	_assert(str(v5_dto.get("phase", "")) == SaveSchemaV5Script.PHASE_PREP,
		"the migrated phase is the conservative prep fallback")
	var migrated_shop: Dictionary = v5_dto.get("shop", {}) as Dictionary
	_assert((migrated_shop.get("offered_ids", []) as Array).is_empty(),
		"the migrated shop offer is empty, not invented")
	var migrated_merchant: Dictionary = migrated_shop.get("merchant", {}) as Dictionary
	_assert((migrated_merchant.get("offered_item_ids", []) as Array).is_empty(),
		"the migrated merchant offer is empty, not invented")
	_assert((v5_dto.get("map", {}) as Dictionary).is_empty(),
		"the migrated map is empty, not invented")
	var migrated_rewards: Dictionary = v5_dto.get("rewards", {}) as Dictionary
	_assert((migrated_rewards.get("offered_ids", []) as Array).is_empty(),
		"the migrated reward offer is empty, not invented")

	# The migrated DTO is decodable.
	var decoded: Dictionary = RunCheckpointV5MapperScript.from_v5_dto(v5_dto)
	_assert(bool(decoded.get("ok", false)),
		"the migrated checkpoint is decodable")
	if bool(decoded.get("ok", false)):
		_assert(decoded.get("state") != null,
			"the migrated checkpoint carries the domain state")

	# The v5 schema accepts it.
	var valid: Dictionary = SaveSchemaV5Script.validate_shape(v5_dto)
	_assert(bool(valid.get("success", false)),
		"the migrated checkpoint passes the v5 schema (%s)"
			% str(valid.get("diagnostics", [])))


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
		print("  [FAIL] Stage 3C: %s" % label)
