class_name MigrationDiagnostic extends RefCounted
## A single non-fatal issue encountered during migration.
##
## Diagnostics never abort the migrator. The migrator always
## returns a `MigrationResult` and accumulates diagnostics; the
## caller decides what to do with `success == false`.

enum Severity { INFO, WARNING, ERROR }

var severity: int = Severity.INFO
## Stable machine-readable code (e.g. "unit_states_count_mismatch").
var code: String = ""
## Human-readable detail, e.g. "expected 4 unit_states, got 3".
var detail: String = ""
## Optional stable reference (e.g. "definition_id" or board index).
var context: String = ""


static func info(code: String, detail: String, context: String = "") -> RefCounted:
	var d: RefCounted = MigrationDiagnostic.new()
	d.severity = Severity.INFO
	d.code = code
	d.detail = detail
	d.context = context
	return d


static func warning(code: String, detail: String, context: String = "") -> RefCounted:
	var d: RefCounted = MigrationDiagnostic.new()
	d.severity = Severity.WARNING
	d.code = code
	d.detail = detail
	d.context = context
	return d


static func error(code: String, detail: String, context: String = "") -> RefCounted:
	var d: RefCounted = MigrationDiagnostic.new()
	d.severity = Severity.ERROR
	d.code = code
	d.detail = detail
	d.context = context
	return d


func to_dict() -> Dictionary:
	## Canonical diagnostic encoding with a fixed key order.
	return {
		"severity": _severity_name(severity),
		"code": code,
		"detail": detail,
		"context": context,
	}


static func _severity_name(s: int) -> String:
	match s:
		Severity.INFO: return "info"
		Severity.WARNING: return "warning"
		Severity.ERROR: return "error"
		_: return "unknown"
