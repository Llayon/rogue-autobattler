extends SceneTree

## Run Integrity — the v5 checkpoint serialization is byte-stable.
##
## Two semantically identical checkpoints must serialize to the SAME
## bytes. The ordering must not depend on:
##
##   - the Dictionary iteration order,
##   - the filesystem listing order,
##   - the object identity,
##   - a runtime pointer value.
##
## The map snapshot is the interesting part: its nodes are emitted in
## ascending id order and every id list is sorted, so two graphs that
## differ only in insertion order serialize identically.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const SaveSchemaV5Script = preload("res://core/save/save_schema_v5.gd")
const EncounterMapScript = preload("res://core/encounter/encounter_map.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_A_the_same_checkpoint_serializes_identically()
	await _test_B_the_map_order_does_not_change_the_bytes()
	await _test_C_the_key_order_is_canonical()
	print("")
	print("=== STAGE 3B: V5 BYTE DETERMINISM ===")
	print("passed : %d" % _passed)
	print("failed : %d" % _failed)
	if _failed > 0:
		quit(1)
		return
	quit(0)


func _make_controller(seed_value: int) -> Node:
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]
	ctrl.start_run(seed_value)
	await process_frame
	return ctrl


# ---------------------------------------------------------------- A


## The same runtime saved twice must produce the same bytes.
func _test_A_the_same_checkpoint_serializes_identically() -> void:
	var ctrl: Node = await _make_controller(860001)
	ctrl.encounter_map = EncounterMapScript.new()
	ctrl.encounter_map.generate(860001)
	ctrl.encounter_map.start_run()
	ctrl.reward.generate_offer(2)
	ctrl.merchant_shop.refresh()
	ctrl._set_phase(ctrl.Phase.MAP)

	var first: PackedByteArray = RunSaveRepositoryScript.serialize_canonical_bytes(
		ctrl.build_checkpoint_dto())
	var second: PackedByteArray = RunSaveRepositoryScript.serialize_canonical_bytes(
		ctrl.build_checkpoint_dto())
	_assert(first == second,
		"the same checkpoint serializes to the same bytes")
	_assert(first.size() > 0, "the serialized checkpoint is not empty")

	ctrl.queue_free()
	await process_frame


# ---------------------------------------------------------------- B


## A map whose nodes were added in a different order must serialize to
## the same bytes.
func _test_B_the_map_order_does_not_change_the_bytes() -> void:
	var map_a: RefCounted = EncounterMapScript.new()
	map_a.generate(860002)
	map_a.start_run()

	# The SAME graph, with the node list reversed. The map must not be
	# regenerated: generate() consumes the RNG, so a second call would
	# produce a DIFFERENT graph and the comparison would prove nothing.
	var snap_a: Dictionary = map_a.snapshot()
	var snap_b: Dictionary = snap_a.duplicate(true)
	var reversed_nodes: Array = []
	var nodes: Array = snap_b.get("nodes", []) as Array
	for i in range(nodes.size() - 1, -1, -1):
		reversed_nodes.append(nodes[i])
	snap_b["nodes"] = reversed_nodes

	# The two snapshots describe the same graph.
	_assert(int(snap_a.get("next_id", -1)) == int(snap_b.get("next_id", -2)),
		"the two snapshots describe the same graph")
	_assert(int(snap_a.get("current_node_id", -1))
		== int(snap_b.get("current_node_id", -2)),
		"the two snapshots share the current node")

	var dto_a: Dictionary = SaveSchemaV5Script.empty_dto()
	dto_a["seed"] = 860002
	dto_a["run_id"] = "run_860002"
	dto_a["map"] = snap_a
	var dto_b: Dictionary = SaveSchemaV5Script.empty_dto()
	dto_b["seed"] = 860002
	dto_b["run_id"] = "run_860002"
	dto_b["map"] = snap_b

	var bytes_a: PackedByteArray = RunSaveRepositoryScript.serialize_canonical_bytes(dto_a)
	var bytes_b: PackedByteArray = RunSaveRepositoryScript.serialize_canonical_bytes(dto_b)
	_assert(bytes_a == bytes_b,
		"the node order does not change the serialized bytes")

	map_a = null


# ---------------------------------------------------------------- C


## The serialized key order does not depend on the insertion order.
##
## Godot's JSON.stringify always emits the object keys in sorted
## order, so the byte form is deterministic by construction. The
## canonical schema order is the CONTRACT for the DTO, not for the
## JSON text: what matters is that the same checkpoint always
## produces the same bytes.
func _test_C_the_key_order_is_canonical() -> void:
	var dto_a: Dictionary = SaveSchemaV5Script.empty_dto()
	dto_a["seed"] = 860003
	dto_a["run_id"] = "run_860003"

	# The same keys, inserted in a different order.
	var dto_b: Dictionary = {}
	for key in SaveSchemaV5Script.TOP_LEVEL_KEYS:
		dto_b[key] = dto_a[key]

	var bytes_a: PackedByteArray = RunSaveRepositoryScript.serialize_canonical_bytes(dto_a)
	var bytes_b: PackedByteArray = RunSaveRepositoryScript.serialize_canonical_bytes(dto_b)
	_assert(bytes_a == bytes_b,
		"the insertion order does not change the serialized bytes")

	# Every canonical key is present in the serialized object.
	var text: String = bytes_a.get_string_from_utf8()
	var nl: int = text.find("\n")
	var body: String = text.substr(nl + 1, text.length() - (nl + 1))
	var parsed: Variant = JSON.parse_string(body)
	_assert(parsed is Dictionary, "the serialized body is a JSON object")
	if parsed is Dictionary:
		var keys: Array = (parsed as Dictionary).keys()
		_assert(keys.size() == SaveSchemaV5Script.TOP_LEVEL_KEYS.size(),
			"the serialized checkpoint has every canonical key")
		var all_present: bool = true
		for key in SaveSchemaV5Script.TOP_LEVEL_KEYS:
			if not ((parsed as Dictionary).has(key)):
				all_present = false
		_assert(all_present, "the serialized checkpoint carries every canonical key")


# ----------------------------------------------------------------


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage 3B: %s" % label)
