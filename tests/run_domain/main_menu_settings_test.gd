extends SceneTree

## The main menu's Settings: the button, the panel, and the speed.
##
## THE DEFECT THIS SUITE GUARDS:
##
##   `_build_vbox()` never CREATED the settings button. The member was
##   declared, `_on_settings_pressed()` existed, the panel existed --
##   and none of it was reachable, because the button that opens the
##   panel was never added to the tree. The whole settings feature was
##   dead code: the player could not reach it at all.
##
## The suite also guards the two things that would break the feature
## again:
##
##   the panel must live INSIDE the menu's vbox. Positioned against
##   the root Control it could cover the New Run and Continue buttons;
##   inside the vbox it is laid out with the menu.
##
##   a failed write must NOT be shown as a saved speed. The profile
##   keeps the value it had, so the menu never shows a speed that is
##   not on the disk.
##
## THE ISOLATION:
##
##   The suite NEVER writes `user://saves/meta.tres`. The menu's
##   persistence seam is injected with a writer and a reader that
##   point at `user://main_menu_settings_test/`, and the production
##   meta file's digest is checked before and after -- so a leak
##   would be a RED, not a silent side effect.

const MainMenuScript = preload("res://scenes/main_menu/main_menu.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")

## The isolated directory. It carries the run's own id, so two
## concurrent runs -- the repo's own docs warn that the suites share
## `user://` and must run sequentially -- cannot race on one file.
## It is removed when the suite ends.
const ISOLATED_DIR_BASE: String = "user://main_menu_settings_test/"

var _isolated_dir: String = ""
var _isolated_parent: String = ""
const PRODUCTION_META: String = "user://saves/meta.tres"

var _passed: int = 0
var _failed: int = 0


## The persistence seam: writes and reads inside the isolated
## directory. It is the SAME shape the RunController's `meta_writer`
## uses, so the menu's seam is not a special case.
class IsolatedMeta:
	extends RefCounted

	var _path: String = ""

	func _init(base_dir: String) -> void:
		_path = base_dir + "meta.tres"

	func write_meta(profile: MetaProfile) -> bool:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_path.get_base_dir()))
		return ResourceSaver.save(profile, _path) == OK

	func read_meta() -> MetaProfile:
		if not FileAccess.file_exists(_path):
			return null
		var res: Resource = load(_path)
		if res is MetaProfile:
			return res
		return null


## A writer that ALWAYS fails. The menu must not show a speed as
## saved when the write did not land.
class FailingMeta:
	extends RefCounted

	func write_meta(profile: MetaProfile) -> bool:
		return false

	func read_meta() -> MetaProfile:
		return null


func _initialize() -> void:
	# A directory of this run's own, removed at the end.
	_isolated_parent = ISOLATED_DIR_BASE + str(get_instance_id()) + "/"
	_isolated_dir = _isolated_parent
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_isolated_dir))
	var production_before: String = _production_meta_digest()
	await _test_A_the_settings_button_exists_and_is_reachable()
	await _test_B_the_panel_opens_and_closes()
	await _test_C_the_panel_lives_inside_the_menu_vbox()
	await _test_D_repeated_opening_creates_no_duplicate()
	await _test_E_the_panel_has_exactly_three_switches()
	await _test_F_the_speed_is_persisted_and_restored()
	await _test_G_a_failed_write_is_not_shown_as_saved()
	await _test_H_the_new_run_and_continue_keep_their_logic()
	await _test_I_the_production_meta_is_untouched()
	var production_after: String = _production_meta_digest()
	_assert(production_before == production_after,
		"the production meta.tres is byte-identical after the suite")
	# The isolated directory is this run's own, and it goes away with
	# it: the suite leaves nothing behind in the shared user data
	# directory.
	_remove_isolated_dir()
	print("\n=== main menu settings: %d passed, %d failed ===\n" % [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  [OK]   %s" % label)
	else:
		_failed += 1
		print("  [FAIL] %s" % label)


## Removes this run's isolated directory, so the shared user data
## directory is left as it was found.
##
## The removal is RECURSIVE: the per-run directory holds the saved
## meta file, and `DirAccess.remove()` only removes a FILE.
func _remove_isolated_dir() -> void:
	if _isolated_dir == "":
		return
	var dir: DirAccess = DirAccess.open(_isolated_dir)
	if dir == null:
		return
	for name in dir.get_files():
		dir.remove(name)
	for name in dir.get_directories():
		_remove_tree(_isolated_dir + name)
	# And the directories themselves. `DirAccess.remove()` removes a
	# FILE; a DIRECTORY needs `remove_absolute()` on its globalised
	# path -- the per-run directory was left behind otherwise.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_isolated_dir))
	var base: DirAccess = DirAccess.open(ISOLATED_DIR_BASE)
	if base != null and base.get_directories().is_empty() and base.get_files().is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ISOLATED_DIR_BASE))


## Removes a directory and everything in it.
func _remove_tree(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	for name in dir.get_files():
		dir.remove(name)
	for name in dir.get_directories():
		_remove_tree(path + name)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## The digest of the production meta file, or "" when it does not
## exist. The suite compares it before and after, so a write that
## leaked out of the seam would be caught.
func _production_meta_digest() -> String:
	if not FileAccess.file_exists(PRODUCTION_META):
		return ""
	var file: FileAccess = FileAccess.open(PRODUCTION_META, FileAccess.READ)
	if file == null:
		return ""
	var bytes: PackedByteArray = file.get_buffer(file.get_length())
	file.close()
	return bytes.hex_encode()


## A menu wired to the isolated persistence.
func _make_menu() -> Node:
	var menu: Node = MainMenuScript.new()
	var seam: IsolatedMeta = IsolatedMeta.new(_isolated_dir)
	menu.set_meta_persistence_for_test(seam, seam)
	return menu


## The button that opens the settings.
func _settings_button_of(menu: Node) -> Button:
	return menu.get("_settings_button") as Button


## The settings panel.
func _settings_panel_of(menu: Node) -> PanelContainer:
	return menu.get("_settings_panel") as PanelContainer


## A button whose text is exactly the given one, anywhere under the
## given node. The menu's buttons live in its vbox, not in its root.
func _button_named(root: Node, text: String) -> Button:
	for child in root.get_children():
		if child is Button and (child as Button).text == text:
			return child as Button
		var found: Button = _button_named(child, text)
		if found != null:
			return found
	return null


# === A: the button exists, is visible and is reachable ===

func _test_A_the_settings_button_exists_and_is_reachable() -> void:
	print("[A] the settings button exists and is reachable")
	var menu: Node = _make_menu()
	get_root().add_child.call_deferred(menu)
	await process_frame
	await process_frame
	var button: Button = _settings_button_of(menu)
	_assert(button != null, "the settings button exists in the tree")
	if button == null:
		menu.queue_free()
		return
	_assert(button.text == "Settings", "the button is labelled 'Settings'")
	_assert(button.visible, "the settings button is visible")
	_assert(not button.disabled, "the settings button is enabled")
	_assert(button.is_inside_tree(), "the settings button is inside the tree")
	# It is a child of the menu's own layout, so it is ON the screen
	# and not somewhere off in a corner.
	var parent: Node = button.get_parent()
	_assert(parent != null and parent is VBoxContainer,
		"the settings button sits in the menu's vbox")
	menu.queue_free()


# === B: the press opens the panel, the next press closes it ===

func _test_B_the_panel_opens_and_closes() -> void:
	print("[B] the press opens the panel, the next press closes it")
	var menu: Node = _make_menu()
	get_root().add_child.call_deferred(menu)
	await process_frame
	await process_frame
	var panel: PanelContainer = _settings_panel_of(menu)
	_assert(panel != null, "the settings panel was built")
	if panel == null:
		menu.queue_free()
		return
	_assert(not panel.visible, "the panel starts hidden")
	# The BUTTON is pressed, not the handler called. The handler could
	# work while the button's signal is not connected -- and that is
	# exactly the defect this hotfix closed: a Settings button the
	# player can press and nothing happens.
	var button: Button = _settings_button_of(menu)
	_assert(button != null, "the settings button exists")
	if button == null:
		menu.queue_free()
		return
	button.pressed.emit()
	_assert(panel.visible, "the first press of the button opens the panel")
	button.pressed.emit()
	_assert(not panel.visible, "the second press of the button closes the panel")
	button.pressed.emit()
	_assert(panel.visible, "the third press of the button opens it again")
	menu.queue_free()


# === C: the panel lives inside the menu's vbox ===

func _test_C_the_panel_lives_inside_the_menu_vbox() -> void:
	print("[C] the panel lives inside the menu's vbox")
	var menu: Node = _make_menu()
	get_root().add_child.call_deferred(menu)
	await process_frame
	await process_frame
	var panel: PanelContainer = _settings_panel_of(menu)
	_assert(panel != null, "the settings panel was built")
	if panel == null:
		menu.queue_free()
		return
	_assert(panel.get_parent() != null and panel.get_parent() is VBoxContainer,
		"the panel's parent is the menu's vbox, not the root Control")
	# The panel is a SIBLING of the New Run and Continue buttons, so it
	# is laid out with them and cannot cover them.
	var vbox: VBoxContainer = panel.get_parent() as VBoxContainer
	var covers: bool = false
	for child in vbox.get_children():
		if child is Button:
			var text: String = (child as Button).text
			if text == "New Run" or text == "Continue":
				covers = true
	_assert(covers, "the New Run and Continue buttons are the panel's siblings")
	menu.queue_free()


# === D: repeated opening creates no duplicate ===

func _test_D_repeated_opening_creates_no_duplicate() -> void:
	print("[D] repeated opening creates no duplicate")
	var menu: Node = _make_menu()
	get_root().add_child.call_deferred(menu)
	await process_frame
	await process_frame
	var panel_before: PanelContainer = _settings_panel_of(menu)
	var count_before: int = _count_panels(menu)
	var button: Button = _settings_button_of(menu)
	_assert(button != null, "the settings button exists")
	if button == null:
		menu.queue_free()
		return
	for i in 5:
		button.pressed.emit()
		button.pressed.emit()
	var panel_after: PanelContainer = _settings_panel_of(menu)
	var count_after: int = _count_panels(menu)
	_assert(panel_before == panel_after, "the panel is the SAME object after ten presses")
	_assert(count_before == count_after, "no extra panel was created")
	_assert(count_after == 1, "there is exactly one settings panel")
	menu.queue_free()


## How many settings panels are in the menu's tree.
func _count_panels(root: Node) -> int:
	var total: int = 0
	for child in root.get_children():
		if child is PanelContainer:
			total += 1
		total += _count_panels(child)
	return total


# === E: the panel carries exactly three switches ===

func _test_E_the_panel_has_exactly_three_switches() -> void:
	print("[E] the panel carries exactly three switches")
	var menu: Node = _make_menu()
	get_root().add_child.call_deferred(menu)
	await process_frame
	await process_frame
	var panel: PanelContainer = _settings_panel_of(menu)
	_assert(panel != null, "the settings panel was built")
	if panel == null:
		menu.queue_free()
		return
	var switches: Array[Button] = []
	for child in panel.get_children():
		if child is VBoxContainer:
			for row in (child as VBoxContainer).get_children():
				if row is HBoxContainer:
					for cell in (row as HBoxContainer).get_children():
						if cell is Button:
							switches.append(cell as Button)
	_assert(switches.size() == 3, "the panel has exactly three speed switches (got %d)"
		% switches.size())
	var labels: Array[String] = []
	for btn in switches:
		labels.append(btn.text)
	_assert(labels.has("1x"), "the 1x switch is present")
	_assert(labels.has("2x"), "the 2x switch is present")
	_assert(labels.has("4x"), "the 4x switch is present")
	menu.queue_free()


# === F: the speed is persisted and restored ===

func _test_F_the_speed_is_persisted_and_restored() -> void:
	print("[F] the speed is persisted and restored")
	var seam: IsolatedMeta = IsolatedMeta.new(_isolated_dir)
	# A FRESH profile, so the restored value cannot be a leftover.
	var fresh: MetaProfile = MetaProfileScript.new()
	fresh.battle_speed = 1.0
	seam.write_meta(fresh)
	var menu: Node = _make_menu()
	get_root().add_child.call_deferred(menu)
	await process_frame
	await process_frame
	var profile: Object = menu.get("_profile")
	_assert(profile != null, "the menu has a profile")
	_assert(profile.battle_speed == 1.0, "the restored speed is the saved one")
	# Choose 2x.
	menu._on_speed_2_pressed()
	_assert(profile.battle_speed == 2.0, "choosing 2x updates the profile")
	var reread: MetaProfile = seam.read_meta()
	_assert(reread != null, "the profile was written")
	if reread != null:
		_assert(reread.battle_speed == 2.0,
			"the saved speed is 2x (got %s)" % str(reread.battle_speed))
	# A NEW menu reads the persisted speed.
	var second: Node = _make_menu()
	get_root().add_child.call_deferred(second)
	await process_frame
	await process_frame
	var second_profile: Object = second.get("_profile")
	_assert(second_profile.battle_speed == 2.0,
		"a fresh menu shows the persisted 2x (got %s)" % str(second_profile.battle_speed))
	# The OPENED panel shows the saved speed as the selected one.
	var panel: PanelContainer = _settings_panel_of(second)
	_assert(panel != null, "the second menu has a panel")
	if panel != null:
		second._on_settings_pressed()
		var selected: Button = _selected_speed_button(second)
		_assert(selected != null, "a speed is shown as selected")
		if selected != null:
			_assert(selected.text == "2x",
				"the selected speed is the saved 2x (got %s)" % selected.text)
	# 4x works the same way.
	second._on_speed_4_pressed()
	_assert(second_profile.battle_speed == 4.0, "choosing 4x updates the profile")
	var reread4: MetaProfile = seam.read_meta()
	if reread4 != null:
		_assert(reread4.battle_speed == 4.0, "the saved speed is 4x")
	# And 1x restores the ordinary speed.
	second._on_speed_1_pressed()
	_assert(second_profile.battle_speed == 1.0, "choosing 1x restores the ordinary speed")
	var reread1: MetaProfile = seam.read_meta()
	if reread1 != null:
		_assert(reread1.battle_speed == 1.0, "the saved speed is 1x")
	menu.queue_free()
	second.queue_free()


## The speed button that the menu shows as the selected one.
func _selected_speed_button(menu: Node) -> Button:
	var current: float = (menu.get("_profile") as MetaProfile).battle_speed
	for btn in [menu.get("_speed_1_button"), menu.get("_speed_2_button"),
			menu.get("_speed_4_button")]:
		if btn == null:
			continue
		var style: StyleBoxFlat = btn.get_theme_stylebox("normal") as StyleBoxFlat
		if style != null and style.bg_color == Color(0.40, 0.55, 0.40):
			return btn as Button
	return null


# === G: a failed write is NOT shown as a saved speed ===

func _test_G_a_failed_write_is_not_shown_as_saved() -> void:
	print("[G] a failed write is not shown as a saved speed")
	var menu: Node = MainMenuScript.new()
	var failing: FailingMeta = FailingMeta.new()
	menu.set_meta_persistence_for_test(failing, failing)
	get_root().add_child.call_deferred(menu)
	await process_frame
	await process_frame
	var profile: Object = menu.get("_profile")
	var before: float = profile.battle_speed
	menu._on_speed_4_pressed()
	_assert(profile.battle_speed == before,
		"a failed write leaves the profile's speed unchanged (got %s, was %s)"
		% [str(profile.battle_speed), str(before)])
	# And the panel does not show a speed as selected that is not
	# persisted: the selected button is the one of the OLD speed.
	var panel: PanelContainer = _settings_panel_of(menu)
	if panel != null:
		menu._on_settings_pressed()
		var selected: Button = _selected_speed_button(menu)
		if selected != null:
			var expected: String = "1x"
			if before == 2.0:
				expected = "2x"
			elif before == 4.0:
				expected = "4x"
			_assert(selected.text == expected,
				"the shown speed is the one that is persisted (got %s, expected %s)"
				% [selected.text, expected])
	menu.queue_free()


# === H: the New Run and the Continue keep their logic ===

func _test_H_the_new_run_and_continue_keep_their_logic() -> void:
	print("[H] the new run and the continue keep their logic")
	var menu: Node = _make_menu()
	get_root().add_child.call_deferred(menu)
	await process_frame
	await process_frame
	var new_run: Button = _button_named(menu, "New Run")
	var cont: Button = _button_named(menu, "Continue")
	_assert(new_run != null, "the New Run button exists")
	_assert(cont != null, "the Continue button exists")
	if new_run == null or cont == null:
		menu.queue_free()
		return
	# The Continue button is hidden when there is no checkpoint.
	_assert(not cont.visible, "the Continue button is hidden without a checkpoint")
	# New Run emits the request with the NEW_RUN intent.
	var received: Array = []
	menu.run_requested.connect(func(request: Object) -> void: received.append(request))
	new_run.pressed.emit()
	_assert(received.size() == 1, "the New Run press emits one request")
	if received.size() == 1:
		var request: Object = received[0]
		_assert(request.is_new_run(),
			"the request carries the NEW_RUN intent")
		_assert(not request.is_continue(),
			"the request is NOT a continue")
		_assert(request.seed != 0, "the request carries a seed")
	menu.queue_free()


# === I: the production meta file is untouched ===

func _test_I_the_production_meta_is_untouched() -> void:
	print("[I] the production meta file is untouched")
	# The suite wrote only through the injected seam. The production
	# file is compared by the caller, before and after the whole suite;
	# here we check that the production file was not created by the
	# suite either.
	# The production file's digest is compared by the CALLER, before
	# and after the whole suite -- that is the assertion that carries
	# the guarantee. A digest compared with a second read of the same
	# file taken microseconds later can never fail, so it is not
	# asserted here.
	# And the isolated file is where the writes landed.
	_assert(FileAccess.file_exists(_isolated_dir + "meta.tres"),
		"the writes landed in the isolated directory")
