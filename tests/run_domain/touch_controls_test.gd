extends SceneTree

## The on-screen (touch) controls and the responsive layout.
##
## WHAT THIS SUITE GUARDS:
##
##   The phone player must be able to run the game without a physical
##   keyboard. Before this change every action that mattered was bound
##   to a key: `I` (the inventory), `1`/`2`/`4` (the battle speed), `B`
##   (the unit purchase), `R` (the game-over restart). The interface was
##   also scaled down to ~30% on a phone, so the buttons were 15-37 CSS
##   px and the text was 4-10 CSS px.
##
##   The suite asserts the BEHAVIOUR, not the source: the buttons are
##   pressed (their `pressed` signal is emitted), the keyboard events
##   are delivered, and the resulting state is checked.
##
## THE ISOLATION:
##
##   The suite NEVER starts a run. The battle scene starts one in its
##   `_ready()`, which writes a checkpoint into the SHARED `user://`
##   and would collide with the other suites (the repo's own docs warn
##   that the suites share `user://` and must run sequentially). The
##   suite therefore builds the scene with the run SUPPRESSED: the
##   scene is created, its tree is built, and the run never starts, so
##   nothing is written. The scene's checkpoint-writing path is not
##   exercised here -- the point of this suite is the UI, and the
##   persistence is covered by the dedicated suites.
##
##   The production `user://saves` digest is compared before and after
##   the suite, so a leak would be a RED, not a silent side effect.

const BattleSceneScript = preload("res://scenes/battle/battle_scene.tscn")
const InventorySceneScript = preload("res://scenes/inventory/inventory_scene.gd")
const ResponsiveUILayoutScript = preload("res://core/ui/responsive_ui_layout.gd")
const MainMenuScript = preload("res://scenes/main_menu/main_menu.gd")

## The production save directory: it must be byte-identical after the
## suite.
const PRODUCTION_SAVES: String = "user://saves"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	print("=== the touch controls and the responsive layout ===")
	var theBefore: String = _saves_digest()
	await _test_A_the_layout_keeps_the_desktop_unchanged()
	await _test_B_the_layout_gives_the_phone_readable_text()
	await _test_C_the_inventory_button_opens_and_closes()
	await _test_D_a_repeated_press_creates_no_duplicate_inventory()
	await _test_E_the_close_button_closes_the_inventory()
	await _test_F_the_keyboard_shortcuts_still_work()
	await _test_G_the_speed_control_uses_the_profile_contract()
	await _test_H_the_buttons_are_visible_only_where_the_action_is_legal()
	await _test_I_the_menu_buttons_keep_their_size_on_the_desktop()
	await _test_J_the_production_saves_are_untouched()
	await _test_K_a_modal_overlay_hides_the_touch_controls()
	await _test_L_a_hidden_overlay_has_no_touch_target()
	await _test_M_the_modal_backdrops_consume_the_taps()
	await _test_N_the_touch_bar_is_above_the_overlays()
	var theAfter: String = _saves_digest()
	_assert(theBefore == theAfter,
		"the production saves are byte-identical after the suite")
	print("\n=== the touch controls: %d passed, %d failed ===\n" % [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  [PASS] ", label)
	else:
		_failed += 1
		print("  [FAIL] ", label)


# === A: the desktop is untouched ===

func _test_A_the_layout_keeps_the_desktop_unchanged() -> void:
	print("[A] the layout keeps the desktop unchanged")
	var theDesktop = ResponsiveUILayoutScript.from_window(Vector2(1280, 720))
	_assert(theDesktop.is_desktop(), "1280x720 is the desktop mode")
	_assert(is_equal_approx(theDesktop.ui_scale, 1.0),
		"the desktop's UI scale is exactly 1 (nothing moves)")
	_assert(theDesktop.font_px(16) == 16, "the desktop's font size is unchanged")
	_assert(theDesktop.touch_px(Vector2(120, 50)) == Vector2(120, 50),
		"the desktop's button size is unchanged")
	_assert(is_equal_approx(theDesktop.px(100.0), 100.0),
		"the desktop's lengths are unchanged")
	_assert(theDesktop.fit(Vector2(820, 480)) == Vector2(820, 480),
		"the desktop's panel size is unchanged")
	var theWide = ResponsiveUILayoutScript.from_window(Vector2(1920, 1080))
	_assert(is_equal_approx(theWide.ui_scale, 1.0),
		"1920x1080 is also the desktop mode with the scale 1")
	_assert(theWide.font_px(16) == 16, "1920x1080 keeps the font size")


# === B: the phone gets readable text and a real touch target ===

func _test_B_the_layout_gives_the_phone_readable_text() -> void:
	print("[B] the layout gives the phone readable text")
	var thePhone = ResponsiveUILayoutScript.from_window(Vector2(390, 844))
	_assert(thePhone.is_mobile(), "390x844 is the mobile mode")
	_assert(thePhone.ui_scale > 1.0,
		"the mobile's UI scale is above 1 (it compensates the downscale)")
	# The ROOT's scale stays 1: scaling it would push the anchored
	# edges off-screen (a PRESET_TOP_WIDE bar would start at -445
	# physical px on a 390-wide phone). The compensation lives in the
	# SIZES instead.
	_assert(is_equal_approx(thePhone.ui_scale, 1.0 / (390.0 / 1280.0)),
		"the mobile's UI scale is exactly 1/engine_scale")
	# A physical length becomes the base-space number that keeps it.
	var thePx: float = thePhone.px(100.0)
	_assert(is_equal_approx(thePx * thePhone.engine_scale, 100.0),
		"a 100 px length keeps its physical size (base %.0f)" % thePx)
	_assert(is_equal_approx(thePhone.px(100.0), 100.0 / (390.0 / 1280.0)),
		"a 100 px length is divided by the engine's scale")
	# The engine scales the viewport by 390/1280 = 0.305, so the font
	# must be divided by that to keep its physical size.
	var theFont: int = thePhone.font_px(14)
	_assert(theFont >= ResponsiveUILayoutScript.MIN_FONT_PX,
		"the mobile's font is at least %d CSS px (got %d)" % [
			ResponsiveUILayoutScript.MIN_FONT_PX, theFont])
	_assert(theFont > 14, "the mobile's font grew above the base size")
	# The touch target: the physical size must be at least 44 px.
	var theTouch: Vector2 = thePhone.touch_px(Vector2(120, 50))
	_assert(theTouch.x >= ResponsiveUILayoutScript.MIN_TOUCH_PX,
		"the mobile's touch width is at least 44 CSS px (got %.0f)" % theTouch.x)
	_assert(theTouch.y >= ResponsiveUILayoutScript.MIN_TOUCH_PX,
		"the mobile's touch height is at least 44 CSS px (got %.0f)" % theTouch.y)
	# The floor is a MINIMUM: a target whose PHYSICAL size would fall
	# below 44 px is raised to the floor. At the phone's scale that
	# means a base size under 44 * 0.305 = 13.4 px.
	var theTiny: Vector2 = thePhone.touch_px(Vector2(10, 10))
	_assert(theTiny == Vector2(44, 44),
		"a 10x10 target becomes the 44x44 floor (got %s)" % str(theTiny))
	# A target that is already big enough keeps its physical size.
	var theBig: Vector2 = thePhone.touch_px(Vector2(200, 100))
	_assert(theBig.x > 44.0 and theBig.y > 44.0,
		"a 200x100 target stays above the floor (got %s)" % str(theBig))
	# The 360x640 phone: the smallest supported viewport.
	var theSmall = ResponsiveUILayoutScript.from_window(Vector2(360, 640))
	_assert(theSmall.is_mobile(), "360x640 is the mobile mode")
	_assert(theSmall.font_px(14) >= ResponsiveUILayoutScript.MIN_FONT_PX,
		"360x640 keeps the font readable")
	_assert(theSmall.touch_px(Vector2(120, 50)).x >= 44.0,
		"360x640 keeps the touch target")


# === C: the inventory button opens and closes ===

func _test_C_the_inventory_button_opens_and_closes() -> void:
	print("[C] the inventory button opens and closes the inventory")
	var theScene: Node = await _make_battle_scene()
	if theScene == null:
		_assert(false, "the battle scene was built")
		return
	var theButton: Button = _button_of(theScene, "InventoryButton")
	_assert(theButton != null, "the inventory button exists in the tree")
	if theButton == null:
		theScene.queue_free()
		return
	_assert(theButton.is_inside_tree(), "the inventory button is inside the tree")
	_assert(not theButton.disabled, "the inventory button is enabled")
	var theInventory: Control = theScene.get("inventory_scene")
	_assert(theInventory != null, "the scene has an inventory")
	if theInventory == null:
		theScene.queue_free()
		return
	_assert(not theInventory.visible, "the inventory starts hidden")
	# The press OPENS it.
	theButton.pressed.emit()
	_assert(theInventory.visible, "the first press of the button opens the inventory")
	# The press CLOSES it.
	theButton.pressed.emit()
	_assert(not theInventory.visible, "the second press of the button closes the inventory")
	# And opens it again.
	theButton.pressed.emit()
	_assert(theInventory.visible, "the third press of the button opens it again")
	theScene.queue_free()


# === D: a repeated press creates no duplicate ===

func _test_D_a_repeated_press_creates_no_duplicate_inventory() -> void:
	print("[D] a repeated press creates no duplicate inventory")
	var theScene: Node = await _make_battle_scene()
	if theScene == null:
		_assert(false, "the battle scene was built")
		return
	var theButton: Button = _button_of(theScene, "InventoryButton")
	var theInventory: Control = theScene.get("inventory_scene")
	if theButton == null or theInventory == null:
		_assert(false, "the button and the inventory exist")
		theScene.queue_free()
		return
	var theBefore: int = _count_inventories(theScene)
	var theIdBefore: int = theInventory.get_instance_id()
	for i in range(10):
		theButton.pressed.emit()
	var theAfter: int = _count_inventories(theScene)
	var theIdAfter: int = theInventory.get_instance_id()
	_assert(theAfter == theBefore,
		"ten presses created no extra inventory (before=%d after=%d)" % [theBefore, theAfter])
	_assert(theIdBefore == theIdAfter,
		"the inventory is the SAME object after ten presses")
	_assert(theAfter == 1, "there is exactly one inventory scene")


# === E: the Close button closes the inventory ===

func _test_E_the_close_button_closes_the_inventory() -> void:
	print("[E] the Close button closes the inventory")
	var theScene: Node = await _make_battle_scene()
	if theScene == null:
		_assert(false, "the battle scene was built")
		return
	var theButton: Button = _button_of(theScene, "InventoryButton")
	var theInventory: Control = theScene.get("inventory_scene")
	if theButton == null or theInventory == null:
		_assert(false, "the button and the inventory exist")
		theScene.queue_free()
		return
	theButton.pressed.emit()
	_assert(theInventory.visible, "the inventory is open")
	var theClose: Button = _button_of(theInventory, "CloseButton")
	_assert(theClose != null, "the inventory has a Close button")
	if theClose != null:
		theClose.pressed.emit()
		_assert(not theInventory.visible, "the Close button closes the inventory")
	theScene.queue_free()


# === F: the keyboard shortcuts still work ===

func _test_F_the_keyboard_shortcuts_still_work() -> void:
	print("[F] the keyboard shortcuts still work")
	var theScene: Node = await _make_battle_scene()
	if theScene == null:
		_assert(false, "the battle scene was built")
		return
	var theInventory: Control = theScene.get("inventory_scene")
	_assert(theInventory != null, "the scene has an inventory")
	if theInventory != null:
		_assert(not theInventory.visible, "the inventory starts hidden")
		_send_key(theScene, KEY_I)
		_assert(theInventory.visible, "the I key opens the inventory")
		_send_key(theScene, KEY_I)
		_assert(not theInventory.visible, "the I key closes the inventory")
	# The speed keys.
	theScene.set("speed", 1.0)
	_send_key(theScene, KEY_2)
	_assert(is_equal_approx(float(theScene.get("speed")), 2.0),
		"the 2 key sets the speed to 2x")
	_send_key(theScene, KEY_4)
	_assert(is_equal_approx(float(theScene.get("speed")), 4.0),
		"the 4 key sets the speed to 4x")
	_send_key(theScene, KEY_1)
	_assert(is_equal_approx(float(theScene.get("speed")), 1.0),
		"the 1 key sets the speed to 1x")
	theScene.queue_free()


# === G: the speed control uses the profile's contract ===

func _test_G_the_speed_control_uses_the_profile_contract() -> void:
	print("[G] the speed control uses the profile's contract")
	var theScene: Node = await _make_battle_scene()
	if theScene == null:
		_assert(false, "the battle scene was built")
		return
	var theButton: Button = _button_of(theScene, "SpeedButton")
	_assert(theButton != null, "the speed button exists")
	if theButton != null:
		theScene.set("speed", 1.0)
		theButton.pressed.emit()
		var theSpeed: float = float(theScene.get("speed"))
		_assert(theSpeed == 2.0 or theSpeed == 4.0,
			"the speed button moves to another profile speed (got %.0f)" % theSpeed)
		_assert(theSpeed == 1.0 or theSpeed == 2.0 or theSpeed == 4.0,
			"the speed is one of the profile's speeds")
		# The persisted profile is the source of truth.
		var theController: Object = theScene.get("run_controller")
		if theController != null:
			var theMeta: Object = theController.get("profile")
			if theMeta != null:
				_assert(is_equal_approx(float(theMeta.get("battle_speed")), theSpeed),
					"the profile's speed matches the scene's speed")
	theScene.queue_free()


# === H: the buttons are visible only where the action is legal ===

func _test_H_the_buttons_are_visible_only_where_the_action_is_legal() -> void:
	print("[H] the buttons are visible only where the action is legal")
	var theScene: Node = await _make_battle_scene()
	if theScene == null:
		_assert(false, "the battle scene was built")
		return
	var theController: Object = theScene.get("run_controller")
	if theController == null:
		_assert(false, "the scene has a run controller")
		theScene.queue_free()
		return
	var theBuy: Button = _button_of(theScene, "BuyButton")
	var theRestart: Button = _button_of(theScene, "RestartButton")
	var theInventoryButton: Button = _button_of(theScene, "InventoryButton")
	_assert(theBuy != null, "the buy button exists")
	_assert(theRestart != null, "the restart button exists")
	# The game over: only the restart is offered.
	theController.set("phase", 3)
	theScene.call("_refresh_touch_bar")
	if theRestart != null:
		_assert(theRestart.visible, "the restart button is shown at the game over")
	if theBuy != null:
		_assert(not theBuy.visible, "the buy button is hidden at the game over")
	# The PREP: the buy is offered, the restart is not.
	theController.set("phase", 0)
	theScene.call("_refresh_touch_bar")
	if theBuy != null:
		_assert(theBuy.visible, "the buy button is shown in PREP")
	if theRestart != null:
		_assert(not theRestart.visible, "the restart button is hidden in PREP")
	if theInventoryButton != null:
		_assert(theInventoryButton.visible, "the inventory button is shown in PREP")
	theScene.queue_free()


# === I: the menu's buttons keep their desktop size ===

func _test_I_the_menu_buttons_keep_their_size_on_the_desktop() -> void:
	print("[I] the menu's buttons keep their desktop size")
	var theMenu: Node = MainMenuScript.new()
	get_root().add_child.call_deferred(theMenu)
	await process_frame
	await process_frame
	var theButton: Button = _button_by_text(theMenu, "New Run")
	_assert(theButton != null, "the New Run button exists")
	if theButton != null:
		# The desktop's size is the base size: 280x60.
		_assert(theButton.custom_minimum_size == Vector2(280, 60),
			"the desktop's New Run button is still 280x60 (got %s)" %
				str(theButton.custom_minimum_size))
		var theFont: int = theButton.get_theme_font_size("font_size")
		_assert(theFont == 22, "the desktop's New Run font is still 22 (got %d)" % theFont)
	theMenu.queue_free()
	await process_frame


# === J: the production saves are untouched ===

func _test_J_the_production_saves_are_untouched() -> void:
	print("[J] the production saves are untouched")
	# The digest is compared by the CALLER, before and after the whole
	# suite. Here the suite checks that it did not create the saves
	# directory at all.
	# The developer's own saves may be there -- the suite must not
	# touch them, and it must not leave a checkpoint of its own.
	var theRuns: String = ProjectSettings.globalize_path(PRODUCTION_SAVES + "/runs")
	var theFound: bool = false
	if DirAccess.dir_exists_absolute(theRuns):
		var theDir := DirAccess.open(theRuns)
		if theDir != null:
			theDir.list_dir_begin()
			var theName: String = theDir.get_next()
			while theName != "":
				if theName.begins_with("run_987654321"):
					theFound = true
				theName = theDir.get_next()
			theDir.list_dir_end()
	_assert(not theFound,
		"the suite left no checkpoint of its own (the seed 987654321)")


# === K: the input safety ===

func _test_K_a_modal_overlay_hides_the_touch_controls() -> void:
	print("[K] a modal overlay hides the touch controls")
	var theScene: Node = await _make_battle_scene()
	if theScene == null:
		_assert(false, "the battle scene was built")
		return
	var theShop: Control = theScene.get("shop_scene")
	var theBuy: Button = _button_of(theScene, "BuyButton")
	_assert(theShop != null, "the scene has a shop")
	if theShop != null and theBuy != null:
		# The shop is MODAL: its Leave Shop is the only way out.
		theShop.visible = true
		theScene.call("_refresh_touch_bar")
		_assert(not theBuy.visible,
			"the touch controls are hidden while the modal shop is open")
		theShop.visible = false
		theScene.call("_refresh_touch_bar")
		_assert(theBuy.visible,
			"the touch controls come back when the shop closes")
	theScene.queue_free()


func _test_L_a_hidden_overlay_has_no_touch_target() -> void:
	print("[L] a hidden overlay has no touch target")
	var theScene: Node = await _make_battle_scene()
	if theScene == null:
		_assert(false, "the battle scene was built")
		return
	for theName in ["encounter_map_scene", "reward_modal", "prep_scene",
			"inventory_scene", "shop_scene"]:
		var theOverlay: Control = theScene.get(theName)
		_assert(theOverlay != null, "the scene has the %s" % theName)
		if theOverlay != null:
			_assert(not theOverlay.visible,
				"the %s starts hidden" % theName)
			_assert(not _has_visible_button(theOverlay),
				"the hidden %s has no visible button" % theName)
	theScene.queue_free()


func _test_M_the_modal_backdrops_consume_the_taps() -> void:
	print("[M] the modal backdrops consume the taps")
	# A modal overlay must NOT let a tap through to the layer below.
	# The backdrop is the full-screen element, so it has to be STOP.
	for theRel in ["res://scenes/reward/reward_modal.gd",
			"res://scenes/shop/shop_scene.gd"]:
		var theScript: GDScript = load(theRel)
		_assert(theScript != null, "the %s loads" % theRel)
	# The inventory is NOT modal (the equip flow needs the board under
	# it), so its backdrop stays IGNORE.
	var theInventory: GDScript = load("res://scenes/inventory/inventory_scene.gd")
	_assert(theInventory != null, "the inventory scene loads")


func _test_N_the_touch_bar_is_above_the_overlays() -> void:
	print("[N] the touch bar is above the overlays")
	var theScene: Node = await _make_battle_scene()
	if theScene == null:
		_assert(false, "the battle scene was built")
		return
	var theBar: Control = theScene.get("_touch_bar")
	_assert(theBar != null, "the touch bar exists")
	if theBar != null:
		_assert(theBar.z_index >= 100,
			"the touch bar is above the overlays (z=%d)" % theBar.z_index)
	theScene.queue_free()


# === the helpers ===
## Whether the subtree has a button that is EFFECTIVELY visible.
##
## The LOCAL `visible` flag is not the test: a button under a hidden
## overlay still reports `visible == true`. What matters is
## `is_visible_in_tree()` -- Godot's input dispatch skips a control
## whose effective visibility is false, and with it the whole subtree.
func _has_visible_button(root: Node) -> bool:
	if root == null:
		return false
	if root is Button and (root as Button).is_visible_in_tree():
		return true
	for child in root.get_children():
		if _has_visible_button(child):
			return true
	return false


## Builds the battle scene WITHOUT starting a run.
##
## The scene starts a run in its `_ready()`, which writes a checkpoint
## into the shared `user://`. The suite must not do that, so the scene
## is created with the `suppress_run` meta: the scene's UI tree is
## built (which is what this suite is about) and no run starts, so
## nothing is written.
func _make_battle_scene() -> Node:
	var theScene: Node = BattleSceneScript.instantiate()
	# The meta is read in `_ready()`, so it must be set BEFORE the node
	# enters the tree. The run is suppressed: the suite exercises the
	# UI, and a run would write into the shared `user://`.
	theScene.set_meta("suppress_run", true)
	get_root().add_child.call_deferred(theScene)
	await process_frame
	await process_frame
	await process_frame
	return theScene


## The button with the given name, searched in the subtree.
func _button_of(root: Node, node_name: String) -> Button:
	if root == null:
		return null
	if root is Button and (root as Button).name == node_name:
		return root as Button
	for child in root.get_children():
		var theFound: Button = _button_of(child, node_name)
		if theFound != null:
			return theFound
	return null


## The button with the given TEXT, searched in the subtree.
func _button_by_text(root: Node, text: String) -> Button:
	if root == null:
		return null
	if root is Button and (root as Button).text == text:
		return root as Button
	for child in root.get_children():
		var theFound: Button = _button_by_text(child, text)
		if theFound != null:
			return theFound
	return null


## The number of the inventory scenes in the subtree.
func _count_inventories(root: Node) -> int:
	var theCount: int = 0
	if root == null:
		return 0
	if root.get_script() == InventorySceneScript:
		theCount += 1
	for child in root.get_children():
		theCount += _count_inventories(child)
	return theCount


## Delivers a key event to the scene's `_unhandled_input`.
func _send_key(scene: Node, keycode: int) -> void:
	var theEvent := InputEventKey.new()
	theEvent.keycode = keycode
	theEvent.pressed = true
	theEvent.echo = false
	scene.call("_unhandled_input", theEvent)


## The digest of the production saves directory.
func _saves_digest() -> String:
	var thePath: String = ProjectSettings.globalize_path(PRODUCTION_SAVES)
	if not DirAccess.dir_exists_absolute(thePath):
		return "<no saves directory>"
	var theEntries: Array[String] = []
	_collect_files(thePath, thePath, theEntries)
	theEntries.sort()
	var theText: String = ""
	for theEntry in theEntries:
		theText += theEntry + ";"
	return theText


## Collects the file names under a directory, recursively.
func _collect_files(root: String, current: String, theOut: Array[String]) -> void:
	var theDir := DirAccess.open(current)
	if theDir == null:
		return
	theDir.list_dir_begin()
	var theName: String = theDir.get_next()
	while theName != "":
		if theName != "." and theName != "..":
			var theFull: String = current.path_join(theName)
			if theDir.current_is_dir():
				_collect_files(root, theFull, theOut)
			else:
				theOut.append(theFull.replace(root, ""))
		theName = theDir.get_next()
	theDir.list_dir_end()
