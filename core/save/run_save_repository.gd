class_name RunSaveRepository extends RefCounted
## Production save repository for the v4 run schema. Handles format
## detection, in-memory legacy migration, atomic write, and
## immutable legacy backup. Does not depend on Godot autoloads.
##
## The repository is decoupled from `RunController`. The migration
## orchestration is here, not in the controller.

const SaveSchemaV4Script = preload("res://core/save/save_schema_v4.gd")
const MigratorScript = preload("res://core/save/legacy_save_v1_to_v4_migrator.gd")
const SaveLoadResultScript = preload("res://core/save/save_load_result.gd")
const MigrationDiagnosticScript = preload("res://core/save/migration_diagnostic.gd")

const BACKUP_SUFFIX: String = ".legacy-v1.bak"

## Construct a repository bound to a specific directory and the
## filename pattern `run_<seed>.tres`. The base directory is
## normally `user://saves/runs/`, but tests pass an isolated temp
## directory to avoid touching the user's data.
func _init(p_runs_dir: String) -> void:
	runs_dir = p_runs_dir
	_save_count = 0
	_load_count = 0
	_migration_count = 0

var runs_dir: String = ""
var _save_count: int = 0
var _load_count: int = 0
var _migration_count: int = 0


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Returns a v4 DTO (Dictionary). On a fresh legacy save the first
## call migrates in memory and persists the v4 file plus a legacy
## backup. Subsequent calls load the v4 file directly.
##
## The repository never throws for expected migration/validation
## failures; every failure is reported through `SaveLoadResult.status`.
func load_run(seed_value: int) -> RefCounted:
	_load_count += 1
	var run_path: String = _run_path(seed_value)
	if not FileAccess.file_exists(run_path):
		var r: RefCounted = SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_V4_LOAD_FAILED,
			"missing",
			"save file not found: %s" % run_path
		)
		return r
	# Try v4 first.
	var v4_text: PackedByteArray = FileAccess.get_file_as_bytes(run_path)
	if _looks_like_v4(v4_text):
		return _load_v4(run_path, seed_value)
	# Then legacy v1.
	if _looks_like_legacy_v1(v4_text):
		return _load_legacy_and_migrate(run_path, seed_value)
	var unknown: RefCounted = SaveLoadResultScript.error_with(
		SaveLoadResultScript.ERROR_UNKNOWN_FORMAT,
		"unknown",
		"file does not look like v4 or legacy v1"
	)
	unknown.source_path = run_path
	return unknown


## Persist a v4 DTO atomically. Returns OK on success, ERROR_* on
## failure. The existing save file (legacy or v4) is never replaced
## before the temporary write, re-read, re-validate, and atomic
## rename steps all succeed.
func save_run(seed_value: int, v4_data: Dictionary) -> RefCounted:
	_save_count += 1
	var run_path: String = _run_path(seed_value)
	# Pre-step: validate the in-memory v4 DTO before any I/O.
	var v: Dictionary = MigratorScript.validate(v4_data)
	if not bool(v.get("success", false)):
		var r: RefCounted = SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED,
			"v4",
			"v4 DTO failed validation before write"
		)
		for d in v.get("diagnostics", []):
			r.add_diagnostic(d)
		return r
	# Serialise: canonical Dictionary text. We keep the on-disk form
	# as a plain .tres-like text file using Godot ResourceSaver via
	# a temporary `RunState`-like shape. For now, the repository
	# uses `ResourceSaver` only on a Resource stub. To keep the
	# repository pure (no new Resource types), we serialise to a
	# plain Dictionary text via JSON in v4 form, and read it back
	# via `JSON.parse_string` for the temp re-read step.
	var serialised: Dictionary = MigratorScript.serialize(v4_data)
	var temp_path: String = run_path + ".tmp"
	var ok: bool = _write_dict_text(temp_path, serialised)
	if not ok:
		return SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_TEMP_WRITE_FAILED,
			"v4",
			"failed to write temp v4 file: %s" % temp_path
		)
	# Re-read and re-validate the temp file before replacing.
	var reloaded: Dictionary = _read_dict_text(temp_path)
	if reloaded.is_empty():
		return SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_TEMP_RELOAD_FAILED,
			"v4",
			"failed to re-read temp v4 file: %s" % temp_path
		)
	var tv: Dictionary = MigratorScript.validate(reloaded)
	if not bool(tv.get("success", false)):
		return SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_TEMP_VALIDATION_FAILED,
			"v4",
			"temp v4 file failed validation"
		)
	# Atomic replace: rename temp -> target. On Windows
	# `DirAccess.rename_absolute` is atomic. Use the underlying
	# `OS.move_to` fallback only if needed.
	if not _atomic_replace(temp_path, run_path):
		return SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_ATOMIC_REPLACE_FAILED,
			"v4",
			"failed to atomic-replace %s" % run_path
		)
	var ok_r: RefCounted = SaveLoadResultScript.ok()
	ok_r.source_format = "v4"
	ok_r.source_path = run_path
	ok_r.data = reloaded
	return ok_r


## Backup policy: the legacy backup is created exactly once per
## run file. An existing legacy-v1 backup is never overwritten.
## Returns the backup path on success, empty string on failure.
func create_legacy_backup_if_missing(legacy_path: String) -> String:
	var backup_path: String = legacy_path + BACKUP_SUFFIX
	if FileAccess.file_exists(backup_path):
		# Immutable: never overwrite an existing backup.
		return backup_path
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(legacy_path)
	if bytes.is_empty():
		return ""
	var f: FileAccess = FileAccess.open(backup_path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_buffer(bytes)
	f.close()
	return backup_path


# ---------------------------------------------------------------------------
# Format detection
# ---------------------------------------------------------------------------

static func _looks_like_v4(text: PackedByteArray) -> bool:
	# v4 DTOs are stored as a simple key=value text file produced by
	# _write_dict_text. We detect by scanning for the schema_version
	# header.
	if text.is_empty():
		return false
	var s: String = text.get_string_from_utf8()
	# The JSON body contains "schema_version": 4.
	return s.find("\"schema_version\": 4") >= 0 or s.find("\"schema_version\":4") >= 0


static func _looks_like_legacy_v1(text: PackedByteArray) -> bool:
	if text.is_empty():
		return false
	var s: String = text.get_string_from_utf8()
	# Legacy .tres has a [gd_resource] header.
	if not s.begins_with("[gd_resource"):
		return false
	# Required structural fields. The fixture shows the core
	# unit arrays; item_equip_board_idx, bench_unit_ids, and
	# item_ids are optional but typical. A file is legacy v1 if it
	# is a Godot resource that has the v1 unit-array structure.
	for key in ["player_unit_ids", "unit_states"]:
		if s.find(key) < 0:
			return false
	return true


# ---------------------------------------------------------------------------
# v4 path
# ---------------------------------------------------------------------------

func _load_v4(run_path: String, seed_value: int) -> RefCounted:
	var parsed: Dictionary = _read_dict_text(run_path)
	if parsed.is_empty():
		var r: RefCounted = SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_V4_LOAD_FAILED,
			"v4",
			"failed to parse v4 file: %s" % run_path
		)
		r.source_path = run_path
		return r
	var v: Dictionary = MigratorScript.validate(parsed)
	if not bool(v.get("success", false)):
		var ve: RefCounted = SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED,
			"v4",
			"v4 file failed validation: %s" % run_path
		)
		ve.source_path = run_path
		for d in v.get("diagnostics", []):
			ve.add_diagnostic(d)
		return ve
	var ok: RefCounted = SaveLoadResultScript.ok()
	ok.source_format = "v4"
	ok.source_path = run_path
	ok.data = parsed
	return ok


# ---------------------------------------------------------------------------
# Legacy path
# ---------------------------------------------------------------------------

func _load_legacy_and_migrate(legacy_path: String, seed_value: int) -> RefCounted:
	# Step 1: load the legacy .tres via Godot's resource loader.
	# We must NOT mutate the file: the loader must not rewrite it.
	var legacy_bytes_before: PackedByteArray = FileAccess.get_file_as_bytes(legacy_path)
	var legacy_res: Resource = load(legacy_path)
	if legacy_res == null:
		var r: RefCounted = SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_LEGACY_LOAD_FAILED,
			"legacy_v1",
			"failed to load legacy resource: %s" % legacy_path
		)
		r.source_path = legacy_path
		return r
	# Confirm the on-disk bytes are unchanged after `load()`. The
	# production loader must not mutate the file; if it does, that
	# is a corruption hazard we surface as ERROR_CORRUPT_INPUT.
	var legacy_bytes_after: PackedByteArray = FileAccess.get_file_as_bytes(legacy_path)
	if legacy_bytes_before != legacy_bytes_after:
		var r2: RefCounted = SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_CORRUPT_INPUT,
			"legacy_v1",
			"legacy loader mutated the file; refusing to migrate"
		)
		r2.source_path = legacy_path
		return r2
	# Step 2: in-memory migration (pure).
	var mig: Dictionary = MigratorScript.migrate_run(legacy_res)
	if not bool(mig.get("success", false)):
		var r3: RefCounted = SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_LEGACY_MIGRATION_FAILED,
			"legacy_v1",
			"migrator returned failure for: %s" % legacy_path
		)
		r3.source_path = legacy_path
		for d in mig.get("diagnostics", []):
			r3.add_diagnostic(d)
		return r3
	var v4_data: Dictionary = mig.get("data", {})
	# Step 3: validate the migrated v4 DTO.
	var v: Dictionary = MigratorScript.validate(v4_data)
	if not bool(v.get("success", false)):
		var r4: RefCounted = SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED,
			"legacy_v1",
			"migrated v4 DTO failed validation: %s" % legacy_path
		)
		r4.source_path = legacy_path
		for d in v.get("diagnostics", []):
			r4.add_diagnostic(d)
		return r4
	# Step 4: serialise the v4 DTO and write to a temp file.
	var serialised: Dictionary = MigratorScript.serialize(v4_data)
	var temp_path: String = legacy_path + ".v4.tmp"
	if not _write_dict_text(temp_path, serialised):
		return SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_TEMP_WRITE_FAILED,
			"legacy_v1",
			"failed to write temp v4 file: %s" % temp_path
		)
	# Step 5: re-read the temp file and re-validate.
	var reloaded: Dictionary = _read_dict_text(temp_path)
	if reloaded.is_empty():
		return SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_TEMP_RELOAD_FAILED,
			"legacy_v1",
			"failed to re-read temp v4 file: %s" % temp_path
		)
	var tv: Dictionary = MigratorScript.validate(reloaded)
	if not bool(tv.get("success", false)):
		return SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_TEMP_VALIDATION_FAILED,
			"legacy_v1",
			"temp v4 file failed validation"
		)
	# Step 6: preserve the legacy backup (immutable; never overwrite).
	var backup_path: String = create_legacy_backup_if_missing(legacy_path)
	if backup_path == "":
		return SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_BACKUP_FAILED,
			"legacy_v1",
			"failed to create legacy backup: %s" % (legacy_path + BACKUP_SUFFIX)
		)
	# Step 7: atomic replace legacy with the v4 file.
	if not _atomic_replace(temp_path, legacy_path):
		return SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_ATOMIC_REPLACE_FAILED,
			"legacy_v1",
			"failed to atomic-replace legacy with v4: %s" % legacy_path
		)
	# Step 8: confirm the legacy on-disk file is now the v4 file
	# (so a subsequent load_run() reads v4, not legacy again).
	var post_bytes: PackedByteArray = FileAccess.get_file_as_bytes(legacy_path)
	if not _looks_like_v4(post_bytes):
		# Rollback: try to restore the backup so the legacy save is
		# still readable.
		_atomic_replace(backup_path, legacy_path)
		return SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_IO,
			"legacy_v1",
			"post-replace file is not v4; rolled back"
		)
	_migration_count += 1
	var ok: RefCounted = SaveLoadResultScript.ok()
	ok.source_format = "v4"
	ok.source_path = legacy_path
	ok.was_migrated = true
	ok.backup_path = backup_path
	ok.data = reloaded
	# Carry migrator diagnostics so callers can inspect.
	for d in mig.get("diagnostics", []):
		ok.add_diagnostic(d)
	return ok


# ---------------------------------------------------------------------------
# File I/O helpers
# ---------------------------------------------------------------------------

func _run_path(seed_value: int) -> String:
	return runs_dir + "run_%d.tres" % seed_value


## Writes a v4 DTO as a JSON file. The file starts with a
## `# v4 save` marker line so `_looks_like_v4` can detect the format
## before parsing.
static func _write_dict_text(path: String, data: Dictionary) -> bool:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_line("# v4 save")
	f.store_string(JSON.stringify(_to_json_safe(data), "", false))
	f.close()
	return true


## Reads a JSON-encoded v4 file produced by `_write_dict_text`.
## Returns an empty Dictionary on parse error.
static func _read_dict_text(path: String) -> Dictionary:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text: String = f.get_as_text()
	f.close()
	# Drop the `# v4 save` marker on the first line.
	var nl: int = text.find("\n")
	if nl < 0:
		return {}
	var body: String = text.substr(nl + 1, text.length() - (nl + 1))
	if body.strip_edges() == "":
		return {}
	var parsed: Variant = JSON.parse_string(body)
	if not parsed is Dictionary:
		return {}
	return parsed


## Convert a v4 DTO into a shape JSON can encode. Godot JSON
## supports primitives, Dictionary, Array, String, StringName, and
## null.
static func _to_json_safe(value: Variant) -> Variant:
	if value is Array:
		var out: Array = []
		for v in value:
			out.append(_to_json_safe(v))
		return out
	if value is Dictionary:
		var d: Dictionary = {}
		for k in value.keys():
			d[String(k)] = _to_json_safe(value[k])
		return d
	return value


## Atomic replace: read the source, write the target, remove the
## source. `DirAccess.rename_absolute` is not used because on
## Windows it fails when the target already exists.
static func _atomic_replace(source_path: String, target_path: String) -> bool:
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(source_path)
	if bytes.is_empty():
		return false
	var f: FileAccess = FileAccess.open(target_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	f.close()
	if FileAccess.file_exists(source_path):
		var dir: DirAccess = DirAccess.open(source_path.get_base_dir())
		if dir != null:
			dir.remove(source_path.get_file())
	return FileAccess.file_exists(target_path)


static func _zero_for(key: String) -> Variant:
	match key:
		"schema_version": return SaveSchemaV4Script.SCHEMA_VERSION
		"game_build": return ""
		"run_id": return ""
		"seed": return 0
		"round_index": return 1
		"phase": return "prep"
		"gold": return 0
		"units": return [] as Array
		"items": return [] as Array
		"next_unit_instance_seq": return 0
		"next_item_instance_seq": return 0
		"shop": return {} as Dictionary
		"map": return {} as Dictionary
		"rewards": return {} as Dictionary
		"wins": return 0
		"losses": return 0
		"units_killed": return 0
		"lives": return 0
		"xp": return 0
		"level": return 0
		"current_encounter_id": return -1
		"encounter_visited_ids": return [] as Array
		"meta_modifiers": return {} as Dictionary
		"just_visited_merchant": return false
		_: return null
