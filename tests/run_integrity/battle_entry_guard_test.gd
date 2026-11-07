extends SceneTree

## RUN-ENTRY-01: the battle entry must be GUARDED.
##
## The baseline:
##
##     func start_battle() -> bool:
##         if phase != Phase.PREP and phase != Phase.MAP:
##             return false
##         if state.get_board_units().is_empty():
##             return false
##
## So ANY PREP or MAP with a unit on the board started a battle.
## But the phase alone is not a readiness proof:
##
##   - a PREP can be the initial preparation, a selected COMBAT, a
##     MERCHANT visit or a post-defeat preparation;
##   - a MAP means "the player must select a node", not "the battle may
##     start".
##
## The illegal paths:
##
##   MERCHANT open             -> start_battle()
##   MAP without a selection   -> start_battle()
##   MAP after a service       -> start_battle()
##   GAMEOVER                  -> start_battle()
##   REWARD                    -> start_battle()
##
## And the refusal must be ATOMIC: the phase, the map, the merchant
## offer, the merchant flag, the state, the context, the runner, the
## battle participants, the RNG, the checkpoint, the save count and the
## meta must all be UNCHANGED.
##
## The refusal must also happen BEFORE: the BattleContext creation,
## the reaction registry clearing, the enemy generation, the RNG
## consumption and the battle participant mapping.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")
const RngScript = preload("res://core/utils/rng_service.gd")

const ISOLATED_DIR: String = "user://run_integrity_entry/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_a_merchant_visit_refuses_the_battle()
	await _test_B_a_map_without_a_selection_refuses_the_battle()
	await _test_C_a_map_after_a_service_refuses_the_battle()
	await _test_D_the_terminal_phases_refuse_the_battle()
	await _test_E_the_initial_run_prep_starts_the_battle()
	await _test_F_a_selected_combat_starts_the_battle()
	await _test_G_a_selected_elite_or_boss_starts_the_battle()
	await _test_H_a_continue_after_a_selection_starts_the_battle()
	await _test_I_the_refusal_changes_nothing()
	print("")
	print("=== STAGE ENTRY: THE BATTLE ENTRY IS GUARDED: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A. A MERCHANT visit refuses the battle.
func _test_A_a_merchant_visit_refuses_the_battle() -> void:
	var ctrl: Node = await _make_controller(670101)
	# The merchant context: the phase is PREP and the flag is set.
	ctrl.state.just_visited_merchant = true
	ctrl._set_phase(ctrl.Phase.PREP)
	var before: Dictionary = _snapshot(ctrl)
	var started: bool = ctrl.start_battle()
	_assert(not started, "the merchant visit refuses the battle")
	var after: Dictionary = _snapshot(ctrl)
	_assert(_equal(before, after), "the refusal changed nothing")


## B. A MAP without a selection refuses the battle.
func _test_B_a_map_without_a_selection_refuses_the_battle() -> void:
	var ctrl: Node = await _make_controller(670102)
	ctrl._enter_map()
	await process_frame
	_assert(int(ctrl.phase) == 4, "the phase is MAP")
	var before: Dictionary = _snapshot(ctrl)
	var started: bool = ctrl.start_battle()
	_assert(not started, "a MAP without a selection refuses the battle")
	_assert(_equal(before, _snapshot(ctrl)), "the refusal changed nothing")


## C. A MAP after a SERVICE refuses the battle.
func _test_C_a_map_after_a_service_refuses_the_battle() -> void:
	var ctrl: Node = await _make_controller(670103)
	ctrl._enter_map()
	await process_frame
	# The service effect: the phase returns to MAP and the current
	# encounter is the service node.
	var node_id: int = _first_service_node(ctrl)
	if node_id < 0:
		return
	ctrl._on_node_selected(node_id)
	await process_frame
	_assert(int(ctrl.phase) == 4, "the phase is MAP after the service")
	var before: Dictionary = _snapshot(ctrl)
	var started: bool = ctrl.start_battle()
	_assert(not started, "a MAP after a service refuses the battle")
	_assert(_equal(before, _snapshot(ctrl)), "the refusal changed nothing")


## D. GAMEOVER and REWARD refuse the battle.
func _test_D_the_terminal_phases_refuse_the_battle() -> void:
	var ctrl: Node = await _make_controller(670104)
	ctrl._set_phase(ctrl.Phase.GAMEOVER)
	_assert(not ctrl.start_battle(), "GAMEOVER refuses the battle")
	ctrl._set_phase(ctrl.Phase.REWARD)
	_assert(not ctrl.start_battle(), "REWARD refuses the battle")


## E. The initial run PREP starts the battle.
func _test_E_the_initial_run_prep_starts_the_battle() -> void:
	var ctrl: Node = await _make_controller(670105)
	_assert(int(ctrl.phase) == 0, "the phase is PREP")
	_assert(ctrl.state.current_encounter_id == -1,
		"no encounter is selected yet")
	var started: bool = ctrl.start_battle()
	_assert(started, "the initial run PREP starts the battle")


## F. A selected COMBAT starts the battle.
func _test_F_a_selected_combat_starts_the_battle() -> void:
	var ctrl: Node = await _make_controller(670106)
	ctrl._enter_map()
	await process_frame
	var node_id: int = _first_combat_node(ctrl)
	if node_id < 0:
		return
	ctrl._on_node_selected(node_id)
	await process_frame
	_assert(int(ctrl.phase) == 0, "the phase is PREP after the selection")
	_assert(ctrl.state.current_encounter_id == node_id,
		"the selected combat is the current encounter")
	var started: bool = ctrl.start_battle()
	_assert(started, "the selected COMBAT starts the battle")


## G. A selected ELITE or BOSS starts the battle.
func _test_G_a_selected_elite_or_boss_starts_the_battle() -> void:
	var ctrl: Node = await _make_controller(670107)
	ctrl._enter_map()
	await process_frame
	var node_id: int = _first_elite_or_boss_node(ctrl)
	if node_id < 0:
		return
	# The selection goes through the production path, so the phase
	# and the state are the real ones.
	ctrl._on_node_selected(node_id)
	await process_frame
	_assert(int(ctrl.phase) == 0, "the phase is PREP after the selection")
	var started: bool = ctrl.start_battle()
	_assert(started, "the selected ELITE/BOSS starts the battle")


## H. A Continue after a selection starts the battle.
func _test_H_a_continue_after_a_selection_starts_the_battle() -> void:
	var ctrl: Node = await _make_controller(670108)
	ctrl._enter_map()
	await process_frame
	var node_id: int = _first_combat_node(ctrl)
	if node_id < 0:
		return
	ctrl._on_node_selected(node_id)
	await process_frame
	ctrl.save_now_report()
	# A FRESH controller continues the run.
	var other: Node = await _make_controller(670108)
	other.profile = ctrl.profile
	var resumed: bool = other.resume_run(670108)
	_assert(resumed, "the run resumes")
	_assert(int(other.phase) == 0, "the resumed phase is PREP")
	_assert(other.state.current_encounter_id == node_id,
		"the resumed run keeps the selected combat")
	var started: bool = other.start_battle()
	_assert(started, "the Continue after a selection starts the battle")


## I. The refusal changes NOTHING: the state, the runtime, the RNG and
## the persistence.
func _test_I_the_refusal_changes_nothing() -> void:
	var ctrl: Node = await _make_controller(670109)
	ctrl._enter_map()
	await process_frame
	var before: Dictionary = _snapshot(ctrl)
	var started: bool = ctrl.start_battle()
	_assert(not started, "the MAP battle is refused")
	var after: Dictionary = _snapshot(ctrl)
	_assert(_equal(before, after), "the refusal changed nothing")
	_assert(after["save_count"] == before["save_count"],
		"the save count is unchanged")
	_assert(after["rng_state"] == before["rng_state"],
		"the RNG stream is unchanged")


# ----------------------------------------------------------------


func _make_controller(seed_value: int) -> Node:
	var ctrl: Node = RunControllerScript.new()
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR)
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]
	ctrl.start_run(seed_value)
	await process_frame
	return ctrl


## The state the refusal must not touch.
func _snapshot(ctrl: Node) -> Dictionary:
	var state: Object = ctrl.state
	return {
		"phase": int(ctrl.phase),
		"current_encounter_id": int(state.current_encounter_id),
		"round_index": int(state.round_index),
		"wins": int(state.wins),
		"losses": int(state.losses),
		"lives": int(state.lives),
		"gold": int(state.gold),
		"just_visited_merchant": bool(state.just_visited_merchant),
		"items": int(state.items.size()),
		"units": int(state.units.size()),
		"visited": str(state.encounter_visited_ids),
		"ctx": ctrl.ctx == null,
		"runner": ctrl.runner == null,
		"participants": ctrl._battle_participants == null,
		"save_count": int(ctrl.save_repository.get_save_count()),
		"rng_state": str(RngScript.snapshot()),
		"meta_total_runs": int(ctrl.profile.total_runs),
		"meta_total_wins": int(ctrl.profile.total_wins),
	}


func _equal(a: Dictionary, b: Dictionary) -> bool:
	for key in a.keys():
		if str(a[key]) != str(b.get(key)):
			print("  the difference at %s: %s vs %s"
				% [key, str(a[key]), str(b.get(key))])
			return false
	return true


## The first COMBAT node of the available ones.
func _first_combat_node(ctrl: Node) -> int:
	return _first_node_of_kind(ctrl, [&"combat"])


## The first ELITE or BOSS node of the available ones.
func _first_elite_or_boss_node(ctrl: Node) -> int:
	return _first_node_of_kind(ctrl, [&"elite", &"boss"])


## The first SERVICE node of the available ones.
func _first_service_node(ctrl: Node) -> int:
	return _first_node_of_kind(ctrl, [&"heal", &"treasure", &"merchant",
		&"rest", &"shrine"])


func _first_node_of_kind(ctrl: Node, kinds: Array) -> int:
	var map: Object = ctrl.get_encounter_map()
	if map == null:
		return -1
	for node_id in map.get_available_next_ids():
		var node: Object = map.get_node(int(node_id))
		if node == null:
			continue
		var kind_name: String = _kind_name(int(node.type))
		if kinds.has(kind_name):
			return int(node_id)
	return -1


func _kind_name(kind: int) -> String:
	match kind:
		EncounterTypeScript.Kind.COMBAT:
			return "combat"
		EncounterTypeScript.Kind.ELITE:
			return "elite"
		EncounterTypeScript.Kind.BOSS:
			return "boss"
		EncounterTypeScript.Kind.HEAL:
			return "heal"
		EncounterTypeScript.Kind.TREASURE:
			return "treasure"
		EncounterTypeScript.Kind.MERCHANT:
			return "merchant"
		EncounterTypeScript.Kind.REST:
			return "rest"
		EncounterTypeScript.Kind.SHRINE:
			return "shrine"
		_:
			return "unknown"


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage ENTRY: %s" % label)
