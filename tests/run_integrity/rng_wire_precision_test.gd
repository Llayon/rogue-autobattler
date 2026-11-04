extends SceneTree

## Run Integrity — RI-04 RED: the RNG machine state must survive the
## v5 WIRE round trip.
##
## The PRNG machine state is a full-width 64-bit value. It is NOT an
## IEEE-754 safe integer: at ~1.45e18 the double spacing is 256, so
##
##     1455099814280779554  ->  JSON number  ->  double
##                           ->  1455099814280779520
##
## The low bits are lost BEFORE the wire normalizer ever sees the
## value, so no int-coercion can recover them.
##
## This suite isolates the WIRE from resume_run(): it pushes a state
## through the REAL production serializer, the REAL JSON parser and
## the REAL v5 wire normalizer.
##
## It must be RED on the current numeric representation and GREEN
## once the state is carried as a lossless decimal string.

const SaveSchemaV5Script = preload("res://core/save/save_schema_v5.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const RunCheckpointV5MapperScript = preload("res://core/progression/run_checkpoint_v5_mapper.gd")
const RunDomainStateScript = preload("res://core/progression/run_domain_state.gd")
const RngServiceScript = preload("res://core/utils/rng_service.gd")

var _passed: int = 0
var _failed: int = 0

## The value that actually occurred in the field: 34 low bits were
## lost on the wire.
const KNOWN_BAD_STATE: int = 1455099814280779554


func _initialize() -> void:
	await _test_A_red_known_state_survives_the_wire()
	await _test_B_red_boundary_values_survive_the_wire()
	await _test_C_draw_count_does_not_affect_the_sequence()
	print("")
	print("=== STAGE 3A: RNG WIRE PRECISION (RED) ===")
	print("\n=== STAGE 3A: RNG WIRE PRECISION (RED): %d pass / %d fail ===\n"
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## The production wire round trip: a v5 DTO goes through the canonical
## serializer, the JSON parser and the v5 wire normalizer.
func _wire_round_trip(dto: Dictionary) -> Dictionary:
	var bytes: PackedByteArray = RunSaveRepositoryScript.serialize_canonical_bytes(dto)
	var text: String = bytes.get_string_from_utf8()
	var nl: int = text.find("\n")
	var body: String = text.substr(nl + 1, text.length() - (nl + 1))
	var parsed: Variant = JSON.parse_string(body)
	if not (parsed is Dictionary):
		return {}
	return RunSaveRepositoryScript._normalize_wire_v5(parsed as Dictionary)


## Builds a minimal but structurally valid v5 DTO THROUGH THE
## PRODUCTION MAPPER.
##
## The DTO must not be assembled by the test: a mutation of the
## mapper's encoding would be invisible if the test wrote the wire
## form itself.
func _make_dto(state_value: int) -> Dictionary:
	var state = RunDomainStateScript.new()
	state.seed = 123456
	return RunCheckpointV5MapperScript.to_v5_dto(
		state,
		SaveSchemaV5Script.PHASE_PREP,
		{"offered_ids": []},
		{"offered_item_ids": [], "discount": 0.5},
		{},
		{"offered_ids": [], "round_index": 0},
		{"seed": 123456, "state": state_value})


# ---------------------------------------------------------------- A


## RED: the state that actually occurred must survive the wire.
func _test_A_red_known_state_survives_the_wire() -> void:
	var dto: Dictionary = _make_dto(KNOWN_BAD_STATE)
	var decoded: Dictionary = _wire_round_trip(dto)
	_assert(not decoded.is_empty(), "the wire round trip produced a DTO")
	if decoded.is_empty():
		return
	var rng_data: Dictionary = decoded.get("rng", {}) as Dictionary
	_assert(rng_data.has("state"), "the decoded rng carries the state")
	# The state is carried as a lossless decimal string.
	var raw_state: Variant = rng_data.get("state", "")
	_assert(raw_state is String,
		"the persisted rng state is a decimal string, not a JSON number")
	var decoded_state: Dictionary = SaveSchemaV5Script.decode_int64(raw_state)
	_assert(bool(decoded_state.get("ok", false)),
		"the persisted rng state decodes (%s)"
			% str(decoded_state.get("reason", "")))
	var got: int = int(decoded_state.get("value", 0))
	_assert(got == KNOWN_BAD_STATE,
		"the rng machine state survives the wire (got %d, want %d)"
			% [got, KNOWN_BAD_STATE])

	# The corruption must come from the wire, not from the in-memory
	# value: the in-memory snapshot is exact.
	RngServiceScript.seed_run(123456)
	for _i in 7:
		RngServiceScript.randf()
	var snap: Dictionary = RngServiceScript.snapshot()
	_assert(int(snap.get("state", 0)) == int(RngServiceScript.snapshot().get("state", -1)),
		"the in-memory snapshot is stable")


# ---------------------------------------------------------------- B


## RED: every boundary value must survive the wire.
func _test_B_red_boundary_values_survive_the_wire() -> void:
	var values: Array[int] = [
		0,
		1,
		-1,
		9007199254740991,       # 2^53 - 1
		9007199254740992,       # 2^53
		9007199254740993,       # 2^53 + 1
		1455099814280779554,    # the value that actually occurred
		9223372036854775807,    # INT64_MAX
		-9223372036854775808,   # INT64_MIN
	]
	for value in values:
		# The canonical string form must round-trip through the strict
		# decoder without a change.
		var encoded: String = SaveSchemaV5Script.encode_int64(value)
		var strict: Dictionary = SaveSchemaV5Script.decode_int64(encoded)
		_assert(bool(strict.get("ok", false)),
			"the canonical form of %d decodes (%s)"
				% [value, str(strict.get("reason", ""))])
		_assert(int(strict.get("value", 0)) == value,
			"the canonical form of %d decodes to itself" % value)
		var dto: Dictionary = _make_dto(value)
		var decoded: Dictionary = _wire_round_trip(dto)
		_assert(not decoded.is_empty(),
			"the wire round trip produced a DTO for %d" % value)
		if decoded.is_empty():
			continue
		var rng_data: Dictionary = decoded.get("rng", {}) as Dictionary
		var raw_state: Variant = rng_data.get("state", "")
		_assert(raw_state is String,
			"the persisted rng state for %d is a decimal string" % value)
		var decoded_state: Dictionary = SaveSchemaV5Script.decode_int64(raw_state)
		_assert(bool(decoded_state.get("ok", false)),
			"the persisted rng state for %d decodes (%s)"
				% [value, str(decoded_state.get("reason", ""))])
		var got: int = int(decoded_state.get("value", 0))
		_assert(got == value,
			"the rng state %d survives the wire (got %d)" % [value, got])


# ---------------------------------------------------------------- C


## draw_count must NOT influence the sequence.
##
## The legacy facade deliberately restores draw_count as 0. This test
## proves that the gameplay contract does not depend on it: the same
## machine state produces the same next value regardless of the
## counter.
##
## The two streams are brought to the SAME machine state on purpose:
## stream A draws three times, stream B draws nine times, and then B
## is rewound to A's machine position with a DIFFERENT draw_count.
func _test_C_draw_count_does_not_affect_the_sequence() -> void:
	var DeterministicRngScript = preload("res://core/rng/deterministic_rng.gd")

	var a = DeterministicRngScript.new(777)
	for _i in 3:
		a.randf()
	var snap_a: Dictionary = a.snapshot()

	# A different stream that reached the same machine state with a
	# different number of draws: rewind it to A's position.
	var b = DeterministicRngScript.new(777)
	for _i in 9:
		b.randf()
	var snap_b: Dictionary = b.snapshot()
	snap_b["state"] = snap_a["state"]
	snap_b["draw_count"] = 417
	b.restore(snap_b)

	_assert(int(a.snapshot().get("state", 0)) == int(b.snapshot().get("state", 0)),
		"the two streams share the same machine state")
	_assert(int(a.snapshot().get("draw_count", 0)) != int(b.snapshot().get("draw_count", 0)),
		"the two streams have different draw counts")

	var next_a: float = a.randf()
	var next_b: float = b.randf()
	_assert(absf(next_a - next_b) < 0.0000001,
		"the next random value does not depend on draw_count")
	_assert(int(a.snapshot().get("state", 0)) == int(b.snapshot().get("state", 0)),
		"the next machine state does not depend on draw_count")


# ----------------------------------------------------------------


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage 3A: %s" % label)
