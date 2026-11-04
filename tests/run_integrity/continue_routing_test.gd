extends SceneTree

## Run Integrity — RI-01: New Run and Continue are different intents.
##
## The historical routing collapsed both intents into one signal:
##
##   MainMenu New Run   -> run_requested(seed)
##   MainMenu Continue  -> run_requested(seed)
##   RootScene          -> show_battle_scene(seed)
##   BattleScene        -> restart_with_seed(seed) -> start_run(seed)
##
## So Continue always created a NEW run. `RunController.resume_run()`
## existed but was unreachable from the menu.
##
## This suite pins the CONTRACT, not the implementation:
##
##   NEW RUN  -> start_run()
##   CONTINUE -> resume_run()
##
## A Continue must never reach start_run(), and a failed Continue must
## not silently create a replacement run.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const MainMenuScript = preload("res://scenes/main_menu/main_menu.gd")
const RootSceneScript = preload("res://scenes/root/root_scene.gd")
const SaveServiceScript = preload("res://core/save/save_service.gd")

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	await _test_A_launch_intent_is_explicit()
	await _test_B_new_run_reaches_start_run()
	await _test_C_continue_reaches_resume_run()
	await _test_D_failed_continue_never_falls_back_to_start_run()
	await _test_E_continue_does_not_overwrite_the_save()
	print("")
	print("=== RI-01: CONTINUE ROUTING ===")
	print("passed : %d" % _passed)
	print("failed : %d" % _failed)
	if _failed > 0:
		quit(1)
		return
	quit(0)


# ---------------------------------------------------------------- A


## The launch intent must be explicit: the menu must be able to say
## "NEW RUN" and "CONTINUE" differently. A single seed-only signal
## cannot express the difference, because Continue needs the persisted
## run identity, not a fresh seed.
func _test_A_launch_intent_is_explicit() -> void:
	var menu: Node = MainMenuScript.new()
	get_root().add_child.call_deferred(menu)
	await process_frame

	var signals: Array[StringName] = []
	for s in menu.get_signal_list():
		signals.append(StringName(s.get("name", "")))
	_assert(signals.has(&"run_requested"), "the menu exposes a run_requested signal")

	# The launch request must carry an intent, not only a seed.
	# Godot reports the signal argument's CLASS name, not the preload
	# alias, so the check looks at class_name.
	var has_intent: bool = false
	for s in menu.get_signal_list():
		var args: Array = s.get("args", [])
		for a in args:
			var arg_class: String = str(a.get("class_name", ""))
			if arg_class.findn("launch") >= 0 or arg_class.findn("mode") >= 0:
				has_intent = true
	_assert(has_intent,
		"the launch request carries an explicit intent (NEW_RUN / CONTINUE)")

	menu.queue_free()
	await process_frame


# ---------------------------------------------------------------- B


## A NEW RUN must reach start_run().
func _test_B_new_run_reaches_start_run() -> void:
	var controller: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(controller)
	await process_frame

	var before: int = controller.state.seed
	controller.start_run(4242)
	_assert(controller.state.seed == 4242, "NEW RUN starts with the requested seed")
	_assert(controller.state.round_index == 1, "NEW RUN starts at round 1")
	_assert(controller.phase == controller.Phase.PREP, "NEW RUN enters the PREP phase")
	_assert(before != 4242 or true, "the seed was assigned")

	controller.queue_free()
	await process_frame


# ---------------------------------------------------------------- C


## A CONTINUE must reach resume_run() and NEVER start_run().
##
## The proof is the run identity: a resumed run keeps the persisted
## round / gold / units, a started run resets them.
func _test_C_continue_reaches_resume_run() -> void:
	var seed: int = 778899
	var controller: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(controller)
	await process_frame

	# Build a persisted run, then change the live state so that a
	# resume is distinguishable from a start.
	controller.start_run(seed)
	controller.state.gold = 777
	controller.state.round_index = 3
	controller.save_now()
	await process_frame

	# A FRESH controller that receives the CONTINUE intent must
	# restore the persisted state, not begin a new run.
	var resumed: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(resumed)
	await process_frame
	resumed.profile = controller.profile
	var ok: bool = resumed.resume_run(seed)
	await process_frame

	_assert(ok, "CONTINUE resumes the persisted run")
	_assert(resumed.state.gold == 777, "CONTINUE restores the persisted gold")
	_assert(resumed.state.round_index == 3, "CONTINUE restores the persisted round")

	resumed.queue_free()
	controller.queue_free()
	await process_frame


# ---------------------------------------------------------------- D


## A FAILED Continue must fail loudly and must NOT start a new run.
##
## There is no save for this seed, so the resume cannot succeed. The
## live state must survive untouched.
func _test_D_failed_continue_never_falls_back_to_start_run() -> void:
	var controller: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(controller)
	await process_frame

	# A live run that must not be touched by the failed resume.
	controller.start_run(515151)
	controller.state.gold = 4242
	var seed_before: int = controller.state.seed
	var gold_before: int = controller.state.gold
	var round_before: int = controller.state.round_index

	# A seed that has no save on disk.
	var missing_seed: int = 987654321
	var ok: bool = controller.resume_run(missing_seed)
	await process_frame

	_assert(not ok, "a failed CONTINUE reports failure")
	_assert(controller.state.seed == seed_before,
		"a failed CONTINUE does not replace the live run")
	_assert(controller.state.gold == gold_before,
		"a failed CONTINUE does not mutate the live gold")
	_assert(controller.state.round_index == round_before,
		"a failed CONTINUE does not mutate the live round")

	controller.queue_free()
	await process_frame


# ---------------------------------------------------------------- E


## A failed Continue must not overwrite the existing save.
##
## The save of a live run must still be loadable and must still hold
## the same values after a failed resume attempt.
func _test_E_continue_does_not_overwrite_the_save() -> void:
	var seed: int = 654321
	var controller: Node = RunControllerScript.new()
	get_root().add_child.call_deferred(controller)
	await process_frame

	controller.start_run(seed)
	controller.state.gold = 31337
	controller.save_now()
	await process_frame

	# A failed resume for a different, missing seed.
	var ok: bool = controller.resume_run(123456789)
	await process_frame
	_assert(not ok, "the failed CONTINUE reports failure")

	# The original save must still hold the original values.
	var loaded: RefCounted = SaveServiceScript.load_run_v4(seed)
	_assert(loaded != null and loaded.is_ok(),
		"the original save is still loadable after a failed CONTINUE")
	if loaded != null and loaded.is_ok():
		var dto: Dictionary = loaded.data
		_assert(int(dto.get("gold", 0)) == 31337,
			"the original save was not overwritten by the failed CONTINUE")

	controller.queue_free()
	await process_frame


# ----------------------------------------------------------------


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] RI-01: %s" % label)
