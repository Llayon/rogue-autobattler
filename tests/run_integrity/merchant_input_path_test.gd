extends SceneTree

## RUN-ENTRY-02: the merchant input path.
##
## The shop scene closes on SPACE and on ESC:
##
##     match event.keycode:
##         KEY_ESCAPE, KEY_SPACE:
##             if visible:
##                 _on_close_pressed()
##             get_viewport().set_input_as_handled()
##
## The battle scene starts a battle on SPACE:
##
##     KEY_SPACE:
##         if run_controller.phase == RunController.Phase.PREP:
##             run_controller.start_battle()
##
## The two handlers must not both consume the same event. The shop
## scene calls `set_input_as_handled()`, but the ORDER of the
## `_unhandled_input` dispatch decides whether that helps: Godot
## delivers the event to the nodes in the reverse order of their
## place in the tree, so a scene added LATER sees it FIRST.
##
## The required behaviour:
##
##   MERCHANT visible -> SPACE -> the shop closes, the phase is MAP,
##                        NO battle starts
##   MERCHANT visible -> ESC   -> the shop closes, the phase is MAP,
##                        NO battle starts
##   a normal PREP    -> SPACE -> a valid battle starts
##   an invalid MAP   -> SPACE -> NO battle starts
##
## These are REAL input-event checks: the event is pushed through the
## viewport, not the handler called directly.

const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const BattleSceneScript = preload("res://scenes/battle/battle_scene.gd")

const ISOLATED_DIR: String = "user://run_integrity_input/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_the_merchant_space_closes_the_shop()
	await _test_B_the_merchant_escape_closes_the_shop()
	await _test_C_a_normal_prep_space_starts_the_battle()
	await _test_D_an_invalid_map_space_starts_nothing()
	print("")
	print("=== STAGE INPUT: THE MERCHANT INPUT PATH: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## Builds a battle scene and puts its OWN controller into the given
## phase.
##
## The battle scene creates its RunController in `_ready()` and drives
## it through `apply_launch_request()`, so the test uses the controller
## the scene owns -- a separate controller would not be the one the
## input path reaches.
func _build_scene(phase: int, merchant: bool) -> Array:
	var scene: Node = BattleSceneScript.new()
	get_root().add_child(scene)
	await process_frame
	var ctrl: Node = scene.run_controller
	_assert(ctrl != null, "the battle scene owns a controller")
	if ctrl == null:
		return [scene, null, null]
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR)
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]
	ctrl.start_run(880001)
	await process_frame
	ctrl._set_phase(phase)
	if merchant:
		ctrl.state.just_visited_merchant = true
		ctrl._refresh_merchant_shop()
	# The shop is VISIBLE only in the merchant case: a visible shop
	# consumes the SPACE and closes itself, so a "normal PREP" with a
	# visible shop would never reach the battle.
	var shop: Node = scene.shop_scene
	if shop != null:
		shop.visible = merchant
		shop.set_run_controller(ctrl)
	await process_frame
	return [scene, ctrl, shop]


## Pushes a real key event through the viewport.
func _press_key(keycode: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	event.echo = false
	Input.parse_input_event(event)
	await process_frame
	await process_frame


## A. MERCHANT visible -> SPACE -> the shop closes, the phase is MAP,
##    NO battle starts.
func _test_A_the_merchant_space_closes_the_shop() -> void:
	var built: Array = await _build_scene(0, true)
	var scene: Node = built[0]
	var ctrl: Node = built[1]
	var shop: Node = built[2]
	_assert(shop != null, "the shop scene exists")
	_assert(shop != null and shop.visible, "the shop is visible")
	await _press_key(KEY_SPACE)
	_assert(not shop.visible, "SPACE closes the shop")
	_assert(int(ctrl.phase) == 4, "the phase is MAP after the close")
	_assert(ctrl.runner == null, "SPACE in the merchant starts NO battle")


## B. MERCHANT visible -> ESC -> the shop closes, the phase is MAP,
##    NO battle starts.
func _test_B_the_merchant_escape_closes_the_shop() -> void:
	var built: Array = await _build_scene(0, true)
	var scene: Node = built[0]
	var ctrl: Node = built[1]
	var shop: Node = built[2]
	_assert(shop != null, "the shop scene exists")
	_assert(shop != null and shop.visible, "the shop is visible")
	await _press_key(KEY_ESCAPE)
	_assert(not shop.visible, "ESC closes the shop")
	_assert(int(ctrl.phase) == 4, "the phase is MAP after the close")
	_assert(ctrl.runner == null, "ESC in the merchant starts NO battle")


## C. A normal PREP -> SPACE -> a valid battle starts.
func _test_C_a_normal_prep_space_starts_the_battle() -> void:
	var built: Array = await _build_scene(0, false)
	var scene: Node = built[0]
	var ctrl: Node = built[1]
	await _press_key(KEY_SPACE)
	_assert(ctrl.runner != null, "SPACE in a normal PREP starts the battle")
	_assert(int(ctrl.phase) == 1, "the phase is BATTLE")


## D. An invalid MAP -> SPACE -> NO battle starts.
func _test_D_an_invalid_map_space_starts_nothing() -> void:
	var built: Array = await _build_scene(4, false)
	var scene: Node = built[0]
	var ctrl: Node = built[1]
	await _press_key(KEY_SPACE)
	_assert(ctrl.runner == null, "SPACE in a MAP starts NO battle")
	_assert(int(ctrl.phase) == 4, "the phase stays MAP")


# ----------------------------------------------------------------


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage INPUT: %s" % label)
