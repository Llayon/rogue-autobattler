class_name MigrationResult extends RefCounted
## Outcome of a single migration call. `success == true` is the
## expected path; the migrator never throws for expected
## validation failures.

const SOURCE_SCHEMA_LEGACY_V1: int = 1
const TARGET_SCHEMA_V4: int = 4

var success: bool = false
## On success: a SaveSchemaV4 DTO (canonical Dictionary). On
## failure: `null`. Callers must check `success` before reading.
var data: Dictionary = {}
## Stable source schema identifier (currently always
## `SOURCE_SCHEMA_LEGACY_V1`).
var source_schema: int = 0
## Stable target schema identifier (currently always
## `TARGET_SCHEMA_V4`).
var target_schema: int = 0
## Accumulated diagnostics; never null.
var diagnostics: Array[RefCounted] = []


func add_diagnostic(diagnostic: RefCounted) -> void:
	if diagnostic != null:
		diagnostics.append(diagnostic)


func has_errors() -> bool:
	for d in diagnostics:
		if d.severity == MigrationDiagnostic.Severity.ERROR:
			return true
	return false
