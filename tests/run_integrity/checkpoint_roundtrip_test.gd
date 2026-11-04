extends SceneTree

## Run Integrity — Stage 3A RED: the persisted checkpoint must describe
## the REAL runtime state.
##
## The v4 DTO hardcodes:
##
##     phase   = "prep"
##     shop    = {}
##     map     = {}
##     rewards = {}
##
## so a MAP / REWARD / MERCHANT checkpoint is indistinguishable from a
## PREP one, and every subsystem offer is regenerated on resume.
##
## This suite is written against the PRODUCTION save path
## (RunController.save_now -> SaveService -> repository), so it fails
## semantically on the current code: the production executes, the
## assertion fails, the process exits non-zero, and there is no parse
## error and no script error.
##
## The expected values are the CONTRACT, not the current behaviour.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunStateV4MapperScript = preload("res://core/progression/run_state_v4_mapper.gd")
const SaveServiceScript = preload("res://core/save/save_service.gd")
const EncounterMapScript = preload("res://core/encounter/encounter_map.gd")
const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")
const BalanceScript = preload("res://core/balance.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_A_red_1_phase_is_not_hardcoded()
	await _test_B_red_2_unit_shop_offer_survives()
	await _test_C_red_3_map_graph_survives()
	await _test_D_red_4_reward_offer_survives()
	await _test_E_red_5_merchant_offer_survives()
	print("")
	print("=== STAGE 3A: CHECKPOINT PERSISTENCE (RED) ===")
	print("passed : %d" % _passed)
	print("failed : %d" % _failed)
	if _failed > 0:
		quit(1)
		return
	quit(0)


## Builds a controller with a clean profile and a deterministic seed.
func _make_controller(seed_value: int) -> Node:
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child(ctrl)
	await process_frame
	# The controller's own _ready() loads the meta profile; replace it
	# with a deterministic one so the offers are stable.
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]
	ctrl.start_run(seed_value)
	await process_frame
	return ctrl


## Reads the persisted DTO for a seed through the production service.
func _load_dto(seed_value: int) -> Dictionary:
	var result: RefCounted = SaveServiceScript.load_run_v4(seed_value)
	if result == null or not result.is_ok():
		return {}
	return result.data


## Resumes a run in a FRESH runtime and returns the controller.
##
## The runtime is recreated, so the resumed controller can only hold
## the state that was actually persisted.
func _resume(seed_value: int) -> Node:
	var ctrl: Node = RunControllerScript.new()
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]
	var ok: bool = ctrl.resume_run(seed_value)
	await process_frame
	if not ok:
		ctrl.queue_free()
		await process_frame
		return null
	return ctrl


# ---------------------------------------------------------------- RED-1


## RED-1: a non-PREP stable state must not persist as "prep".
func _test_A_red_1_phase_is_not_hardcoded() -> void:
	var seed: int = 810001
	var ctrl: Node = await _make_controller(seed)

	# Move into the MAP phase: the encounter map exists and the run
	# is in a stable, non-PREP state.
	ctrl.encounter_map = EncounterMapScript.new()
	ctrl.encounter_map.generate(seed)
	ctrl.encounter_map.start_run()
	ctrl._set_phase(ctrl.Phase.MAP)
	ctrl.save_now()
	await process_frame

	var dto: Dictionary = _load_dto(seed)
	_assert(not dto.is_empty(), "the MAP checkpoint was persisted")
	if not dto.is_empty():
		var persisted_phase: String = str(dto.get("phase", ""))
		_assert(persisted_phase != "prep",
			"the persisted phase is not hardcoded to prep (got '%s')" % persisted_phase)
		_assert(persisted_phase == "map",
			"the persisted phase is the wire name of MAP (got '%s')" % persisted_phase)

	ctrl.queue_free()
	await process_frame


# ---------------------------------------------------------------- RED-2


## RED-2: the unit-shop offer must survive the save.
func _test_B_red_2_unit_shop_offer_survives() -> void:
	var seed: int = 810002
	var ctrl: Node = await _make_controller(seed)

	var offered_before: Array = ctrl.shop.offered_ids()
	_assert(offered_before.size() > 0, "the unit shop has a deterministic offer")

	ctrl.save_now()
	await process_frame

	var dto: Dictionary = _load_dto(seed)
	_assert(not dto.is_empty(), "the PREP checkpoint was persisted")
	if dto.is_empty():
		ctrl.queue_free()
		await process_frame
		return
	var shop_data: Dictionary = dto.get("shop", {}) as Dictionary
	_assert(not shop_data.is_empty(),
		"the persisted checkpoint carries the unit-shop offer")
	var persisted_ids: Array = shop_data.get("offered_ids", []) as Array
	_assert(persisted_ids.size() == offered_before.size(),
		"the persisted offer has the same number of slots")
	if persisted_ids.size() == offered_before.size() and not offered_before.is_empty():
		var same: bool = true
		for i in offered_before.size():
			if str(persisted_ids[i]) != str(offered_before[i]):
				same = false
		_assert(same,
			"the persisted offer keeps the exact ids AND the ordering")

	# The offer must also come BACK on a resume, not only be present
	# in the file.
	var resumed: Node = await _resume(seed)
	_assert(resumed != null, "the PREP checkpoint resumed")
	if resumed != null:
		_assert(resumed.shop.offered_ids() == offered_before,
			"the resumed unit shop keeps the exact offer")
		ctrl.queue_free()
		await process_frame
		resumed.queue_free()
		await process_frame
		return
	ctrl.queue_free()
	await process_frame


# ---------------------------------------------------------------- RED-3


## RED-3: the encounter map must survive the save, not be regenerated.
##
## The test advances the map to a specific node, saves, and then checks
## that the persisted graph is the ADVANCED graph. A regeneration would
## produce a fresh map whose visited / available state differs.
func _test_C_red_3_map_graph_survives() -> void:
	var seed: int = 810003
	var ctrl: Node = await _make_controller(seed)

	ctrl.encounter_map = EncounterMapScript.new()
	ctrl.encounter_map.generate(seed)
	ctrl.encounter_map.start_run()
	# Advance: pick the first available node so that visited / current
	# state are non-trivial.
	var available: Array[int] = ctrl.encounter_map.get_available_next_ids()
	_assert(available.size() > 0, "the map has available nodes")
	if available.is_empty():
		ctrl.queue_free()
		await process_frame
		return
	ctrl.encounter_map.choose_next(available[0])
	var current_before: int = ctrl.encounter_map.get_current_node_id()
	var visited_before: int = ctrl.encounter_map.get_layer_nodes(1).size()
	_assert(current_before >= 0, "the map has a current node")

	ctrl._set_phase(ctrl.Phase.MAP)
	ctrl.save_now()
	await process_frame

	var dto: Dictionary = _load_dto(seed)
	_assert(not dto.is_empty(), "the MAP checkpoint was persisted")
	if dto.is_empty():
		ctrl.queue_free()
		await process_frame
		return
	var map_data: Dictionary = dto.get("map", {}) as Dictionary
	_assert(not map_data.is_empty(),
		"the persisted checkpoint carries the encounter-map snapshot")
	if not map_data.is_empty():
		_assert(int(map_data.get("current_node_id", -1)) == current_before,
			"the persisted map keeps the current node")
		var nodes: Array = map_data.get("nodes", []) as Array
		_assert(nodes.size() == ctrl.encounter_map.get_all_nodes().size(),
			"the persisted map keeps every node")
		var any_visited: bool = false
		for n in nodes:
			if bool((n as Dictionary).get("visited", false)):
				any_visited = true
		_assert(any_visited, "the persisted map keeps the visited state")

	# The map must come BACK on a resume: the graph, the current node,
	# the visited state and the available next ids.
	var resumed: Node = await _resume(seed)
	_assert(resumed != null, "the MAP checkpoint resumed")
	if resumed != null:
		_assert(resumed.encounter_map != null,
			"the resumed run has the encounter map")
		if resumed.encounter_map != null:
			_assert(resumed.encounter_map.get_current_node_id() == current_before,
				"the resumed map keeps the current node")
			_assert(resumed.encounter_map.get_available_next_ids()
				== ctrl.encounter_map.get_available_next_ids(),
				"the resumed map keeps the available-next ids")
			_assert(resumed.encounter_map.get_layer_types()
				== ctrl.encounter_map.get_layer_types(),
				"the resumed map keeps the graph")
		ctrl.queue_free()
		await process_frame
		resumed.queue_free()
		await process_frame
		return
	ctrl.queue_free()
	await process_frame


# ---------------------------------------------------------------- RED-4


## RED-4: the reward offer must survive the save.
func _test_D_red_4_reward_offer_survives() -> void:
	var seed: int = 810004
	var ctrl: Node = await _make_controller(seed)

	ctrl.reward.generate_offer(2)
	var reward_before: Array = ctrl.reward.offered_ids()
	_assert(reward_before.size() > 0, "the reward screen has an offer")

	ctrl._set_phase(ctrl.Phase.REWARD)
	ctrl.save_now()
	await process_frame

	var dto: Dictionary = _load_dto(seed)
	_assert(not dto.is_empty(), "the REWARD checkpoint was persisted")
	if dto.is_empty():
		ctrl.queue_free()
		await process_frame
		return
	var rewards_data: Dictionary = dto.get("rewards", {}) as Dictionary
	_assert(not rewards_data.is_empty(),
		"the persisted checkpoint carries the reward offer")
	var persisted_ids: Array = rewards_data.get("offered_ids", []) as Array
	_assert(persisted_ids.size() == reward_before.size(),
		"the persisted reward has the same number of slots")
	if persisted_ids.size() == reward_before.size() and not reward_before.is_empty():
		var same: bool = true
		for i in reward_before.size():
			if str(persisted_ids[i]) != str(reward_before[i]):
				same = false
		_assert(same,
			"the persisted reward keeps the exact ids AND the ordering")

	# The reward must come BACK on a resume: no reroll.
	var resumed: Node = await _resume(seed)
	_assert(resumed != null, "the REWARD checkpoint resumed")
	if resumed != null:
		_assert(resumed.reward.offered_ids() == reward_before,
			"the resumed reward keeps the exact offer")
		_assert(resumed.phase == resumed.Phase.REWARD,
			"the resumed run is in the REWARD phase")
		ctrl.queue_free()
		await process_frame
		resumed.queue_free()
		await process_frame
		return
	ctrl.queue_free()
	await process_frame


# ---------------------------------------------------------------- RED-5


## RED-5: the merchant offer must survive the save.
func _test_E_red_5_merchant_offer_survives() -> void:
	var seed: int = 810005
	var ctrl: Node = await _make_controller(seed)

	ctrl.merchant_shop.refresh()
	var merchant_before: Array = ctrl.merchant_shop.get_offered_ids()
	var discount_before: float = ctrl.merchant_shop.get_discount()
	_assert(merchant_before.size() > 0, "the merchant shop has an offer")

	ctrl.state.just_visited_merchant = true
	ctrl._set_phase(ctrl.Phase.PREP)
	ctrl.save_now()
	await process_frame

	var dto: Dictionary = _load_dto(seed)
	_assert(not dto.is_empty(), "the MERCHANT checkpoint was persisted")
	if dto.is_empty():
		ctrl.queue_free()
		await process_frame
		return
	_assert(str(dto.get("phase", "")) == "merchant",
		"the merchant checkpoint persists the wire phase 'merchant'")
	var shop_data: Dictionary = dto.get("shop", {}) as Dictionary
	var merchant_data: Dictionary = shop_data.get("merchant", {}) as Dictionary
	_assert(not merchant_data.is_empty(),
		"the persisted checkpoint carries the merchant offer")
	if not merchant_data.is_empty():
		var persisted_ids: Array = merchant_data.get("offered_item_ids", []) as Array
		_assert(persisted_ids.size() == merchant_before.size(),
			"the persisted merchant offer has the same number of slots")
		var same: bool = true
		for i in merchant_before.size():
			if str(persisted_ids[i]) != str(merchant_before[i]):
				same = false
		_assert(same,
			"the persisted merchant offer keeps the exact ids AND the ordering")
		_assert(absf(float(merchant_data.get("discount", -1.0)) - discount_before) < 0.0001,
			"the persisted merchant offer keeps the discount")

	# The merchant must come BACK on a resume.
	var resumed: Node = await _resume(seed)
	_assert(resumed != null, "the MERCHANT checkpoint resumed")
	if resumed != null:
		_assert(resumed.merchant_shop.get_offered_ids() == merchant_before,
			"the resumed merchant keeps the exact offer")
		_assert(absf(resumed.merchant_shop.get_discount() - discount_before) < 0.0001,
			"the resumed merchant keeps the discount")
		_assert(resumed.state.just_visited_merchant,
			"the resumed run keeps the merchant flag")
		ctrl.queue_free()
		await process_frame
		resumed.queue_free()
		await process_frame
		return
	ctrl.queue_free()
	await process_frame


# ----------------------------------------------------------------


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage 3A: %s" % label)
