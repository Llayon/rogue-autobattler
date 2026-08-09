class_name SaveLoadResult extends RefCounted
## Typed result of a repository load/save call. Avoids bool-only
## returns and string-typed error codes at the call site.

const OK: int = 0
const ERROR_LEGACY_LOAD_FAILED: int = 1
const ERROR_LEGACY_MIGRATION_FAILED: int = 2
const ERROR_V4_VALIDATION_FAILED: int = 3
const ERROR_V4_SERIALIZATION_FAILED: int = 4
const ERROR_TEMP_WRITE_FAILED: int = 5
const ERROR_TEMP_RELOAD_FAILED: int = 6
const ERROR_TEMP_VALIDATION_FAILED: int = 7
const ERROR_BACKUP_FAILED: int = 8
const ERROR_ATOMIC_REPLACE_FAILED: int = 9
const ERROR_UNKNOWN_FORMAT: int = 10
const ERROR_V4_LOAD_FAILED: int = 11
const ERROR_CORRUPT_INPUT: int = 12
const ERROR_V4_ALREADY_CURRENT: int = 13
const ERROR_IO: int = 14
const ERROR_BACKUP_INVALID: int = 15
const ERROR_BACKUP_CONFLICT: int = 16
const ERROR_CORRUPT_V4: int = 17
const ERROR_UNSUPPORTED_SCHEMA: int = 18
const ERROR_RECOVERY_FAILED: int = 19

## One of the OK / ERROR_* constants.
var status: int = OK
## Optional `v4 DTO` (Dictionary) on success; empty on failure.
var data: Dictionary = {}
## One of "legacy_v1", "v4", "unknown", "missing". Useful for tests
## and for cache invalidation.
var source_format: String = "unknown"
## True when the load performed a legacy v1 -> v4 migration in
## memory and persisted the v4 file.
var migrated: bool = false
## When `migrated == true`, path to the immutable legacy backup
## file. Empty otherwise.
var backup_path: String = ""
## Path to the save file that was loaded (legacy or v4). Useful for
## tests.
var source_path: String = ""
## Accumulated diagnostics; never null.
var diagnostics: Array[RefCounted] = []


func is_ok() -> bool:
	return status == OK


func is_error() -> bool:
	return status != OK


func add_diagnostic(diagnostic: RefCounted) -> void:
	if diagnostic != null:
		diagnostics.append(diagnostic)


static func ok() -> RefCounted:
	var r: RefCounted = SaveLoadResult.new()
	r.status = OK
	return r


static func error_with(code: int, source_format: String = "unknown", detail: String = "") -> RefCounted:
	var r: RefCounted = SaveLoadResult.new()
	r.status = code
	r.source_format = source_format
	if detail != "":
		var d: RefCounted = MigrationDiagnostic.error(_error_code_name(code), detail, "")
		r.diagnostics.append(d)
	return r


static func _error_code_name(code: int) -> String:
	match code:
		OK: return "ok"
		ERROR_LEGACY_LOAD_FAILED: return "legacy_load_failed"
		ERROR_LEGACY_MIGRATION_FAILED: return "legacy_migration_failed"
		ERROR_V4_VALIDATION_FAILED: return "v4_validation_failed"
		ERROR_V4_SERIALIZATION_FAILED: return "v4_serialization_failed"
		ERROR_TEMP_WRITE_FAILED: return "temp_write_failed"
		ERROR_TEMP_RELOAD_FAILED: return "temp_reload_failed"
		ERROR_TEMP_VALIDATION_FAILED: return "temp_validation_failed"
		ERROR_BACKUP_FAILED: return "backup_failed"
		ERROR_ATOMIC_REPLACE_FAILED: return "atomic_replace_failed"
		ERROR_UNKNOWN_FORMAT: return "unknown_format"
		ERROR_V4_LOAD_FAILED: return "v4_load_failed"
		ERROR_CORRUPT_INPUT: return "corrupt_input"
		ERROR_V4_ALREADY_CURRENT: return "v4_already_current"
		ERROR_IO: return "io_error"
		ERROR_BACKUP_INVALID: return "backup_invalid"
		ERROR_BACKUP_CONFLICT: return "backup_conflict"
		ERROR_CORRUPT_V4: return "corrupt_v4"
		ERROR_UNSUPPORTED_SCHEMA: return "unsupported_schema"
		ERROR_RECOVERY_FAILED: return "recovery_failed"
		_: return "unknown"
