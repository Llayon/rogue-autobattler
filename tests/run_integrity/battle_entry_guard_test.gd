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
	await _test_D2_a_service_encounter_refuses_the_battle()
	await _test_E_the_initial_run_prep_starts_the_battle()
	await _test_F_a_selected_combat_starts_the_battle()
	await _test_G_a_selected_elite_or_boss_starts_the_battle()
	await _test_H_a_continue_after_a_selection_starts_the_battle()
	await _test_I_a_post_defeat_retry_starts_the_battle()
	await _test_I2_a_post_defeat_retry_of_a_combat_node_starts_the_battle()
	await _test_J_a_refusal_keeps_the_reaction_registry()
	await _test_K_a_refusal_keeps_the_checkpoint_file()
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


## D2. A SERVICE encounter is not a battle context.
##
## A service encounter leaves the run in PREP with that node current:
## the merchant visit is the obvious case, and the merchant flag is
## cleared when the shop is left. The node itself is NOT a combat node,
## so the battle must be refused even when the merchant flag is gone.
func _test_D2_a_service_encounter_refuses_the_battle() -> void:
	var ctrl: Node = await _make_controller(670110)
	ctrl._enter_map()
	await process_frame
	var node_id: int = _first_service_node(ctrl)
	_assert(node_id >= 0, "the map offers a service node")
	if node_id < 0:
		return
	# The service node is selected through the production path, so the
	# phase and the state are the real ones.
	ctrl._on_node_selected(node_id)
	await process_frame
	_assert(int(ctrl.phase) == 0, "the phase is PREP after the service")
	_assert(ctrl.state.current_encounter_id == node_id,
		"the service node is the current encounter")
	# The merchant flag is cleared: the shop was left. The node is
	# still a service node, and a service node is not a battle.
	ctrl.state.just_visited_merchant = false
	var before: Dictionary = _snapshot(ctrl)
	var started: bool = ctrl.start_battle()
	_assert(not started, "a service encounter refuses the battle")
	_assert(_equal(before, _snapshot(ctrl)), "the refusal changed nothing")


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
	var node_id: int = await _walk_to_a_combat(ctrl)
	# The case must NOT be vacuous: a map without a reachable combat
	# node would make the assertions below unreachable.
	_assert(node_id >= 0, "the map offers a reachable combat node")
	if node_id < 0:
		return
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
	# The case must NOT be vacuous. An ELITE/BOSS may not be offered
	# by this seed, and that is a fact about the map, not a reason to
	# skip the case: the boss is ALWAYS in the map (layer 10), so the
	# search must find it.
	_assert(node_id >= 0, "the map has an elite or boss node")
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
	var node_id: int = await _walk_to_a_combat(ctrl)
	_assert(node_id >= 0, "the map offers a reachable combat node")
	if node_id < 0:
		return
	_assert(int(ctrl.phase) == 0, "the phase is PREP after the selection")
	ctrl.save_now_report()
	await process_frame
	# A FRESH controller continues the run. It must NOT start a run:
	# `start_run()` writes a checkpoint of its own and would overwrite
	# the one the resume is supposed to read.
	var other: Node = await _make_empty_controller()
	other.profile = ctrl.profile
	var resumed: bool = other.resume_run(670108)
	_assert(resumed, "the run resumes")
	_assert(int(other.phase) == 0, "the resumed phase is PREP")
	_assert(other.state.current_encounter_id == node_id,
		"the resumed run keeps the selected combat")
	var started: bool = other.start_battle()
	_assert(started, "the Continue after a selection starts the battle")


## I2. The post-defeat retry starts the battle.
##
## The loss branch of `_on_battle_ended()` grows the round and returns
## the run to the PREP phase, but it does NOT change the current
## encounter: the DEFEATED combat node is still current. That is the
## one legal PREP origin whose encounter id is stale by construction,
## and the player must be able to fight it again while lives remain.
func _test_I_a_post_defeat_retry_starts_the_battle() -> void:
	var ctrl: Node = await _make_controller(670120)
	# The first battle of the run: the initial preparation.
	_assert(ctrl.start_battle(), "the first battle starts")
	await process_frame
	_assert(ctrl.runner != null, "the battle has a runner")
	if ctrl.runner == null:
		# The battle did not start: the assertion above has already
		# failed, and a runner access would raise a SCRIPT ERROR,
		# which is not a catch.
		return
	# The player LOSES, and a life remains.
	ctrl.state.lives = 3
	ctrl.runner.state.winner_team = 1
	ctrl.runner.state.phase = 6
	ctrl._on_battle_ended()
	await process_frame
	_assert(int(ctrl.phase) == 0,
		"the run is back in PREP after the defeat (the phase is %d)"
			% int(ctrl.phase))
	_assert(int(ctrl.state.losses) == 1, "the defeat was counted")
	_assert(int(ctrl.state.lives) == 2, "a life remains")
	# The retry is a LEGAL battle: the run is in PREP, the merchant
	# flag is clear and the current encounter is the initial battle.
	var before: Dictionary = _snapshot(ctrl)
	var started: bool = ctrl.start_battle()
	_assert(started, "the post-defeat retry starts the battle")
	await process_frame
	_assert(int(ctrl.phase) == 1,
		"the phase is BATTLE after the retry (the phase is %d)"
			% int(ctrl.phase))
	_assert(ctrl.runner != null, "the retry has a runner")
	# The retry did not repeat the outcome.
	_assert(int(ctrl.state.wins) == int(before["wins"]),
		"the retry did not count a win")
	_assert(int(ctrl.state.losses) == int(before["losses"]),
		"the retry did not count a defeat")


## I3. The post-defeat retry of a DEFEATED COMBAT node is legal.
##
## The same flow, but with a real combat encounter: the defeated node
## is still current, and it is a combat node, so the retry is legal.
func _test_I2_a_post_defeat_retry_of_a_combat_node_starts_the_battle() -> void:
	var ctrl: Node = await _make_controller(670121)
	ctrl._enter_map()
	await process_frame
	var node_id: int = _first_combat_node(ctrl)
	_assert(node_id >= 0, "the map offers a combat node")
	if node_id < 0:
		return
	ctrl._on_node_selected(node_id)
	await process_frame
	_assert(ctrl.start_battle(), "the combat battle starts")
	await process_frame
	_assert(ctrl.runner != null, "the battle has a runner")
	if ctrl.runner == null:
		# The battle did not start: the assertion above has already
		# failed, and a runner access would raise a SCRIPT ERROR,
		# which is not a catch.
		return
	# The player LOSES the combat, and a life remains.
	ctrl.state.lives = 3
	ctrl.runner.state.winner_team = 1
	ctrl.runner.state.phase = 6
	ctrl._on_battle_ended()
	await process_frame
	_assert(int(ctrl.phase) == 0,
		"the run is back in PREP after the defeat (the phase is %d)"
			% int(ctrl.phase))
	_assert(int(ctrl.state.current_encounter_id) == node_id,
		"the defeated node is still the current encounter")
	# The retry of the defeated node is LEGAL.
	var started: bool = ctrl.start_battle()
	_assert(started, "the retry of the defeated node starts the battle")
	await process_frame
	_assert(int(ctrl.phase) == 1,
		"the phase is BATTLE after the retry (the phase is %d)"
			% int(ctrl.phase))


## J. A refusal does not clear the reaction registry.
##
## `start_battle()` clears the legacy reaction registry when it starts.
## A REFUSED call must not touch it: the registry is the shared legacy
## runtime, and a refusal that cleared it would destroy the
## registrations of an unrelated battle.
func _test_J_a_refusal_keeps_the_reaction_registry() -> void:
	# The PALADIN owns the legacy reaction, so a battle with one on
	# the board registers it through the production path. The
	# registry must hold a REAL registration: an empty registry would
	# make this case vacuous, because clearing an empty registry
	# changes nothing.
	var ctrl: Node = await _make_controller(670130)
	ctrl.state.create_unit(&"paladin", 100, 0)
	_reset_reaction_registry()
	_assert(ctrl.start_battle(), "the battle with a paladin starts")
	await process_frame
	var registry_before: String = _reaction_registry_state()
	_assert(registry_before.find("paladin") >= 0,
		"the paladin registered a legacy reaction (the registry is %s)"
			% registry_before)
	if registry_before.find("paladin") < 0:
		return
	# The run goes back to the MAP, and the battle is refused.
	ctrl._set_phase(ctrl.Phase.MAP)
	var refused: bool = ctrl.start_battle()
	_assert(not refused, "the MAP battle is refused")
	_assert(_reaction_registry_state() == registry_before,
		"the refusal did not clear the reaction registry")
	_assert(_reaction_registry_state().find("paladin") >= 0,
		"the paladin is still registered after the refusal")


## K. A refusal does not change the checkpoint on the disk.
##
## The save count proves that no checkpoint was COMMITTED. The bytes
## on the disk prove that the existing checkpoint was not rewritten
## either.
func _test_K_a_refusal_keeps_the_checkpoint_file() -> void:
	var ctrl: Node = await _make_controller(670131)
	ctrl._enter_map()
	await process_frame
	# The run has a checkpoint of its own.
	ctrl.save_now()
	await process_frame
	var before: String = _checkpoint_bytes(ctrl)
	_assert(before != "", "the checkpoint is on the disk")
	if before == "":
		return
	var count_before: int = ctrl.save_repository.get_save_count()
	var refused: bool = ctrl.start_battle()
	_assert(not refused, "the MAP battle is refused")
	_assert(int(ctrl.save_repository.get_save_count()) == count_before,
		"the refusal wrote no checkpoint")
	_assert(_checkpoint_bytes(ctrl) == before,
		"the refusal did not rewrite the checkpoint file")


## The state of the legacy reaction registry, or "" when the autoload
## is not reachable in this headless tree.
func _reaction_registry_state() -> String:
	var tree: Object = Engine.get_main_loop()
	if tree == null or not ("root" in tree):
		return ""
	var node: Object = tree.root.get_node_or_null("ReactionSystem")
	if node == null:
		return ""
	var inner: Object = node.get("_inner")
	if inner == null:
		return ""
	return str(inner.get("_reactions"))


## Makes the reaction registry reachable and EMPTY.
##
## The autoload's own _ready() resolves /root/EventBus with an
## absolute path, which fails outside the active scene tree, so the
## inner system is created here directly -- the same wiring the
## legacy compatibility suite uses.
func _reset_reaction_registry() -> void:
	var tree: Object = Engine.get_main_loop()
	if tree == null or not ("root" in tree):
		return
	var node: Object = tree.root.get_node_or_null("ReactionSystem")
	if node == null:
		return
	if node.get("_inner") == null:
		var inner_script: Resource = load(
			"res://core/reactions/reaction_system.gd")
		node.set("_inner", inner_script.new())
	var inner: Object = node.get("_inner")
	if inner != null:
		inner.get("_reactions").clear()


## The bytes of the run file of the controller, or "" when there is no
## file.
func _checkpoint_bytes(ctrl: Node) -> String:
	var reader: Object = ctrl.save_repository.load_run(int(ctrl.state.seed))
	if reader == null or not bool(reader.is_ok()):
		return ""
	return str(reader.data)


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
	var ctrl: Node = await _make_empty_controller()
	ctrl.start_run(seed_value)
	await process_frame
	return ctrl


## A controller with an EMPTY runtime: it has not started a run, so it
## does not write a checkpoint of its own.
func _make_empty_controller() -> Node:
	var ctrl: Node = RunControllerScript.new()
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR)
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]
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


## The first COMBAT node the player may select.
##
## The map's `start_run()` puts the player on a layer-1 node and marks
## it visited, so the selectable nodes are the CHILDREN of the current
## node -- `get_available_next_ids()`. The kind of a child is drawn,
## so a seed can offer a SERVICE node there.
func _first_combat_node(ctrl: Node) -> int:
	return _first_selectable_of_kind(ctrl, [&"combat"])


## Walks the run to a REACHABLE combat node, the way the player does.
##
## Every step goes through `_on_node_selected`, so the phase, the
## state and the checkpoint are the real ones. The returned id is the
## combat node the run now stands on, or -1 when the graph has no
## reachable combat node.
func _walk_to_a_combat(ctrl: Node) -> int:
	var map: Object = ctrl.get_encounter_map()
	if map == null:
		return -1
	# The layer-1 node the run starts on is a COMBAT node, but it is
	# already visited, so the player cannot select it again: the
	# battle of the layer-1 node is the INITIAL preparation.
	var walked: Dictionary = {}
	for _step in range(12):
		var current: int = int(ctrl.state.current_encounter_id)
		if walked.has(current):
			break
		walked[current] = true
		for node_id in map.get_available_next_ids():
			var node: Object = map.get_node(int(node_id))
			if node == null:
				continue
			if not node.is_combat():
				continue
			ctrl._on_node_selected(int(node_id))
			await process_frame
			return int(node_id)
		# No combat child: the current node has no reachable combat
		# below it, so the walk stops. Stepping through a SERVICE node
		# would leave the run in PREP with a service encounter current,
		# which is not a battle context.
		break
	return -1


## The first SERVICE node the player may select.
func _first_service_node(ctrl: Node) -> int:
	return _first_selectable_of_kind(ctrl, [&"heal", &"treasure", &"merchant",
		&"rest", &"shrine"])


## An ELITE or BOSS node of the map.
##
## The boss is ALWAYS in the map (layer 10), so this search is over
## the WHOLE map: an elite may not be offered by this seed, but the
## boss is guaranteed to exist.
func _first_elite_or_boss_node(ctrl: Node) -> int:
	var map: Object = ctrl.get_encounter_map()
	if map == null:
		return -1
	for node in map.get_all_nodes():
		var kind_name: String = _kind_name(int(node.type))
		if kind_name == "elite" or kind_name == "boss":
			return int(node.id)
	return -1


## The first selectable node of the given kinds.
func _first_selectable_of_kind(ctrl: Node, kinds: Array) -> int:
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
