extends SceneTree

## RI-09 (second round): the item rewards must survive the phase
## guards.
##
## The independent critic of the RI-09 package found two HIGH
## defects, both proven at runtime:
##
## HIGH-1: the TREASURE map node grants an item through `grant_item`,
##        and the call happens while the phase is still MAP. The
##        matrix made `grant_item` PREP-only, so the guard refused it
##        and the treasure's random item was silently lost.
##
## HIGH-2: the post-victory combat drop grants an item through
##        `grant_item`, and the call happens while the phase is still
##        BATTLE (the outcome is applied before the phase changes). The
##        guard refused it, so the 35% drop never landed.
##
## The rule the two cases share: the PLAYER-FACING command is PREP
## only, and the game's own reward delivery goes through an INTERNAL
## grant that is not a command and therefore has no phase guard.
##
## The invariant:
##
##   the TREASURE node grants its item in the MAP phase
##   the combat drop grants its item in the BATTLE phase
##   the player-facing grant_item command is still PREP-only

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")
const BalanceScript = preload("res://core/balance.gd")

const ISOLATED_DIR: String = "user://run_integrity_ri09_drops/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_the_combat_drop_lands()
	await _test_B_the_treasure_item_lands()
	await _test_C_the_command_is_still_prep_only()
	print("")
	print("=== STAGE 4F: THE ITEM REWARDS SURVIVE: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## The post-victory combat drop must land.
##
## The drop rolls `MAP_COMBAT_DROP_CHANCE`, so the test drives many
## seeds and requires that the drop lands in at least one of them: the
## point is that the PATH works, not that every battle drops.
func _test_A_the_combat_drop_lands() -> void:
	var drops: int = 0
	var battles: int = 0
	for s in range(20):
		var ctrl: Node = await _make_controller(610001 + s)
		ctrl.start_battle()
		await process_frame
		for combatant in ctrl.runner.ctx.combatants_of_team(1):
			combatant.health.current_hp = 0
		ctrl.runner._cleanup_dead()
		ctrl.runner._end_battle()
		var before: int = ctrl.state.items.size()
		# The outcome is applied while the phase is still BATTLE.
		_assert(ctrl.phase == ctrl.Phase.BATTLE,
			"the outcome is applied in the battle phase")
		ctrl.tick_battle(0.016)
		await process_frame
		battles += 1
		if ctrl.state.items.size() > before:
			drops += 1
	_assert(battles > 0, "the battles were fought")
	_assert(drops > 0,
		"the combat drop lands through the real battle path (got %d of %d)"
			% [drops, battles])


## The TREASURE node must grant its item.
func _test_B_the_treasure_item_lands() -> void:
	var granted: int = 0
	var tried: int = 0
	for s in range(30):
		var ctrl: Node = await _make_controller(610101 + s)
		ctrl._enter_map()
		var clicked: bool = false
		for _step in 12:
			var ids: Array = ctrl.encounter_map.get_available_next_ids()
			if ids.is_empty():
				break
			var picked: int = -1
			for nid in ids:
				var node: Object = ctrl.encounter_map.get_node(nid)
				if node != null and node.type == EncounterTypeScript.Kind.TREASURE:
					picked = int(nid)
					break
			if picked < 0:
				picked = int(ids[0])
			var before: int = ctrl.state.items.size()
			ctrl._on_node_selected(picked)
			var chosen: Object = ctrl.encounter_map.get_node(picked)
			if chosen != null and chosen.type == EncounterTypeScript.Kind.TREASURE:
				tried += 1
				if ctrl.state.items.size() > before:
					granted += 1
				clicked = true
				break
			# A combat node moved the run into a battle.
			if ctrl.phase != ctrl.Phase.MAP:
				break
		if tried > 0 and granted > 0:
			break
		if not clicked and tried == 0:
			continue
	_assert(tried > 0,
		"a treasure node was reached through the real map flow")
	_assert(granted > 0,
		"the treasure grants its item in the map phase (got %d of %d)"
			% [granted, tried])


## The player-facing command is still PREP-only: the fix must not open
## the door the RI-09 package closed.
func _test_C_the_command_is_still_prep_only() -> void:
	var ctrl: Node = await _make_controller(610201)
	_assert(ctrl.grant_item(&"potion_strength"),
		"the command works in PREP")
	ctrl.start_battle()
	await process_frame
	_assert(not ctrl.grant_item(&"potion_strength"),
		"the command is refused in a battle")
	ctrl._enter_map()
	_assert(not ctrl.grant_item(&"potion_strength"),
		"the command is refused in the map phase")


# ----------------------------------------------------------------


func _make_controller(seed_value: int) -> Node:
	var ctrl: Node = RunControllerScript.new()
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR)
	ctrl.meta_writer = _MetaWriter.new()
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer", &"cleric",
		&"mage", &"knight", &"druid"] as Array[StringName]
	ctrl.start_run(seed_value)
	await process_frame
	return ctrl


## A meta writer that does NOT touch the production meta file.
class _MetaWriter:
	extends RefCounted

	func write_meta(profile: Object) -> bool:
		return true


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage 4F: %s" % label)
