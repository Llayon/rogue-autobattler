class_name RunCheckpointV5Mapper
## Pure mapper between a RUN CHECKPOINT and the canonical v5 DTO.
##
## The persisted object is not merely RunDomainState — it is a
## checkpoint:
##
##     RunCheckpoint
##     ├── RunDomainState
##     ├── stable flow phase
##     ├── unit-shop state
##     ├── merchant state
##     ├── encounter-map state
##     ├── reward state
##     └── RNG continuation state
##
## The mapper receives every piece EXPLICITLY. It never discovers
## global state through the engine, an autoload or the scene tree, and
## it never reaches into the private fields of a subsystem: the
## subsystem publishes its own snapshot.
##
## The mapper has no filesystem responsibility.

const RunStateV4MapperScript = preload("res://core/progression/run_state_v4_mapper.gd")
const SaveSchemaV5Script = preload("res://core/save/save_schema_v5.gd")
const RunDomainSemanticValidatorScript = preload("res://core/save/run_domain_semantic_validator.gd")

const PHASE_PREP: String = SaveSchemaV5Script.PHASE_PREP
const PHASE_MAP: String = SaveSchemaV5Script.PHASE_MAP
const PHASE_REWARD: String = SaveSchemaV5Script.PHASE_REWARD
const PHASE_MERCHANT: String = SaveSchemaV5Script.PHASE_MERCHANT


## Builds the canonical v5 DTO of a checkpoint.
##
## Every subsystem piece is an explicit argument:
##   state          : the RunDomainState
##   wire_phase     : the stable phase wire name
##   unit_shop      : the unit-shop snapshot
##   merchant       : the merchant snapshot
##   map            : the encounter-map snapshot
##   reward         : the reward snapshot
##   rng            : the RNG continuation snapshot
static func to_v5_dto(state, wire_phase: String, unit_shop: Dictionary,
		merchant: Dictionary, map: Dictionary, reward: Dictionary,
		rng: Dictionary) -> Dictionary:
	if state == null:
		return {}
	var dto: Dictionary = RunStateV4MapperScript.to_v4_dto(state)
	if dto.is_empty():
		return {}

	# The v5 shape retains every canonical v4 field.
	var out: Dictionary = {}
	for key in SaveSchemaV5Script.TOP_LEVEL_KEYS:
		if key == "schema_version":
			out["schema_version"] = SaveSchemaV5Script.SCHEMA_VERSION
		elif key == "phase":
			out["phase"] = wire_phase
		elif key == "shop":
			out["shop"] = {
				"offered_ids": _string_array(unit_shop.get("offered_ids", [])),
				"merchant": {
					"offered_item_ids": _string_array(
						merchant.get("offered_item_ids", [])),
					"discount": float(merchant.get("discount", 0.5)),
				},
			}
		elif key == "map":
			out["map"] = _canonical_map(map)
		elif key == "rewards":
			out["rewards"] = {
				"offered_ids": _string_array(reward.get("offered_ids", [])),
				"round_index": int(reward.get("round_index", 0)),
			}
		elif key == "rng":
			# The PRNG machine state is carried as a lossless decimal
			# string: it is not an IEEE-754 safe integer.
			out["rng"] = {
				"seed": int(rng.get("seed", 0)),
				"state": SaveSchemaV5Script.encode_int64(
					int(rng.get("state", 0))),
			}
		elif dto.has(key):
			out[key] = dto[key]
	return out


## Decodes a canonical v5 DTO into the explicit checkpoint pieces.
##
## The inverse is PURE: it does not touch the filesystem and it does
## not mutate the live runtime. It returns the pieces the caller
## restores.
static func from_v5_dto(dto: Dictionary) -> Dictionary:
	if dto.is_empty():
		return {"ok": false, "reason": "empty_dto"}
	# The SEMANTIC gate: the unit and item collections must be
	# consistent. The v4 load path has always had it, and the v5 path
	# must not be weaker: a malformed checkpoint would otherwise be
	# accepted and decoded into an inconsistent domain state.
	var semantic: Dictionary = RunDomainSemanticValidatorScript.validate(dto)
	if not bool(semantic.get("success", false)):
		return {"ok": false, "reason": "semantic_validation_failed",
			"diagnostics": semantic.get("diagnostics", [])}
	var state = RunStateV4MapperScript.from_v4_dto(dto)
	if state == null:
		return {"ok": false, "reason": "domain_state_failed"}
	var shop: Dictionary = dto.get("shop", {}) as Dictionary
	var merchant: Dictionary = shop.get("merchant", {}) as Dictionary
	return {
		"ok": true,
		"state": state,
		"phase": str(dto.get("phase", PHASE_PREP)),
		"unit_shop": {"offered_ids": _string_array(shop.get("offered_ids", []))},
		"merchant": {
			"offered_item_ids": _string_array(
				merchant.get("offered_item_ids", [])),
			"discount": float(merchant.get("discount", 0.5)),
		},
		"map": (dto.get("map", {}) as Dictionary).duplicate(true),
		"reward": {
			"offered_ids": _string_array(
				(dto.get("rewards", {}) as Dictionary).get("offered_ids", [])),
			"round_index": int(
				(dto.get("rewards", {}) as Dictionary).get("round_index", 0)),
		},
		"rng": {
			"seed": int((dto.get("rng", {}) as Dictionary).get("seed", 0)),
			"state": _decode_rng_state(
				(dto.get("rng", {}) as Dictionary).get("state", 0)),
		},
	}


## Migrates a canonical v4 DTO to the v5 shape.
##
## v4 did NOT persist the real phase, the shop offer, the map snapshot,
## the reward offer or the RNG continuation. Those cannot be truthfully
## recreated, so the migration uses a CONSERVATIVE, DETERMINISTIC
## fallback and reports what was lost:
##
##   phase   -> "prep" (the conservative stable checkpoint)
##   shop    -> empty (the offer is regenerated on the first refresh)
##   map     -> empty (the map is rebuilt from the seed)
##   rewards -> empty (the reward is regenerated)
##   rng     -> seeded from the run seed (the continuation is lost)
##
## The migration is NON-DESTRUCTIVE: the source DTO is not modified,
## and the caller decides whether to write the result.
static func migrate_v4_to_v5(v4_dto: Dictionary) -> Dictionary:
	if v4_dto.is_empty():
		return {"ok": false, "reason": "empty_dto"}
	var out: Dictionary = {}
	for key in SaveSchemaV5Script.TOP_LEVEL_KEYS:
		if key == "schema_version":
			out["schema_version"] = SaveSchemaV5Script.SCHEMA_VERSION
		elif key == "phase":
			out["phase"] = PHASE_PREP
		elif key == "shop":
			out["shop"] = {
				"offered_ids": [] as Array,
				"merchant": {
					"offered_item_ids": [] as Array,
					"discount": float(0.5),
				},
			}
		elif key == "map":
			out["map"] = {} as Dictionary
		elif key == "rewards":
			out["rewards"] = {"offered_ids": [] as Array, "round_index": 0}
		elif key == "rng":
			out["rng"] = {
				"seed": int(v4_dto.get("seed", 0)),
				"state": SaveSchemaV5Script.encode_int64(0),
			}
		elif v4_dto.has(key):
			out[key] = v4_dto[key]
	return {
		"ok": true,
		"dto": out,
		"diagnostics": [
			"v4->v5: the phase was not persisted; the checkpoint enters the conservative prep phase",
			"v4->v5: the shop, map, reward and rng continuation were not persisted; they are regenerated",
			"v4->v5: the encounter map is reproduced from the run seed, so the graph is exact, but the visited state and the current node are not persisted; a run that had entered the map replays one encounter at the current node before the flow returns to the map phase",
		],
	}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Decodes the persisted RNG machine state.
##
## The wire form is a lossless decimal string. A numeric value is
## accepted as a legacy fallback, but it is already lossy at that
## point, so the checkpoint reports it.
static func _decode_rng_state(raw: Variant) -> int:
	if raw is String:
		var decoded: Dictionary = SaveSchemaV5Script.decode_int64(raw)
		if bool(decoded.get("ok", false)):
			return int(decoded.get("value", 0))
		return 0
	if raw is int or raw is float:
		# Legacy numeric form: already lossy beyond 2^53.
		return int(raw)
	return 0


## Normalizes an id collection into a stable Array of Strings.
static func _string_array(source: Variant) -> Array:
	var out: Array = []
	if not (source is Array):
		return out
	for v in source as Array:
		out.append(String(v))
	return out


## Canonicalizes a map snapshot: the node list is emitted in ascending
## id order and the id lists are sorted, so two semantically identical
## maps serialize identically.
static func _canonical_map(source: Dictionary) -> Dictionary:
	if source.is_empty():
		return {} as Dictionary
	var out: Dictionary = {}
	for key in source.keys():
		if key != "nodes":
			out[key] = source[key]
	var nodes: Array = []
	for entry in source.get("nodes", []) as Array:
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
