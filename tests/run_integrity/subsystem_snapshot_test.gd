extends SceneTree

## Run Integrity — Stage 3A RED: the subsystems need a pure
## snapshot / restore contract.
##
## Today the resume path regenerates every subsystem:
##
##     _refresh_shop()               -> shop.refresh(pool)
##     merchant_shop.refresh()       -> new offers
##     reward.generate_offer(...)    -> new offers
##     encounter_map.generate(seed)  -> a new graph
##
## None of them can be restored exactly, so a resume can never
## reproduce the persisted state.
##
## This suite pins the REQUIRED contract: each subsystem exposes a
## pure snapshot and a restore that is atomic (validate everything,
## then commit). It is written against the CURRENT code, so the
## snapshot calls fail: the production executes, the assertion fails,
## the process exits non-zero, and there is no parse error.

const EncounterMapScript = preload("res://core/encounter/encounter_map.gd")
const ShopScript = preload("res://core/economy/shop.gd")
const ShopScreenScript = preload("res://core/progression/shop_screen.gd")
const RewardScreenScript = preload("res://core/progression/reward_screen.gd")
const RngServiceScript = preload("res://core/utils/rng_service.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_A_red_map_snapshot_contract()
	await _test_B_red_shop_snapshot_contract()
	await _test_C_red_merchant_snapshot_contract()
	await _test_D_red_reward_snapshot_contract()
	await _test_E_red_rng_snapshot_contract()
	print("")
	print("=== STAGE 3A: SUBSYSTEM SNAPSHOT CONTRACT (RED) ===")
	print("passed : %d" % _passed)
	print("failed : %d" % _failed)
	if _failed > 0:
		quit(1)
		return
	quit(0)


# ---------------------------------------------------------------- A


## The map must expose a pure snapshot and an atomic restore.
func _test_A_red_map_snapshot_contract() -> void:
	var map: RefCounted = EncounterMapScript.new()
	map.generate(840001)
	map.start_run()
	var available: Array[int] = map.get_available_next_ids()
	if not available.is_empty():
		map.choose_next(available[0])

	_assert(map.has_method("snapshot"),
		"the encounter map exposes a pure snapshot()")
	_assert(map.has_method("restore_snapshot"),
		"the encounter map exposes an atomic restore_snapshot()")

	if map.has_method("snapshot") and map.has_method("restore_snapshot"):
		var snap: Variant = map.snapshot()
		_assert(snap is Dictionary,
			"the map snapshot is a plain Dictionary")
		if snap is Dictionary:
			var data: Dictionary = snap
			_assert(data.has("nodes"), "the map snapshot carries the nodes")
			_assert(data.has("current_node_id"),
				"the map snapshot carries the current node")
			_assert(data.has("next_id"), "the map snapshot carries the next id")

			# A fresh map restored from the snapshot must equal it.
			var restored: RefCounted = EncounterMapScript.new()
			var ok: bool = restored.restore_snapshot(data)
			_assert(ok, "the map restore accepts a valid snapshot")
			_assert(restored.get_current_node_id() == map.get_current_node_id(),
				"the restored map keeps the current node")
			_assert(restored.get_available_next_ids() == map.get_available_next_ids(),
				"the restored map keeps the available-next ids")
			_assert(restored.get_layer_types() == map.get_layer_types(),
				"the restored map keeps the layer types")

			# A bad snapshot must not partially modify the live map.
			var broken: Dictionary = data.duplicate(true)
			broken["nodes"] = "not an array"
			var before_nodes: int = restored.get_all_nodes().size()
			restored.restore_snapshot(broken)
			_assert(restored.get_all_nodes().size() == before_nodes,
				"a bad snapshot does not partially modify the live map")

	map = null


# ---------------------------------------------------------------- B


## The unit shop must expose a pure snapshot and an atomic restore.
func _test_B_red_shop_snapshot_contract() -> void:
	var shop: RefCounted = ShopScript.new()
	var pool: Array[StringName] = [&"warrior", &"archer", &"goblin"] as Array[StringName]
	shop.refresh(pool)

	_assert(shop.has_method("snapshot"),
		"the unit shop exposes a pure snapshot()")
	_assert(shop.has_method("restore_snapshot"),
		"the unit shop exposes an atomic restore_snapshot()")

	if shop.has_method("snapshot") and shop.has_method("restore_snapshot"):
		var before: Array = shop.offered_ids()
		var snap: Variant = shop.snapshot()
		_assert(snap is Dictionary, "the shop snapshot is a plain Dictionary")
		if snap is Dictionary:
			var restored: RefCounted = ShopScript.new()
			var ok: bool = restored.restore_snapshot(snap)
			_assert(ok, "the shop restore accepts a valid snapshot")
			_assert(restored.offered_ids() == before,
				"the restored shop keeps the exact ids AND the ordering")

			var broken: Dictionary = (snap as Dictionary).duplicate(true)
			broken["offered_ids"] = 42
			var before_ids: Array = restored.offered_ids()
			restored.restore_snapshot(broken)
			_assert(restored.offered_ids() == before_ids,
				"a bad snapshot does not partially modify the live shop")

	shop = null


# ---------------------------------------------------------------- C


## The merchant shop must expose a pure snapshot and an atomic restore.
func _test_C_red_merchant_snapshot_contract() -> void:
	var merchant: RefCounted = ShopScreenScript.new()
	merchant.refresh()
	merchant.set_discount(0.75)

	_assert(merchant.has_method("snapshot"),
		"the merchant shop exposes a pure snapshot()")
	_assert(merchant.has_method("restore_snapshot"),
		"the merchant shop exposes an atomic restore_snapshot()")

	if merchant.has_method("snapshot") and merchant.has_method("restore_snapshot"):
		var before_ids: Array = merchant.get_offered_ids()
		var before_discount: float = merchant.get_discount()
		var snap: Variant = merchant.snapshot()
		_assert(snap is Dictionary, "the merchant snapshot is a plain Dictionary")
		if snap is Dictionary:
			var restored: RefCounted = ShopScreenScript.new()
			var ok: bool = restored.restore_snapshot(snap)
			_assert(ok, "the merchant restore accepts a valid snapshot")
			_assert(restored.get_offered_ids() == before_ids,
				"the restored merchant keeps the exact ids AND the ordering")
			_assert(absf(restored.get_discount() - before_discount) < 0.0001,
				"the restored merchant keeps the discount")

	merchant = null


# ---------------------------------------------------------------- D


## The reward screen must expose a pure snapshot and an atomic restore.
func _test_D_red_reward_snapshot_contract() -> void:
	var reward: RefCounted = RewardScreenScript.new()
	reward.generate_offer(3)

	_assert(reward.has_method("snapshot"),
		"the reward screen exposes a pure snapshot()")
	_assert(reward.has_method("restore_snapshot"),
		"the reward screen exposes an atomic restore_snapshot()")

	if reward.has_method("snapshot") and reward.has_method("restore_snapshot"):
		var before: Array = reward.offered_ids()
		var snap: Variant = reward.snapshot()
		_assert(snap is Dictionary, "the reward snapshot is a plain Dictionary")
		if snap is Dictionary:
			var restored: RefCounted = RewardScreenScript.new()
			var ok: bool = restored.restore_snapshot(snap)
			_assert(ok, "the reward restore accepts a valid snapshot")
			_assert(restored.offered_ids() == before,
				"the restored reward keeps the exact ids AND the ordering")

			var broken: Dictionary = (snap as Dictionary).duplicate(true)
			broken["offered_ids"] = "not an array"
			var before_ids: Array = restored.offered_ids()
			restored.restore_snapshot(broken)
			_assert(restored.offered_ids() == before_ids,
				"a bad snapshot does not partially modify the live reward")

	reward = null


# ---------------------------------------------------------------- E


## The RNG already exposes snapshot / restore; the contract is that
## the restore resumes the stream EXACTLY, not merely the seed.
func _test_E_red_rng_snapshot_contract() -> void:
	RngServiceScript.seed_run(850001)
	# Draw a few values so the stream is mid-way.
	for _i in 5:
		RngServiceScript.randf()
	var snap: Dictionary = RngServiceScript.snapshot()
	_assert(snap.has("seed"), "the RNG snapshot carries the seed")
	_assert(snap.has("state"), "the RNG snapshot carries the machine state")

	var expected_next: float = RngServiceScript.randf()
	RngServiceScript.restore(snap)
	var actual_next: float = RngServiceScript.randf()
	_assert(absf(expected_next - actual_next) < 0.0000001,
		"the RNG restore resumes the stream exactly")
	_assert(int(RngServiceScript.snapshot().get("state", -1))
		== int(RngServiceScript.snapshot().get("state", -2)),
		"the RNG state is stable across the comparison")


# ----------------------------------------------------------------


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage 3A: %s" % label)
