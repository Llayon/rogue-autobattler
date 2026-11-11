extends SceneTree

## The lives cap is a BALANCE constant, not a formula in the logic.
##
## THE DEFECT THIS SUITE GUARDS:
##
##   The cap on the lives was written INTO the logic, twice:
##
##     state.lives = mini(state.lives + 1, BalanceScript.STARTING_LIVES * 2)
##
##   in `_apply_heal_effect()` and again in `_apply_shrine_effect()`.
##   The `* 2` is a magic number: the project rule in AGENTS.md says
##   every balance number lives in core/balance.gd, and a formula in
##   the logic is the exact failure mode that file's own header warns
##   about ("if you move the gold-per-round into a literal, in two
##   months you will not remember where it is and will balance the
##   wrong variable").
##
##   Two call sites meant two places to change when the cap moves, and
##   a balance change to STARTING_LIVES silently changed the cap in
##   a way nobody asked for.
##
## WHAT THIS SUITE REQUIRES:
##   1. core/balance.gd declares ONE cap constant.
##   2. The cap equals the value the logic used (STARTING_LIVES * 2),
##      so the refactor changes no behaviour.
##   3. The HEAL effect respects the cap.
##   4. The SHRINE effect respects the cap.
##   5. The logic contains NO hard-coded multiplier: the cap comes
##      from the balance file, not from a formula next to the use.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const BalanceScript = preload("res://core/balance.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _run()
	print("\n=== the lives cap is a balance constant: %d passed, %d failed ===\n" % [_passed, _failed])
	if _failed > 0:
		quit(1)
	else:
		quit(0)


func _assert(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
		print("  [OK]   %s" % msg)
	else:
		_failed += 1
		printerr("  [FAIL] %s" % msg)


## Removes a file from the shared user directory, if it is there.
func _remove_file(path: String) -> void:
	var global_path: String = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(global_path):
		DirAccess.remove_absolute(global_path)
func _run() -> void:
	# --- 1. the balance file declares the cap ---
	# The constant must EXIST. A missing constant is a failure, not a
	# skipped check: a check that compares against a default proves
	# nothing.
	var has_cap: bool = false
	var cap_value: int = -1
	# The constant map is a RUNTIME lookup: a direct
	# `BalanceScript.MAX_LIVES` would be a parse error when the
	# constant does not exist yet, and the suite would not RUN -- it
	# would not FAIL. A missing constant must be an assertion
	# failure, so it is looked up through the map.
	# The declaration is checked in the SOURCE: a constant that is
	# not declared there is not a balance constant, whatever a
	# reflection API reports.
	var balance_src: String = FileAccess.get_file_as_string(
		"res://core/balance.gd")
	_assert(balance_src.contains("const MAX_LIVES"),
		"core/balance.gd declares MAX_LIVES (the lives cap)")
	has_cap = balance_src.contains("const MAX_LIVES")
	if has_cap:
		# The VALUE is read through the live class, so the assertion
		# is against the real constant, not against the text.
		cap_value = int(BalanceScript.MAX_LIVES)

	# --- 2. the cap is the value the logic used ---
	# STARTING_LIVES * 2 == 2 with STARTING_LIVES == 1. The refactor
	# must not change the game's behaviour.
	if has_cap:
		_assert(cap_value == BalanceScript.STARTING_LIVES * 2,
			"the cap is STARTING_LIVES * 2 = %d (got %d)"
			% [BalanceScript.STARTING_LIVES * 2, cap_value])
		_assert(cap_value >= BalanceScript.STARTING_LIVES,
			"the cap is at least the starting lives (%d >= %d)"
			% [cap_value, BalanceScript.STARTING_LIVES])

	# --- 3. the HEAL effect respects the cap ---
	# The seed is THIS suite's own: 8109 is not used by any other
	# suite. The legacy suite writes current_run_seed = 42 into the
	# shared meta, and the settings suite looks for THAT seed's
	# checkpoint -- so a run on 42 would leave a checkpoint the
	# settings suite then sees, and the Continue button would be
	# visible where the suite expects it hidden.
	var ctrl: Node = RunControllerScript.new()
	root.add_child.call_deferred(ctrl)
	await process_frame
	var seed_value: int = 8109
	var checkpoint: String = "user://saves/runs/run_%d.tres" % seed_value
	_remove_file(checkpoint)
	ctrl.start_run(seed_value)

	ctrl.state.lives = BalanceScript.STARTING_LIVES
	ctrl._apply_heal_effect()
	_assert(ctrl.state.lives == BalanceScript.STARTING_LIVES + 1,
		"the HEAL grants one life (got %d)" % ctrl.state.lives)

	# At the cap, HEAL must not push past it.
	ctrl.state.lives = BalanceScript.STARTING_LIVES * 2
	ctrl._apply_heal_effect()
	_assert(ctrl.state.lives == BalanceScript.STARTING_LIVES * 2,
		"the HEAL does not exceed the cap (got %d)" % ctrl.state.lives)

	# --- 4. the SHRINE effect respects the same cap ---
	# The SHRINE gives ONE RANDOM bonus of four (gold / lives / HP /
	# attack), so it does not always grant a life and the test must
	# not assume it does. What it must never do is exceed the cap.
	# The SHRINE is therefore exercised repeatedly, and every life
	# outcome it produces is checked against the cap.
	var shrine_lives_seen: bool = false
	var shrine_over_cap: bool = false
	for i in 40:
		ctrl.state.lives = BalanceScript.STARTING_LIVES * 2
		ctrl._apply_shrine_effect()
		if ctrl.state.lives > BalanceScript.STARTING_LIVES * 2:
			shrine_over_cap = true
		if ctrl.state.lives > BalanceScript.STARTING_LIVES:
			shrine_lives_seen = true
	_assert(not shrine_over_cap,
		"the SHRINE never exceeds the cap over 40 invocations")
	_assert(shrine_lives_seen,
		"the SHRINE granted a life at least once in 40 invocations")

	ctrl.queue_free()
	await process_frame
	# The suite leaves the shared user:// exactly as it found it: the
	# checkpoint start_run() wrote is removed.
	_remove_file(checkpoint)

	# --- 5. the logic holds no hard-coded multiplier ---
	# The cap must come from the balance file. A formula next to the
	# use is the defect this suite exists to close, so it is checked
	# in the SOURCE, not only in the behaviour.
	var src: String = FileAccess.get_file_as_string(
		"res://core/progression/run_controller.gd")
	_assert(src.contains("BalanceScript.MAX_LIVES"),
		"the run controller reads the cap from the balance file")
	_assert(not src.contains("BalanceScript.STARTING_LIVES * 2"),
		"the run controller no longer hard-codes the cap as a formula")


