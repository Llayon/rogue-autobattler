extends SceneTree

## Run Integrity — Stage 3A RED-6: RNG CONTINUATION.
##
## A seed alone does not reproduce the continuation of an already
## running random stream. The resume path reseeds:
##
##     Rng.seed_run(state.seed)
##
## so the next random decision after a resume differs from the next
## random decision in an uninterrupted run.
##
## The proof uses a REAL production consumer: the reward offer
## generator draws from the shared run stream (Rng.randf, Rng.randi_range)
## and the unit-shop refresh does the same. The test compares:
##
##   A = uninterrupted run   -> next reward offer
##   B = run -> save -> destroy runtime -> resume -> next reward offer
##
## and requires A == B, plus the same subsequent RNG state.
##
## The negative control (resume via seed_run only) is the CURRENT
## behaviour, so this suite is RED before the fix.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const SaveServiceScript = preload("res://core/save/save_service.gd")
const RngServiceScript = preload("res://core/utils/rng_service.gd")
const RewardScreenScript = preload("res://core/progression/reward_screen.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const BalanceScript = preload("res://core/balance.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_A_red_6_resumed_reward_offer_matches_uninterrupted()
	await _test_B_red_6_resumed_shop_offer_matches_uninterrupted()
	await _test_C_red_6_rng_continuation_across_several_seeds()
	print("")
	print("=== STAGE 3A: RNG CONTINUATION (RED) ===")
	print("\n=== STAGE 3A: RNG CONTINUATION (RED): %d pass / %d fail ===\n"
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## Builds a controller with a deterministic profile.
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


## A = uninterrupted; B = save + recreate + resume. The next reward
## offer must be identical.
func _test_A_red_6_resumed_reward_offer_matches_uninterrupted() -> void:
	var seed: int = 820001

	# --- Path A: uninterrupted ---
	var a_ctrl: Node = await _make_controller(seed)
	# Consume some randomness first, so the offer is not the first draw.
	a_ctrl.reward.generate_offer(2)
	a_ctrl.save_now()
	await process_frame
	# The NEXT offer of the SAME round: the round must not change,
	# otherwise the tier (and therefore the offered units) differ for a
	# reason that has nothing to do with the RNG continuation.
	var a_next: RewardScreen = RewardScreenScript.new()
	a_next.generate_offer(2)
	var a_offer: Array = a_next.offered_ids()
	var a_rng: Dictionary = RngServiceScript.snapshot()
	a_ctrl.queue_free()
	await process_frame

	# --- Path B: same prefix, then resume ---
	var b_ctrl: Node = await _make_controller(seed)
	b_ctrl.reward.generate_offer(2)
	b_ctrl.save_now()
	await process_frame
	# The runtime is destroyed and recreated: the resumed run must
	# continue the stream, not reseed it.
	b_ctrl.queue_free()
	await process_frame

	var c_ctrl: Node = RunControllerScript.new()
	get_root().add_child(c_ctrl)
	await process_frame
	c_ctrl.profile = MetaProfileScript.new()
	var resumed: bool = c_ctrl.resume_run(seed)
	await process_frame
	_assert(resumed, "the run resumed")

	# The SAME production consumer: the next reward offer of the SAME
	# round.
	var next_reward: RewardScreen = RewardScreenScript.new()
	next_reward.generate_offer(2)
	var b_offer: Array = next_reward.offered_ids()
	var b_rng: Dictionary = RngServiceScript.snapshot()

	_assert(a_offer.size() == b_offer.size(),
		"the resumed reward offer has the same number of slots")
	if a_offer.size() == b_offer.size() and not a_offer.is_empty():
		var same: bool = true
		for i in a_offer.size():
			if str(a_offer[i]) != str(b_offer[i]):
				same = false
		_assert(same,
			"the resumed reward offer matches the uninterrupted one")
	_assert(int(a_rng.get("state", -1)) == int(b_rng.get("state", -2)),
		"the resumed RNG state matches the uninterrupted one")

	c_ctrl.queue_free()
	await process_frame


# ---------------------------------------------------------------- B


## The same proof with the unit-shop refresh as the consumer.
func _test_B_red_6_resumed_shop_offer_matches_uninterrupted() -> void:
	var seed: int = 820002

	var a_ctrl: Node = await _make_controller(seed)
	a_ctrl.reward.generate_offer(2)
	a_ctrl.save_now()
	await process_frame
	# The NEXT shop refresh of the SAME pool: the refresh is the
	# production consumer, and it must run AFTER the save, exactly
	# like in the resumed path.
	a_ctrl.shop.refresh(a_ctrl.profile.unlocked_units)
	var a_offer: Array = a_ctrl.shop.offered_ids()
	a_ctrl.queue_free()
	await process_frame

	var b_ctrl: Node = await _make_controller(seed)
	b_ctrl.reward.generate_offer(2)
	b_ctrl.save_now()
	await process_frame
	b_ctrl.queue_free()
	await process_frame

	var c_ctrl: Node = RunControllerScript.new()
	get_root().add_child(c_ctrl)
	await process_frame
	# The SAME pool as in the uninterrupted path: the shop offer is
	# drawn FROM the pool, so a different pool would change the offer
	# for a reason that has nothing to do with the RNG continuation.
	c_ctrl.profile = MetaProfileScript.new()
	c_ctrl.profile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]
	var resumed: bool = c_ctrl.resume_run(seed)
	await process_frame
	_assert(resumed, "the run resumed for the shop proof")

	# The shop refresh is a production consumer of the run stream.
	c_ctrl.shop.refresh(c_ctrl.profile.unlocked_units)
	var b_offer: Array = c_ctrl.shop.offered_ids()

	_assert(a_offer.size() == b_offer.size(),
		"the resumed shop offer has the same number of slots")
	if a_offer.size() == b_offer.size() and not a_offer.is_empty():
		var same: bool = true
		for i in a_offer.size():
			if str(a_offer[i]) != str(b_offer[i]):
				same = false
		_assert(same,
			"the resumed shop offer matches the uninterrupted one")

	c_ctrl.queue_free()
	await process_frame


# ---------------------------------------------------------------- C


## The continuity must hold for SEVERAL seeds, not just one.
func _test_C_red_6_rng_continuation_across_several_seeds() -> void:
	var seeds: Array[int] = [830001, 830002, 830003]
	for seed in seeds:
		# --- Path A ---
		var a_ctrl: Node = await _make_controller(seed)
		a_ctrl.reward.generate_offer(2)
		a_ctrl.save_now()
		await process_frame
		var a_next: RewardScreen = RewardScreenScript.new()
		a_next.generate_offer(2)
		var a_offer: Array = a_next.offered_ids()
		a_ctrl.queue_free()
		await process_frame

		# --- Path B ---
		var b_ctrl: Node = await _make_controller(seed)
		b_ctrl.reward.generate_offer(2)
		b_ctrl.save_now()
		await process_frame
		b_ctrl.queue_free()
		await process_frame

		var c_ctrl: Node = RunControllerScript.new()
		get_root().add_child(c_ctrl)
		await process_frame
		c_ctrl.profile = MetaProfileScript.new()
		c_ctrl.resume_run(seed)
		await process_frame
		var next_reward: RewardScreen = RewardScreenScript.new()
		next_reward.generate_offer(2)
		var b_offer: Array = next_reward.offered_ids()

		var same: bool = a_offer.size() == b_offer.size()
		if same:
			for i in a_offer.size():
				if str(a_offer[i]) != str(b_offer[i]):
					same = false
		_assert(same,
			"seed %d: the resumed offer matches the uninterrupted one" % seed)

		c_ctrl.queue_free()
		await process_frame


# ----------------------------------------------------------------


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage 3A: %s" % label)
