class_name RunSaveRepository extends RefCounted
## Production save repository for the v4 run schema. Handles format
## detection, in-memory legacy migration, crash-recoverable commit,
## and immutable legacy backup. Does not depend on Godot autoloads.
##
## The repository is decoupled from `RunController`. The migration
## orchestration is here, not in the controller.
##
## The commit protocol is a single deterministic "crash-recoverable
## same-directory commit":
##   - load_run() and save_run() both call _recover_startup_state()
##     before doing anything else.
##   - After successful recovery, commit-old MUST NOT exist when a
##     new commit begins.
##   - The swap is the only commit path: target -> commit-old, then
##     temp -> target, with rollback on every step.
##   - On a fresh save (no target), the swap collapses to a single
##     rename. There is no previous generation to preserve.

const SaveSchemaV4Script = preload("res://core/save/save_schema_v4.gd")
const SaveSchemaV5Script = preload("res://core/save/save_schema_v5.gd")
const RunDomainSemanticValidatorScript = preload("res://core/save/run_domain_semantic_validator.gd")
const MigratorScript = preload("res://core/save/legacy_save_v1_to_v4_migrator.gd")
const SaveLoadResultScript = preload("res://core/save/save_load_result.gd")
const MigrationDiagnosticScript = preload("res://core/save/migration_diagnostic.gd")
const ProductionFileOps = preload("res://core/save/run_save_file_ops.gd")

const SCHEMA_V4: int = SaveSchemaV4Script.SCHEMA_VERSION
const SCHEMA_V5: int = SaveSchemaV5Script.SCHEMA_VERSION
const SCHEMA_MARKER: String = "# v4 save"
const SCHEMA_MARKER_V5: String = "# v5 save"
const BACKUP_SUFFIX: String = ".legacy-v1.bak"
const COMMIT_OLD_SUFFIX: String = ".commit-old"
const TEMP_SUFFIX: String = ".tmp"
const V4_TEMP_SUFFIX: String = ".v4.tmp"
const BACKUP_TEMP_SUFFIX: String = ".bak.tmp"

const INTEGER_FIELDS: Array[StringName] = [
	&"schema_version", &"seed", &"round_index", &"gold",
	&"next_unit_instance_seq", &"next_item_instance_seq",
	&"wins", &"losses", &"units_killed", &"lives",
	&"xp", &"level", &"current_encounter_id",
]

const UNIT_INTEGER_FIELDS: Array[StringName] = [
	&"current_hp", &"max_hp", &"bonus_attack", &"location", &"order",
]


## Construct a repository bound to a specific directory and the
## filename pattern `run_<seed>.tres`. The base directory is
## normally `user://saves/runs/`, but tests pass an isolated temp
## directory to avoid touching the user's data.
##
## When the optional `p_ops` argument is supplied, that adapter is
## used for every filesystem call; otherwise the production adapter
## is instantiated.
func _init(p_runs_dir: String, p_ops: Variant = null) -> void:
	runs_dir = p_runs_dir
	_save_count = 0
	_load_count = 0
	_migration_count = 0
	if p_ops == null:
		_ops = ProductionFileOps.new()
	else:
		_ops = p_ops

var runs_dir: String = ""
var _save_count: int = 0
var _load_count: int = 0
var _migration_count: int = 0
var _ops: RefCounted = null


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
	var target: String = _run_path(seed_value)
	var rec: Dictionary = _recover_startup_state(target, seed_value)
	if not rec.ok:
		return _error(rec.error_code, "unknown", rec.detail)
	if not _ops.exists(target):
		# Recovery said OK but there is nothing to read.
		return _error(SaveLoadResultScript.ERROR_V4_LOAD_FAILED, "missing",
			"save file not found after recovery: %s" % target)
	var text: PackedByteArray = _ops.read_bytes(target)
	if text.is_empty():
		return _error(SaveLoadResultScript.ERROR_V4_LOAD_FAILED, "unknown",
			"save file is empty: %s" % target)
	var detect: Dictionary = _detect_format(text)
	match detect.format:
		"v4":
			var parsed: Dictionary = detect.parsed
			# Wire-normalize parsed JSON into canonical GDScript types
			# BEFORE validate_shape runs. validate_shape() asserts
			# canonical types.
			var normalized: Dictionary = _normalize_wire(parsed)
			if normalized.is_empty():
				return _error(SaveLoadResultScript.ERROR_CORRUPT_V4, "corrupt_v4",
					"wire normalization failed: %s" % str(detect))
			return _load_v4_canonical(normalized, target, seed_value)
		"v5":
			var parsed_v5: Dictionary = detect.parsed
			var normalized_v5: Dictionary = _normalize_wire_v5(parsed_v5)
			if normalized_v5.is_empty():
				return _error(SaveLoadResultScript.ERROR_CORRUPT_V4, "corrupt_v5",
					"wire normalization failed: %s" % str(detect))
			return _load_v5_canonical(normalized_v5, target, seed_value)
		"corrupt_v5":
			return _error(SaveLoadResultScript.ERROR_CORRUPT_V4, "corrupt_v5",
				"corrupt v5: %s" % str(detect))
		"corrupt_v4":
			return _error(SaveLoadResultScript.ERROR_CORRUPT_V4, "corrupt_v4",
				"corrupt v4: %s" % str(detect))
		"unsupported_schema":
			return _error(SaveLoadResultScript.ERROR_UNSUPPORTED_SCHEMA, "unsupported_schema",
				"unsupported schema version: %s" % str(detect))
		"legacy_v1_candidate":
			return _load_legacy_and_migrate(target, seed_value)
		_:
			return _error(SaveLoadResultScript.ERROR_UNKNOWN_FORMAT, "unknown",
				"unknown format")


## Persist a v4 DTO atomically. Returns OK on success, ERROR_* on
## failure. After successful recovery, commit-old MUST NOT exist.
## The previous generation is preserved on disk under commit-old
## until the new generation has been post-validated.
func save_run(seed_value: int, v4_data: Dictionary) -> RefCounted:
	return _save_canonical(seed_value, v4_data, "v4")


## Persists a canonical v5 checkpoint DTO atomically.
##
## The v5 path reuses the SAME hardened mechanism as the v4 path: the
## temp write, the temp verification, the atomic commit swap and the
## post-commit validation are the same code. Only the shape
## validation and the file marker differ.
func save_run_v5(seed_value: int, v5_data: Dictionary) -> RefCounted:
	return _save_canonical(seed_value, v5_data, "v5")


## The shared atomic save path for both schema versions.
func _save_canonical(seed_value: int, data: Dictionary, format: String) -> RefCounted:
	_save_count += 1
	var target: String = _run_path(seed_value)
	var rec: Dictionary = _recover_startup_state(target, seed_value)
	if not rec.ok:
		return _error(rec.error_code, "unknown", rec.detail)
	var seed_pre: RefCounted = _validate_seed_consistency(seed_value, data)
	if seed_pre.is_error():
		return seed_pre
	if format == "v5":
		var shape_v5: Dictionary = SaveSchemaV5Script.validate_shape(data)
		if not bool(shape_v5.get("success", false)):
			var r5: RefCounted = _error(
				SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED, "v5",
				"v5 DTO failed validation before write")
			for d in shape_v5.get("diagnostics", []):
				r5.add_diagnostic(d)
			return r5
		# The semantic gate runs BEFORE the write, exactly like the v4
		# branch. Without it the gate would fire only in
		# _post_commit_validate, i.e. AFTER the atomic swap: on a fresh
		# slot the invalid file would stay on disk under the target and
		# the slot would become unrecoverable.
		var semantic_v5: Dictionary = RunDomainSemanticValidatorScript.validate(data)
		if not bool(semantic_v5.get("success", false)):
			var rs5: RefCounted = _error(
				SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED, "v5",
				"v5 DTO failed the semantic validation before write")
			for d in semantic_v5.get("diagnostics", []):
				rs5.add_diagnostic(d)
			return rs5
	else:
		var v: Dictionary = MigratorScript.validate(data)
		if not bool(v.get("success", false)):
			var r: RefCounted = _error(SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED, "v4",
				"v4 DTO failed validation before write")
			for d in v.get("diagnostics", []):
				r.add_diagnostic(d)
			return r
	var temp: String = target + TEMP_SUFFIX
	var bytes: PackedByteArray = serialize_canonical_bytes(data)
	if not _ops.write_bytes_and_flush(temp, bytes):
		return _error(SaveLoadResultScript.ERROR_TEMP_WRITE_FAILED, format,
			"failed to write temp %s file: %s" % [format, temp])
	if not _verify_temp(temp, bytes):
		_safe_remove(temp)
		return _error(SaveLoadResultScript.ERROR_TEMP_WRITE_FAILED, format,
			"temp %s file failed verification after write" % format)
	if not _commit_verified_temp(temp, target, seed_value):
		return _error(SaveLoadResultScript.ERROR_ATOMIC_REPLACE_FAILED, format,
			"commit swap failed: %s" % target)
	var ok: RefCounted = SaveLoadResultScript.ok()
	ok.source_format = format
	ok.source_path = target
	ok.data = data.duplicate(true)
	return ok


## Backup policy: the legacy backup is created exactly once per
## run file. An existing legacy-v1 backup is never overwritten.
## The repository never auto-repairs or auto-overwrites an immutable
## legacy backup.
func ensure_legacy_backup(legacy_path: String) -> int:
	# Three statuses: BACKUP_OK / BACKUP_INVALID / BACKUP_CONFLICT.
	const BACKUP_OK: int = 0
	const BACKUP_INVALID: int = 1
	const BACKUP_CONFLICT: int = 2
	var backup_path: String = legacy_path + BACKUP_SUFFIX
	if not _ops.exists(backup_path):
		return _create_backup(legacy_path, backup_path)
	return _verify_existing_backup(legacy_path, backup_path)


# ---------------------------------------------------------------------------
# Wire format (single canonical helper)
# ---------------------------------------------------------------------------

## Serializes a canonical DTO to its on-disk byte form.
##
## The marker follows the schema version of the DTO, so a v5
## checkpoint is written with the v5 marker and is detected as v5.
##
## The serialization is BYTE-STABLE: the top-level keys are emitted in
## the canonical schema order, and the nested keys are emitted in
## sorted order. Two semantically identical checkpoints therefore
## serialize identically — the bytes never depend on the Dictionary
## iteration order, the filesystem listing order or an object
## identity.
static func serialize_canonical_bytes(data: Dictionary) -> PackedByteArray:
	# The top-level keys are emitted in the canonical schema order, so
	# the bytes never depend on the Dictionary insertion order.
	var ordered: Dictionary = {}
	for key in canonical_top_level_keys(data):
		ordered[key] = data[key]
	# The map snapshot is canonicalized: the node list is emitted in
	# ascending id order, so the bytes never depend on the insertion
	# order of the nodes.
	if ordered.has("map"):
		ordered["map"] = _canonicalize_map_snapshot(ordered["map"])
	# The NESTED dictionaries are emitted with sorted keys. The top
	# level keeps the schema order, so the nested pass must not touch
	# it.
	var safe: Variant = _to_json_safe_nested(ordered, 0)
	var body: String = JSON.stringify(safe, "", true)
	return (schema_marker_for(data) + "\n" + body).to_utf8_buffer()


## The canonical key order of a top-level DTO.
##
## The schema order is used for a canonical DTO; for anything else the
## keys are sorted, so the bytes stay deterministic.
static func canonical_top_level_keys(data: Dictionary) -> Array:
	var order: Array = []
	if int(data.get("schema_version", 0)) == SCHEMA_V5:
		order = SaveSchemaV5Script.TOP_LEVEL_KEYS
	else:
		order = SaveSchemaV4Script.TOP_LEVEL_KEYS
	var out: Array = []
	for key in order:
		if data.has(key):
			out.append(key)
	# Any key the schema does not know about is appended in sorted
	# order, so an extension cannot break the determinism.
	var extra: Array = []
	for key in data.keys():
		if not (key in out):
			extra.append(key)
	extra.sort()
	for key in extra:
		out.append(key)
	return out


## The file marker of a canonical DTO.
static func schema_marker_for(data: Dictionary) -> String:
	if int(data.get("schema_version", 0)) == SCHEMA_V5:
		return SCHEMA_MARKER_V5
	return SCHEMA_MARKER


static func _to_json_safe(value: Variant) -> Variant:
	return _to_json_safe_nested(value, 1)


## Converts a value into its JSON-safe form.
##
## A nested dictionary is emitted with SORTED keys, so its bytes never
## depend on its insertion order. The top level is exempt: it keeps the
## canonical schema order, which is emitted by the caller.
static func _to_json_safe_nested(value: Variant, depth: int) -> Variant:
	if value is Array:
		var out: Array = []
		for v in value:
			out.append(_to_json_safe_nested(v, depth + 1))
		return out
	if value is Dictionary:
		var d: Dictionary = {}
		var keys: Array = value.keys()
		# The top level (depth 0) keeps the canonical schema order; every
		# nested dictionary uses the sorted order.
		if depth > 0:
			keys.sort()
		for k in keys:
			d[String(k)] = _to_json_safe_nested(value[k], depth + 1)
		return d
	return value


## Canonicalizes the map snapshot before it is serialized.
##
## The node list is emitted in ascending id order and every id list is
## sorted, so two graphs that differ only in their insertion order
## produce the same bytes.
static func _canonicalize_map_snapshot(value: Variant) -> Variant:
	if not (value is Dictionary):
		return value
	var source: Dictionary = value
	# An EMPTY map snapshot means "no map was captured". It must stay
	# empty: a partially filled snapshot would look like a map with a
	# missing field and the restore would reject it.
	if source.is_empty():
		return {} as Dictionary
	var out: Dictionary = {}
	for key in source.keys():
		if key != "nodes":
			out[key] = source[key]
	var raw_nodes: Variant = source.get("nodes", [])
	if not (raw_nodes is Array):
		out["nodes"] = []
		return out
	var nodes: Array = []
	for entry in raw_nodes as Array:
		if not (entry is Dictionary):
			continue
		var d: Dictionary = entry
		nodes.append({
			"id": int(d.get("id", -1)),
			"type": int(d.get("type", 0)),
			"depth": int(d.get("depth", 0)),
			"parent_ids": _sorted_ints(d.get("parent_ids", [])),
			"child_ids": _sorted_ints(d.get("child_ids", [])),
			"visited": bool(d.get("visited", false)),
			"available": bool(d.get("available", false)),
		})
	nodes.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["id"]) < int((b as Dictionary)["id"]))
	out["nodes"] = nodes
	return out


## Returns a sorted Array of ints.
static func _sorted_ints(source: Variant) -> Array:
	var out: Array = []
	if not (source is Array):
		return out
	for v in source as Array:
		out.append(int(v))
	out.sort()
	return out


# ---------------------------------------------------------------------------
# Wire normalization
# ---------------------------------------------------------------------------

## Wire-normalises a JSON-parsed v5 checkpoint.
##
## The keys are emitted in the canonical schema order, so the
## normalised Dictionary is byte-stable for the same checkpoint. The
## integer fields are coerced back from the JSON floats.
static func _normalize_wire_v5(parsed: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in SaveSchemaV5Script.TOP_LEVEL_KEYS:
		if parsed.has(key):
			out[key] = parsed[key]
	for key in SaveSchemaV5Script.INTEGER_FIELDS:
		if out.has(key):
			var r: Dictionary = SaveSchemaV5Script._wire_int(out[key])
			if not r.ok:
				return {}
			out[key] = r.value
	# The PRNG machine state is a lossless decimal string, NOT a JSON
	# number: a double cannot hold the low bits of a 64-bit state.
	if out.has("rng"):
		var rng_value: Variant = out["rng"]
		if not (rng_value is Dictionary):
			return {}
		var rng_out: Dictionary = rng_value as Dictionary
		if rng_out.has("state"):
			var raw_state: Variant = rng_out["state"]
			var decoded_state: Dictionary = SaveSchemaV5Script.decode_int64(raw_state)
			if not bool(decoded_state.get("ok", false)):
				return {}
			rng_out["state"] = SaveSchemaV5Script.encode_int64(
				int(decoded_state.get("value", 0)))
		out["rng"] = rng_out
	# The nested unit integers must be coerced back from the JSON
	# floats, exactly like the v4 normalizer does. Without this the
	# canonical DTO would carry floats in the unit fields, and the
	# strict semantic gate would reject a LEGITIMATE checkpoint.
	if out.has("units"):
		var units_value: Variant = out["units"]
		if not (units_value is Array):
			return {}
		var normalized_units: Array = []
		for u in units_value:
			if not (u is Dictionary):
				return {}
			var nu: Dictionary = (u as Dictionary).duplicate()
			for k in UNIT_INTEGER_FIELDS:
				if nu.has(k):
					var r2: Dictionary = SaveSchemaV5Script._wire_int(nu[k])
					if not bool(r2.get("ok", false)):
						return {}
					nu[k] = r2.get("value", 0)
			normalized_units.append(nu)
		out["units"] = normalized_units
	if out.has("encounter_visited_ids"):
		var ids: Variant = out["encounter_visited_ids"]
		if not (ids is Array):
			return {}
		var normalized_ids: Array = []
		for v in (ids as Array):
			var r3: Dictionary = SaveSchemaV5Script._wire_int(v)
			if not bool(r3.get("ok", false)):
				return {}
			normalized_ids.append(r3.get("value", 0))
		out["encounter_visited_ids"] = normalized_ids
	return out


static func _normalize_wire_static(parsed: Dictionary) -> Dictionary:
	# Wire-normalise a JSON-parsed Dictionary. JSON.parse_string
	# returns integral numbers as floats; we coerce integral floats
	# back to ints and reject the rest. See _normalize_wire for the
	# legacy instance-method form which delegates here.
	var out: Dictionary = parsed.duplicate(true)
	for key in SaveSchemaV4Script.TOP_LEVEL_KEYS:
		if parsed.has(key):
			out[key] = parsed[key]
	for key in INTEGER_FIELDS:
		if out.has(key):
			var r: Dictionary = SaveSchemaV4Script._wire_int(out[key])
			if not r.ok:
				return {}
			out[key] = r.value
	if out.has("units"):
		var units_value: Variant = out["units"]
		if not (units_value is Array):
			return {}
		var normalized_units: Array = []
		for u in units_value:
			if not (u is Dictionary):
				return {}
			var nu: Dictionary = (u as Dictionary).duplicate()
			for k in UNIT_INTEGER_FIELDS:
				if nu.has(k):
					var r2: Dictionary = SaveSchemaV4Script._wire_int(nu[k])
					if not r2.ok:
						return {}
					nu[k] = r2.value
			normalized_units.append(nu)
		out["units"] = normalized_units
	if out.has("encounter_visited_ids"):
		var ids: Variant = out["encounter_visited_ids"]
		if not (ids is Array):
			return {}
		var normalized_ids: Array = []
		for v in (ids as Array):
			var r3: Dictionary = SaveSchemaV4Script._wire_int(v)
			if not r3.ok:
				return {}
			normalized_ids.append(r3.value)
		out["encounter_visited_ids"] = normalized_ids
	return out


func _normalize_wire(parsed: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in SaveSchemaV4Script.TOP_LEVEL_KEYS:
		if parsed.has(key):
			out[key] = parsed[key]
	for key in INTEGER_FIELDS:
		if out.has(key):
			var r: Dictionary = SaveSchemaV4Script._wire_int(out[key])
			if not r.ok:
				return {}
			out[key] = r.value
	if out.has("units"):
		var units_value: Variant = out["units"]
		if not (units_value is Array):
			return {}
		var normalized_units: Array = []
		for u in units_value:
			if not (u is Dictionary):
				return {}
			var nu: Dictionary = (u as Dictionary).duplicate()
			for k in UNIT_INTEGER_FIELDS:
				if nu.has(k):
					var r2: Dictionary = SaveSchemaV4Script._wire_int(nu[k])
					if not r2.ok:
						return {}
					nu[k] = r2.value
			normalized_units.append(nu)
		out["units"] = normalized_units
	if out.has("encounter_visited_ids"):
		var ids: Variant = out["encounter_visited_ids"]
		if not (ids is Array):
			return {}
		var normalized_ids: Array = []
		for v in (ids as Array):
			var r3: Dictionary = SaveSchemaV4Script._wire_int(v)
			if not r3.ok:
				return {}
			normalized_ids.append(r3.value)
		out["encounter_visited_ids"] = normalized_ids
	# Opaque dictionaries (shop, map, rewards, meta_modifiers) are not
	# numeric-domain normalized.
	return out


# ---------------------------------------------------------------------------
# Format detection (wire-aware schema_version)
# ---------------------------------------------------------------------------

func _detect_format(text: PackedByteArray) -> Dictionary:
	var s: String = text.get_string_from_utf8()
	if s.begins_with(SCHEMA_MARKER_V5):
		return _detect_canonical(s, SCHEMA_MARKER_V5, "v5")
	if not s.begins_with(SCHEMA_MARKER):
		if s.begins_with("[gd_resource") and _has_legacy_v1_structural_keys(s):
			return {"format": "legacy_v1_candidate"}
		return {"format": "unknown"}
	return _detect_canonical(s, SCHEMA_MARKER, "v4")


## Parses the body of a canonical save file and identifies its schema.
##
## `format` is the expected schema family ("v4" or "v5"); a file
## whose schema_version does not match the marker is reported as
## unsupported, exactly like before.
func _detect_canonical(s: String, marker: String, format: String) -> Dictionary:
	var nl: int = s.find("\n")
	var body: String = s.substr(nl + 1, s.length() - (nl + 1))
	var parsed: Variant = JSON.parse_string(body)
	if not (parsed is Dictionary):
		return {"format": "corrupt_" + format, "reason": "bad_json"}
	if not parsed.has("schema_version"):
		return {"format": "corrupt_" + format, "reason": "missing_schema_version"}
	var raw_schema: Variant = parsed["schema_version"]
	var schema_result: Dictionary = SaveSchemaV4Script._wire_int(raw_schema)
	if not schema_result.ok:
		return {"format": "corrupt_" + format, "reason": "schema_version_invalid_wire_type"}
	var schema: int = schema_result.value
	var expected: int = SCHEMA_V4 if format == "v4" else SCHEMA_V5
	if schema != expected:
		return {"format": "unsupported_schema", "schema_version": schema}
	return {"format": format, "parsed": parsed}


## Generic tres / legacy line parser. Splits the bytes by newline
## (with allow_empty=false so trailing CR/LF doesn't produce a
## spurious blank line), then for each line looks for an exact
## "key = value" pair. Returns {ok: bool, value: int} so callers
## can compare against an expected integer without substring traps.
## "seed = 9001" must NOT match expected_seed = 90010; the parser
## reads the integer to the first non-digit, ignoring trailing
## digits that follow a non-digit character.
static func _legacy_int_field(s: String, key: String) -> Dictionary:
	for line in s.split("\n", false):
		var stripped: String = line.strip_edges()
		var eq: int = stripped.find("=")
		if eq < 0:
			continue
		if stripped.substr(0, eq).strip_edges() != key:
			continue
		var raw: String = stripped.substr(eq + 1).strip_edges()
		if not raw.is_valid_int():
			return {"ok": false}
		return {"ok": true, "value": int(raw)}
	return {"ok": false}


static func _legacy_has_field(s: String, key: String) -> bool:
	for line in s.split("\n", false):
		var stripped: String = line.strip_edges()
		var eq: int = stripped.find("=")
		if eq < 0:
			continue
		if stripped.substr(0, eq).strip_edges() == key:
			return true
	return false


static func _has_legacy_v1_structural_keys(s: String) -> bool:
	# A tres is a legacy v1 candidate iff:
	#   - begins with [gd_resource
	#   - contains required structural keys
	#   - has exact version = 1 (TYPE_INT, not the substring "version = 10")
	#   - has NO schema_version key
	if not s.begins_with("[gd_resource"):
		return false
	for key in ["player_unit_ids", "unit_states"]:
		if not _legacy_has_field(s, key):
			return false
	var v: Dictionary = _legacy_int_field(s, "version")
	if not bool(v.get("ok", false)) or int(v.get("value", -1)) != 1:
		return false
	if _legacy_has_field(s, "schema_version"):
		return false
	return true


# ---------------------------------------------------------------------------
# v4 load (post-normalization)
# ---------------------------------------------------------------------------

func _load_v4_canonical(parsed: Dictionary, path: String, seed_value: int) -> RefCounted:
	# Seed/run_id consistency check.
	if int(parsed.get("seed", -2)) != seed_value:
		return _error(SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED, "v4",
			"v4 file seed does not match expected seed: file=%s expected=%d" % [parsed.get("seed"), seed_value])
	var expected_run_id: String = "run_%d" % seed_value
	if String(parsed.get("run_id", "")) != expected_run_id:
		return _error(SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED, "v4",
			"v4 file run_id does not match: file=%s expected=%s" % [parsed.get("run_id"), expected_run_id])
	var v: Dictionary = MigratorScript.validate(parsed)
	if not bool(v.get("success", false)):
		var r: RefCounted = _error(SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED, "v4",
			"v4 file failed validation")
		for d in v.get("diagnostics", []):
			r.add_diagnostic(d)
		return r
	var ok: RefCounted = SaveLoadResultScript.ok()
	ok.source_format = "v4"
	ok.source_path = path
	ok.data = parsed.duplicate(true)
	return ok


## Loads and validates a canonical v5 checkpoint.
##
## The v5 path mirrors the v4 path exactly: the seed / run_id
## consistency check and the shape validation happen BEFORE the data
## is handed out, and a failure never returns partial data.
func _load_v5_canonical(parsed: Dictionary, path: String, seed_value: int) -> RefCounted:
	if int(parsed.get("seed", -2)) != seed_value:
		return _error(SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED, "v5",
			"v5 file seed does not match expected seed: file=%s expected=%d" % [parsed.get("seed"), seed_value])
	var expected_run_id: String = "run_%d" % seed_value
	if String(parsed.get("run_id", "")) != expected_run_id:
		return _error(SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED, "v5",
			"v5 file run_id does not match: file=%s expected=%s" % [parsed.get("run_id"), expected_run_id])
	var shape: Dictionary = SaveSchemaV5Script.validate_shape(parsed)
	if not bool(shape.get("success", false)):
		var r: RefCounted = _error(SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED, "v5",
			"v5 file failed validation")
		for d in shape.get("diagnostics", []):
			r.add_diagnostic(d)
		return r
	# The semantic gate runs here too, exactly like on the v4 load
	# path. The repository must not hand out a semantically invalid
	# checkpoint as a valid, loadable save: the mapper gates as a
	# backstop, but every other caller of the public facade would get
	# an unchecked DTO.
	var semantic: Dictionary = RunDomainSemanticValidatorScript.validate(parsed)
	if not bool(semantic.get("success", false)):
		var rs: RefCounted = _error(SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED, "v5",
			"v5 file failed the semantic validation")
		for d in semantic.get("diagnostics", []):
			rs.add_diagnostic(d)
		return rs
	var ok: RefCounted = SaveLoadResultScript.ok()
	ok.source_format = "v5"
	ok.source_path = path
	ok.data = parsed.duplicate(true)
	return ok


# ---------------------------------------------------------------------------
# Legacy v1 load + migrate
# ---------------------------------------------------------------------------

func _load_legacy_and_migrate(legacy_path: String, seed_value: int) -> RefCounted:
	# Step 1: capture bytes before load(); the production loader must
	# not mutate the on-disk legacy file.
	var legacy_bytes_before: PackedByteArray = _ops.read_bytes(legacy_path)
	var legacy_res: Resource = load(legacy_path)
	if legacy_res == null:
		return _error(SaveLoadResultScript.ERROR_LEGACY_LOAD_FAILED, "legacy_v1",
			"failed to load legacy resource: %s" % legacy_path)
	var legacy_bytes_after: PackedByteArray = _ops.read_bytes(legacy_path)
	if legacy_bytes_before != legacy_bytes_after:
		return _error(SaveLoadResultScript.ERROR_CORRUPT_INPUT, "legacy_v1",
			"legacy loader mutated the file; refusing to migrate")
	var mig: Dictionary = MigratorScript.migrate_run(legacy_res)
	if not bool(mig.get("success", false)):
		var r3: RefCounted = _error(SaveLoadResultScript.ERROR_LEGACY_MIGRATION_FAILED, "legacy_v1",
			"migrator returned failure")
		for d in mig.get("diagnostics", []):
			r3.add_diagnostic(d)
		return r3
	var v4_data: Dictionary = mig.get("data", {})
	var v: Dictionary = MigratorScript.validate(v4_data)
	if not bool(v.get("success", false)):
		var r4: RefCounted = _error(SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED, "legacy_v1",
			"migrated v4 DTO failed validation")
		for d in v.get("diagnostics", []):
			r4.add_diagnostic(d)
		return r4
	# Write v4 temp, re-read and re-validate, then ensure backup,
	# then commit swap.
	var v4_temp: String = legacy_path + V4_TEMP_SUFFIX
	var v4_bytes: PackedByteArray = serialize_canonical_bytes(v4_data)
	if not _ops.write_bytes_and_flush(v4_temp, v4_bytes):
		return _error(SaveLoadResultScript.ERROR_TEMP_WRITE_FAILED, "legacy_v1",
			"failed to write v4 temp: %s" % v4_temp)
	var reloaded: Dictionary = _read_dict_text(v4_temp)
	if reloaded.is_empty():
		return _error(SaveLoadResultScript.ERROR_TEMP_RELOAD_FAILED, "legacy_v1",
			"failed to re-read v4 temp: %s" % v4_temp)
	var normalized: Dictionary = _normalize_wire(reloaded)
	if normalized.is_empty():
		return _error(SaveLoadResultScript.ERROR_TEMP_VALIDATION_FAILED, "legacy_v1",
			"re-read v4 temp failed wire normalization")
	var tv: Dictionary = MigratorScript.validate(normalized)
	if not bool(tv.get("success", false)):
		return _error(SaveLoadResultScript.ERROR_TEMP_VALIDATION_FAILED, "legacy_v1",
			"re-read v4 temp failed validation")
	# Immutable legacy backup (always; even on commit failure later
	# the legacy bytes are preserved on disk).
	var backup_status: int = ensure_legacy_backup(legacy_path)
	if backup_status != 0:  # BACKUP_OK == 0
		var code: int = SaveLoadResultScript.ERROR_BACKUP_INVALID
		if backup_status == 2:
			code = SaveLoadResultScript.ERROR_BACKUP_CONFLICT
		return _error(code, "legacy_v1",
			"legacy backup status: %d" % backup_status)
	var backup_path: String = legacy_path + BACKUP_SUFFIX
	# Commit swap: legacy -> commit-old, then v4 temp -> target.
	if not _commit_verified_temp(v4_temp, legacy_path, seed_value):
		_safe_remove(v4_temp)
		return _error(SaveLoadResultScript.ERROR_ATOMIC_REPLACE_FAILED, "legacy_v1",
			"commit swap failed during legacy migration")
	# After successful commit, no commit-old or v4-temp remains.
	var _migration_count_local: int = _migration_count
	_migration_count_local += 1
	_migration_count = _migration_count_local
	var ok: RefCounted = SaveLoadResultScript.ok()
	ok.source_format = "v4"
	ok.source_path = legacy_path
	ok.migrated = true
	ok.backup_path = backup_path
	ok.data = normalized.duplicate(true)
	for d in mig.get("diagnostics", []):
		ok.add_diagnostic(d)
	return ok


# ---------------------------------------------------------------------------
# Backup protocol
# ---------------------------------------------------------------------------

func _create_backup(legacy_path: String, backup_path: String) -> int:
	var tmp: String = backup_path + BACKUP_TEMP_SUFFIX
	var bytes: PackedByteArray = _ops.read_bytes(legacy_path)
	if bytes.is_empty():
		return 1  # BACKUP_INVALID
	if not _ops.write_bytes_and_flush(tmp, bytes):
		return 1
	if _ops.sha256(tmp) != _ops.sha256(legacy_path):
		_safe_remove(tmp)
		return 1
	if not _ops.rename(tmp, backup_path):
		return 1
	return _post_create_verify_backup(legacy_path, backup_path)


func _post_create_verify_backup(legacy_path: String, backup_path: String) -> int:
	var source_sha: String = _ops.sha256(legacy_path)
	var backup_sha: String = _ops.sha256(backup_path)
	if source_sha == "" or backup_sha == "":
		_safe_remove(backup_path)
		return 1
	if source_sha != backup_sha:
		_safe_remove(backup_path)
		return 1
	if not _is_structurally_valid_legacy_v1(backup_path):
		_safe_remove(backup_path)
		return 1
	return 0


func _verify_existing_backup(legacy_path: String, backup_path: String) -> int:
	var backup_sha: String = _ops.sha256(backup_path)
	if backup_sha == "":
		return 1
	var source_sha: String = _ops.sha256(legacy_path)
	if source_sha == "":
		return 1
	if not _is_structurally_valid_legacy_v1(backup_path):
		return 1
	if backup_sha != source_sha:
		return 2  # BACKUP_CONFLICT
	return 0  # BACKUP_OK


## Structural validation for legacy backup paths (`.bak`). Reads
## raw bytes; does not rely on ResourceLoader accepting `.bak`. The
## rules are exactly the detector's rules: a tres is structurally
## valid legacy v1 iff it has [gd_resource], required keys,
## exact version = 1, and no schema_version. One parser, three
## callers.
func _is_structurally_valid_legacy_v1(path: String) -> bool:
	var bytes: PackedByteArray = _ops.read_bytes(path)
	if bytes.is_empty():
		return false
	var s: String = bytes.get_string_from_utf8()
	return _has_legacy_v1_structural_keys(s)


# ---------------------------------------------------------------------------
# Recovery state machine (single entry, used by both load and save)
# ---------------------------------------------------------------------------

func _recover_startup_state(target: String, expected_seed: int) -> Dictionary:
	var commit_old: String = target + COMMIT_OLD_SUFFIX
	var target_present: bool = _ops.exists(target)
	var commit_old_present: bool = _ops.exists(commit_old)

	# 1) target missing + valid commit-old -> restore.
	if not target_present and commit_old_present:
		var v1: Dictionary = _is_valid_recoverable_run(commit_old, expected_seed)
		if v1.valid:
			if not _ops.rename(commit_old, target):
				return {"ok": false, "error_code": SaveLoadResultScript.ERROR_IO,
						"detail": "failed to restore commit-old"}
			return {"ok": true}
		return {"ok": false, "error_code": SaveLoadResultScript.ERROR_BACKUP_INVALID,
				"detail": "stale commit-old is unrecoverable"}

	# 2) target valid + commit-old exists -> target authoritative, remove stale.
	if target_present and commit_old_present:
		var v_target: Dictionary = _is_valid_recoverable_run(target, expected_seed)
		if v_target.valid:
			# The postcondition "commit-old MUST NOT exist" requires a
			# successful remove. If remove fails, do not report a
			# successful recovery.
			if not _ops.remove(commit_old):
				return {"ok": false, "error_code": SaveLoadResultScript.ERROR_IO,
						"detail": "failed to remove stale commit-old"}
			return {"ok": true}
		var v_commit: Dictionary = _is_valid_recoverable_run(commit_old, expected_seed)
		if v_commit.valid:
			# Preserve invalid target for diagnostics.
			var stamp: int = Time.get_ticks_msec()
			var invalid_marker: String = "%s.invalid.%d" % [target, stamp]
			_ops.rename(target, invalid_marker)
			if not _ops.rename(commit_old, target):
				return {"ok": false, "error_code": SaveLoadResultScript.ERROR_IO,
						"detail": "failed to restore commit-old"}
			return {"ok": true}
		# both invalid -> controlled recovery error, destroy nothing.
		return {"ok": false, "error_code": SaveLoadResultScript.ERROR_CORRUPT_INPUT,
				"detail": "both target and commit-old are invalid"}

	# 3) target valid + no commit-old -> recovery says OK; format
	# detection downstream decides what to do with the bytes.
	if target_present and not commit_old_present:
		return {"ok": true}

	# 4) target missing + invalid commit-old -> controlled recovery error.
	if not target_present and commit_old_present:
		return {"ok": false, "error_code": SaveLoadResultScript.ERROR_BACKUP_INVALID,
				"detail": "stale commit-old is unrecoverable"}

	# 5) neither present -> nothing to recover; downstream returns missing.
	return {"ok": true}


func _is_valid_recoverable_run(path: String, expected_seed: int) -> Dictionary:
	var bytes: PackedByteArray = _ops.read_bytes(path)
	if bytes.is_empty():
		return {"valid": false}
	var s: String = bytes.get_string_from_utf8()
	# v4 path: run the strict gate. Recoverable means the file is
	# genuinely usable for the slot, not just shape-recognisable.
	if s.begins_with(SCHEMA_MARKER_V5):
		var parsed_v5: Variant = JSON.parse_string(
			s.substr(SCHEMA_MARKER_V5.length() + 1))
		if not (parsed_v5 is Dictionary):
			return {"valid": false, "reason": "corrupt_v5"}
		var gate_v5: Dictionary = _strictly_valid_v5(parsed_v5, expected_seed)
		if not bool(gate_v5.get("valid", false)):
			return {"valid": false, "reason": "strict_validation_failed"}
		return {"valid": true, "format": "v5"}
	if s.begins_with(SCHEMA_MARKER):
		var parsed_v: Variant = JSON.parse_string(
			s.substr(SCHEMA_MARKER.length() + 1))
		if not (parsed_v is Dictionary):
			return {"valid": false, "reason": "corrupt_v4"}
		var gate: Dictionary = _strictly_valid_v4(parsed_v, expected_seed)
		if not bool(gate.get("valid", false)):
			return {"valid": false, "reason": "strict_validation_failed"}
		return {"valid": true, "format": "v4"}
		# legacy v1 path: bytes-only structural check. ResourceLoader is
		# NOT invoked here because it caches ext-resources and can mutate
	# unrelated loads later in the same process. The legacy loader
	# performs the actual seed match at load time.
	if _is_structurally_valid_legacy_v1(path):
		# A .tres file is recoverable only if its seed line matches
		# the expected slot. A mismatched-seed legacy file is NOT
		# recoverable for that slot.
		if not _legacy_seed_matches(path, expected_seed):
			return {"valid": false, "reason": "legacy_seed_mismatch"}
		return {"valid": true, "format": "legacy_v1"}
	return {"valid": false}


## Strict gate used by both recovery and post-commit validation:
## validates that the parsed JSON Dictionary is a real, semantically
## correct v4 DTO for the slot. Returns the normalised DTO on
## success so callers don't have to repeat the work.
## Slot-aware strict gate. Validates that the parsed JSON Dictionary
## is a real, semantically correct v4 DTO for the SPECIFIC slot
## identified by expected_seed. Returns the normalised DTO on
## success. Used by both recovery and post-commit validation so
## they cannot disagree.
##
## A file is slot-valid iff:
##   - shape validation passes (SaveSchemaV4.validate_shape)
##   - semantic validation passes (Migrator.validate)
##   - schema_version seed field == expected_seed
##   - run_id field == "run_<expected_seed>"
## The strict gate for a canonical v5 checkpoint.
##
## Mirrors `_strictly_valid_v4`: shape validation, the seed match and
## the canonical run_id. Used by both recovery and post-commit
## validation, so they cannot disagree.
static func _strictly_valid_v5(parsed: Dictionary, expected_seed: int) -> Dictionary:
	var normalised: Dictionary = _normalize_wire_v5(parsed)
	var shape: Dictionary = SaveSchemaV5Script.validate_shape(normalised)
	if not bool(shape.get("success", false)):
		return {"valid": false, "reason": "shape_validation_failed",
			"diagnostics": shape.get("diagnostics", [])}
	# The SEMANTIC gate: the unit and item collections must be
	# consistent. The v4 path has always had it; the v5 path must not
	# be weaker, or a malformed checkpoint would be accepted.
	var semantic: Dictionary = RunDomainSemanticValidatorScript.validate(normalised)
	if not bool(semantic.get("success", false)):
		return {"valid": false, "reason": "semantic_validation_failed",
			"diagnostics": semantic.get("diagnostics", [])}
	var sv: int = int(normalised.get("seed", -2))
	if sv != expected_seed:
		return {"valid": false, "reason": "seed_mismatch",
			"diagnostics": [MigrationDiagnostic.error(
				"seed_mismatch",
				"v5 seed %d does not match slot seed %d" % [sv, expected_seed],
				"seed")]}
	var expected_run_id: String = "run_%d" % expected_seed
	if String(normalised.get("run_id", "")) != expected_run_id:
		return {"valid": false, "reason": "run_id_mismatch",
			"diagnostics": [MigrationDiagnostic.error(
				"run_id_mismatch",
				"v5 run_id %s does not match %s"
					% [normalised.get("run_id"), expected_run_id],
				"run_id")]}
	return {"valid": true, "dto": normalised}


static func _strictly_valid_v4(parsed: Dictionary, expected_seed: int) -> Dictionary:
	var normalised: Dictionary = _normalize_wire_static(parsed)
	var shape: Dictionary = SaveSchemaV4Script.validate_shape(normalised)
	if not bool(shape.get("success", false)):
		return {"valid": false, "reason": "shape_validation_failed",
			"diagnostics": shape.get("diagnostics", [])}
	var mig: Dictionary = MigratorScript.validate(normalised)
	if not bool(mig.get("success", false)):
		return {"valid": false, "reason": "semantic_validation_failed",
			"diagnostics": mig.get("diagnostics", [])}
	var sv: int = int(normalised.get("seed", -2))
	if sv != expected_seed:
		return {"valid": false, "reason": "seed_mismatch",
			"diagnostics": [MigrationDiagnostic.error(
				"seed_mismatch",
				"v4 seed %d does not match slot seed %d" % [sv, expected_seed],
				str(expected_seed))]}
	var expected_run_id: String = "run_%d" % expected_seed
	var actual_run_id: String = String(normalised.get("run_id", ""))
	if actual_run_id != expected_run_id:
		return {"valid": false, "reason": "run_id_mismatch",
			"diagnostics": [MigrationDiagnostic.error(
				"run_id_mismatch",
				"v4 run_id %s does not match expected %s" % [actual_run_id, expected_run_id],
				expected_run_id)]}
	return {"valid": true, "data": normalised}


## Line-aware legacy seed match. A tres file's seed line is plain
## text and can be matched without invoking ResourceLoader. The
## parser reads the integer to the first non-digit so expected
## 9001 does NOT match "seed = 90010".
func _legacy_seed_matches(path: String, expected_seed: int) -> bool:
	var bytes: PackedByteArray = _ops.read_bytes(path)
	if bytes.is_empty():
		return false
	var s: String = bytes.get_string_from_utf8()
	var v: Dictionary = _legacy_int_field(s, "seed")
	return bool(v.get("ok", false)) and int(v.get("value", -1)) == expected_seed


# ---------------------------------------------------------------------------
# Commit protocol
# ---------------------------------------------------------------------------

func _commit_verified_temp(temp: String, target: String, seed_value: int) -> bool:
	var commit_old: String = target + COMMIT_OLD_SUFFIX

	if not _ops.exists(target):
		# Fresh save: no previous generation to preserve.
		if not _ops.rename(temp, target):
			return false
		if not _post_commit_validate(target, seed_value):
			# No previous generation exists, so there is nothing to roll
			# back to: the invalid file stays on disk under the target.
			# The next load_run() surfaces the recovery error for that
			# slot.
			#
			# This is why the v5 SAVE path runs the semantic gate BEFORE
			# the write: without it the invalid bytes would reach the
			# disk first and only be rejected here, after the swap.
			return false
		return true

	# Existing save: previous generation must be preserved.
	if _ops.exists(commit_old):
		# This must be impossible after a successful recovery.
		return false
	if not _ops.rename(target, commit_old):
		return false
	if not _ops.rename(temp, target):
		_ops.rename(commit_old, target)
		return false
	if not _post_commit_validate(target, seed_value):
		var stamp: int = Time.get_ticks_msec()
		_ops.rename(target, "%s.invalid.%d" % [target, stamp])
		_ops.rename(commit_old, target)
		return false
	if _ops.exists(commit_old):
		if not _ops.remove(commit_old):
			# Do not report a clean success while the recovery
			# invariant is violated.
			return false
	return true


func _post_commit_validate(target: String, expected_seed: int) -> bool:
	# Re-read target and verify it is a valid canonical file for the
	# specific slot. The slot-aware strict gate is used (wire
	# normalisation + validate_shape + Migrator.validate + seed +
	# run_id). Anything weaker would let a syntactically valid but
	# semantically broken JSON destroy the previous generation.
	#
	# Both schema versions are accepted: the marker decides which
	# strict gate runs.
	var bytes: PackedByteArray = _ops.read_bytes(target)
	if bytes.is_empty():
		return false
	var s: String = bytes.get_string_from_utf8()
	if s.begins_with(SCHEMA_MARKER_V5):
		var parsed_v5: Variant = JSON.parse_string(
			s.substr(SCHEMA_MARKER_V5.length() + 1))
		if not (parsed_v5 is Dictionary):
			return false
		var gate_v5: Dictionary = _strictly_valid_v5(parsed_v5, expected_seed)
		return bool(gate_v5.get("valid", false))
	if not s.begins_with(SCHEMA_MARKER):
		return false
	var parsed: Variant = JSON.parse_string(
		s.substr(SCHEMA_MARKER.length() + 1))
	if not (parsed is Dictionary):
		return false
	var gate: Dictionary = _strictly_valid_v4(parsed, expected_seed)
	return bool(gate.get("valid", false))


func _verify_temp(temp: String, expected_bytes: PackedByteArray) -> bool:
	var bytes: PackedByteArray = _ops.read_bytes(temp)
	if bytes.is_empty():
		return false
	if bytes != expected_bytes:
		return false
	# Re-read also: parse as JSON header to confirm format. Both
	# canonical markers are accepted.
	var s: String = bytes.get_string_from_utf8()
	var marker: String = ""
	if s.begins_with(SCHEMA_MARKER_V5):
		marker = SCHEMA_MARKER_V5
	elif s.begins_with(SCHEMA_MARKER):
		marker = SCHEMA_MARKER
	else:
		return false
	var nl: int = s.find("\n")
	var body: String = s.substr(nl + 1, s.length() - (nl + 1))
	var parsed: Variant = JSON.parse_string(body)
	return parsed is Dictionary


# ---------------------------------------------------------------------------
# File I/O helpers
# ---------------------------------------------------------------------------

func _run_path(seed_value: int) -> String:
	return runs_dir + "run_%d.tres" % seed_value


## The number of successful writes this repository performed.
##
## It is the observable of the write COUNT: the outcome transaction
## must be ONE write, not two.
func get_save_count() -> int:
	return _save_count


## Removes the run file of a finished run.
##
## The repository owns the run files, so the removal belongs here: the
## service façade reaches the production directory, and a test that
## injects a repository over a temporary directory must be able to
## remove the file the same way.
##
## Returns true when the file is gone (including when it was not
## there).
func delete_run(seed_value: int) -> bool:
	if seed_value == 0:
		return false
	var path: String = _run_path(seed_value)
	# The WHOLE slot is removed. The `.commit-old` is the authoritative
	# generation when the target is missing -- the recovery path
	# restores it -- so leaving it behind would resurrect the deleted
	# slot on the next load. The temp file and the legacy backup
	# belong to the slot as well.
	var removed: bool = true
	for candidate in [path, path + COMMIT_OLD_SUFFIX,
			path + TEMP_SUFFIX, path + BACKUP_SUFFIX]:
		if not _ops.exists(candidate):
			continue
		if not _ops.remove(candidate):
			removed = false
	return removed


func _read_dict_text(path: String) -> Dictionary:
	# Bytes-only read. ResourceLoader is not invoked here because
	# it caches ext-resources and can mutate unrelated loads later
	# in the same process. Same file-ops seam as the rest of the
	# repository so the fault adapter can deterministically inject
	# failures here.
	var bytes: PackedByteArray = _ops.read_bytes(path)
	if bytes.is_empty():
		return {}
	var text: String = bytes.get_string_from_utf8()
	var nl: int = text.find("\n")
	if nl < 0:
		return {}
	var body: String = text.substr(nl + 1, text.length() - (nl + 1))
	if body.strip_edges() == "":
		return {}
	var parsed: Variant = JSON.parse_string(body)
	if not (parsed is Dictionary):
		return {}
	return parsed


# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------

func _validate_seed_consistency(seed_value: int, v4_data: Dictionary) -> RefCounted:
	# Pre-save consistency check: the requested seed must match the
	# DTO seed, and the run_id must be the canonical "run_<seed>"
	# derived from that seed. A mismatch is rejected BEFORE any
	# filesystem mutation. Returning a SaveLoadResult lets the
	# caller short-circuit the save_run() without touching disk.
	var sv: int = int(v4_data.get("seed", -1))
	if sv != seed_value:
		var r: RefCounted = SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED,
			"v4",
			"v4 seed %d does not match requested seed %d" % [sv, seed_value])
		r.context = "seed_consistency"
		return r
	var expected_run_id: String = "run_%d" % seed_value
	var actual_run_id: String = String(v4_data.get("run_id", ""))
	if actual_run_id != expected_run_id:
		var r2: RefCounted = SaveLoadResultScript.error_with(
			SaveLoadResultScript.ERROR_V4_VALIDATION_FAILED,
			"v4",
			"v4 run_id %s does not match expected %s" % [actual_run_id, expected_run_id])
		r2.context = "run_id_consistency"
		return r2
	return SaveLoadResultScript.ok()


func _error(code: int, source_format: String, detail: String) -> RefCounted:
	var r: RefCounted = SaveLoadResultScript.error_with(code, source_format, detail)
	r.source_path = ""
	return r


func _safe_remove(path: String) -> void:
	if _ops.exists(path):
		_ops.remove(path)
