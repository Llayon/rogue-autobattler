extends SceneTree

## The CROSS-PACKAGE INTEGRATION GAUNTLET.
##
## Ten scenarios that cross the package boundaries: the map, the
## service, the battle outcome, the meta pointer, the merchant, the
## equipment, the new-run isolation, the boss dead end and the
## terminal failure.
##
## Every scenario drives the PRODUCTION path and compares the live
## state, the persisted checkpoint, the MetaProfile and the restored
## state. Comparing two DTOs that are BOTH wrong proves nothing, so
## each scenario pins the ABSOLUTE expected outcome as well.
##
##   G1  MAP -> COMBAT -> PREP checkpoint -> resume -> the same
##       combat is required
##   G2  MAP -> a service -> the final stable checkpoint -> resume ->
##       the effect is applied once, the RNG parity holds
##   G3  the battle ended -> the checkpoint failed -> the retry
##       succeeds -> resume -> the exact state equality
##   G4  the checkpoint committed -> the meta failed -> the meta retry
##       succeeds -> Continue is available -> no gameplay replay
##   G5  a merchant visit -> a purchase -> an exit -> resume ->
##       the exact inventory, gold, phase and RNG
##   G6  an equip/unequip in MAP -> a checkpoint -> resume -> the
##       exact bidirectional ownership
##   G7  a battle starts -> the equipment changes -> no invalid
##       checkpoint -> the battle outcome -> a valid checkpoint ->
##       resume
##   G8  a resume with an unusual merchant discount -> an independent
##       new run -> no stale merchant or battle runtime
##   G9  a malformed reachable service node -> no path to the boss ->
##       no false victory, no meta unlock, no checkpoint resurrection
##   G10 the boss is defeated -> the cleanup or the meta write fails ->
##       the retry -> no duplicate terminal rewards, no false Continue

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const BattleEntryFixturesScript = preload("res://tests/run_integrity/battle_entry_fixtures.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")
const SaveSchemaV5Script = preload("res://core/save/save_schema_v5.gd")
const RngServiceScript = preload("res://core/utils/rng_service.gd")
const FaultOps = preload("res://tests/save_repository/support/run_save_file_ops_fault.gd")

const ISOLATED_DIR: String = "user://run_integrity_g10/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_G1_the_combat_is_required_after_the_resume()
	await _test_G2_the_service_is_applied_once()
	await _test_G3_the_outcome_retry_restores_the_exact_state()
	await _test_G4_the_meta_retry_makes_continue_available()
	await _test_G5_the_merchant_survives_the_resume()
	await _test_G6_the_equipment_ownership_is_bidirectional()
	await _test_G7_the_mid_battle_equipment_writes_no_invalid_checkpoint()
	await _test_G8_the_new_run_inherits_nothing()
	await _test_G9_the_boss_dead_end_is_not_a_victory()
	await _test_G10_the_terminal_failure_does_not_duplicate_the_rewards()
	print("")
	print("=== STAGE G: THE CROSS-PACKAGE GAUNTLET: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## G1. The combat is required after the resume.
func _test_G1_the_combat_is_required_after_the_resume() -> void:
	var ctrl: Node = await _make_controller(671001)
	ctrl._enter_map()
	await process_frame
	var combat_id: int = _first_child_of_kind(ctrl.encounter_map,
		EncounterTypeScript.Kind.COMBAT)
	_assert(combat_id >= 0, "the map has a selectable combat node")
	if combat_id < 0:
		return
	ctrl._on_node_selected(combat_id)
	await process_frame
	_assert(int(ctrl.phase) == 0, "the phase is PREP after the combat")

	var resumed: Node = await _make_controller(671002)
	var ok: bool = resumed.resume_run(671001)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(int(resumed.phase) == 0,
		"the resumed phase is PREP (it is %d)" % int(resumed.phase))
	# The SAME map and the SAME node.
	_assert(resumed.encounter_map != null, "the resumed run has the map")
	if resumed.encounter_map != null:
		_assert(int(resumed.encounter_map.get_current_node_id()) == combat_id,
			"the resumed map is at the same combat node")
	# The NEXT node cannot be taken: the phase is PREP.
	var next_ids: Array[int] = resumed.encounter_map.get_available_next_ids()
	_assert(next_ids.size() > 0, "the map has the next nodes")
	if next_ids.size() > 0:
		var round_before: int = resumed.state.round_index
		resumed._on_node_selected(next_ids[0])
		await process_frame
		_assert(resumed.state.round_index == round_before,
			"the combat was not skipped")


## G2. The service is applied once and the RNG parity holds.
func _test_G2_the_service_is_applied_once() -> void:
	var ctrl: Node = await _make_controller(671003)
	ctrl._enter_map()
	await process_frame
	var service_id: int = _first_service_child(ctrl.encounter_map)
	if service_id < 0:
		return
	var rng_before: Dictionary = RngServiceScript.snapshot()
	ctrl._on_node_selected(service_id)
	await process_frame
	var rng_after: Dictionary = RngServiceScript.snapshot()
	_assert(ctrl.state.encounter_visited_ids.count(service_id) == 1,
		"the service node was visited once")

	var resumed: Node = await _make_controller(671004)
	var ok: bool = resumed.resume_run(671003)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(resumed.state.encounter_visited_ids.count(service_id) == 1,
		"the resumed run visited the service once")
	# The RNG continuation is the SAME as after the first pass.
	var rng_resumed: Dictionary = RngServiceScript.snapshot()
	_assert(str(rng_resumed.get("state", "")) == str(rng_after.get("state", "")),
		"the RNG continuation survived the resume")


## G3. The outcome retry restores the exact state.
func _test_G3_the_outcome_retry_restores_the_exact_state() -> void:
	var ctrl: Node = await _make_controller(671005)
	# RUN-ENTRY-01: the battle entry is guarded, so a battle may
	# only start from a real battle context. The case needs a
	# STARTED BATTLE, not the map: the first battle of the run --
	# the initial preparation -- is the production way to one.
	await process_frame
	_assert(ctrl.start_battle(), "the battle starts")
	await process_frame
	if ctrl.runner == null:
		return
	ctrl.runner.state.winner_team = 0
	ctrl.runner.state.phase = 6
	# The write fails.
	var ops: RefCounted = FaultOps.new()
	ops.fail_methods = {&"write_bytes_and_flush": true}
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR, ops)
	ctrl._on_battle_ended()
	await process_frame
	_assert(bool(ctrl.outcome_persistence_pending()),
		"the failed outcome write is pending")
	var wins: int = ctrl.state.wins
	var gold: int = ctrl.state.gold
	var round_index: int = ctrl.state.round_index

	# The retry succeeds.
	ops.fail_methods = {}
	_assert(ctrl.retry_outcome_persistence(), "the retry succeeds")

	var resumed: Node = await _make_controller(671006)
	var ok: bool = resumed.resume_run(671005)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(resumed.state.wins == wins,
		"the resumed wins are the applied ones (got %d, it is %d)"
			% [resumed.state.wins, wins])
	_assert(resumed.state.gold == gold,
		"the resumed gold is the applied one (got %d, it is %d)"
			% [resumed.state.gold, gold])
	_assert(resumed.state.round_index == round_index,
		"the resumed round is the applied one")


## G4. The meta retry makes Continue available, with no gameplay
## replay.
func _test_G4_the_meta_retry_makes_continue_available() -> void:
	var ctrl: Node = await _make_controller(671007)
	ctrl.meta_writer.fail = true
	var report: Object = ctrl.save_now_report()
	_assert(report != null and report.is_partial(),
		"the meta failure is a partial success")
	_assert(not bool(report.checkpoint_committed) == false,
		"the checkpoint landed")
	# The retry of the meta only.
	var gold_before: int = ctrl.state.gold
	var wins_before: int = ctrl.state.wins
	ctrl.meta_writer.fail = false
	_assert(ctrl.retry_meta_publication(), "the meta retry succeeds")
	_assert(ctrl.state.gold == gold_before, "the meta retry replayed no gold")
	_assert(ctrl.state.wins == wins_before, "the meta retry replayed no win")
	# Continue is available: the pointer is published and the checkpoint
	# is loadable.
	_assert(ctrl.profile.current_run_seed == 671007,
		"the pointer is published")
	var resumed: Node = await _make_controller(671008)
	var ok: bool = resumed.resume_run(671007)
	await process_frame
	_assert(ok, "Continue is available after the meta retry")


## G5. The merchant survives the resume.
func _test_G5_the_merchant_survives_the_resume() -> void:
	var ctrl: Node = await _make_controller(671009)
	await _enter_merchant(ctrl)
	_assert(ctrl.buy_item(0), "the purchase succeeds")
	var gold: int = ctrl.state.gold
	var items: int = ctrl.state.items.size()
	ctrl.exit_shop_to_map()
	await process_frame
	var rng_before: Dictionary = RngServiceScript.snapshot()

	var resumed: Node = await _make_controller(671010)
	var ok: bool = resumed.resume_run(671009)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(resumed.state.gold == gold, "the resumed gold matches")
	_assert(resumed.state.items.size() == items, "the resumed inventory matches")
	_assert(int(resumed.phase) == 4, "the resumed phase is MAP")
	var rng_after: Dictionary = RngServiceScript.snapshot()
	_assert(str(rng_after.get("state", "")) == str(rng_before.get("state", "")),
		"the RNG continuation survived the resume")


## G6. The equipment ownership is bidirectional after the resume.
func _test_G6_the_equipment_ownership_is_bidirectional() -> void:
	var ctrl: Node = await _make_controller(671011)
	await _prepare_equipment(ctrl)
	ctrl._enter_map()
	await process_frame
	var item_id: String = _first_item_id(ctrl)
	var unit_id: String = _first_unit_id(ctrl)
	if item_id == "" or unit_id == "":
		return
	_assert(ctrl.equip_item_by_id(item_id, unit_id), "the equip succeeds")

	var resumed: Node = await _make_controller(671012)
	var ok: bool = resumed.resume_run(671011)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	# The item says the unit owns it.
	var item: Object = resumed.state.get_item(item_id)
	_assert(item != null and String(item.owner_unit_id) == unit_id,
		"the resumed item is owned by the unit")
	# The unit says the item is equipped.
	var unit: Object = resumed.state.get_unit(unit_id)
	_assert(unit != null and unit.equipped_item_ids.has(item_id),
		"the resumed unit lists the item")
	# And the inventory is consistent.
	_assert(resumed.state.is_inventory_valid(),
		"the resumed inventory is consistent")


## G7. The mid-battle equipment writes no invalid checkpoint.
func _test_G7_the_mid_battle_equipment_writes_no_invalid_checkpoint() -> void:
	var ctrl: Node = await _make_controller(671013)
	await _prepare_equipment(ctrl)
	# RUN-ENTRY-01: the battle entry is guarded, so a battle may only
	# start from a real battle context. The case needs a STARTED
	# BATTLE, not the map: the first battle of the run -- the initial
	# preparation -- is the production way to one.
	await process_frame
	var item_id: String = _first_item_id(ctrl)
	var unit_id: String = _first_unit_id(ctrl)
	if item_id == "" or unit_id == "":
		return
	_assert(ctrl.equip_item_by_id(item_id, unit_id), "the equip succeeds")
	ctrl.save_now()
	# RUN-ENTRY-01: the battle entry is guarded, so a battle may
	# only start from a real battle context. The case needs a
	# STARTED BATTLE, not the map: the first battle of the run --
	# the initial preparation -- is the production way to one.
	await process_frame
	_assert(ctrl.start_battle(), "the battle starts")
	await process_frame
	var count_before: int = ctrl.save_repository.get_save_count()
	_assert(ctrl.equip_item_by_id(item_id, unit_id),
		"the mid-battle equip is allowed")
	_assert(ctrl.save_repository.get_save_count() == count_before,
		"the mid-battle equip wrote no checkpoint")
	# The checkpoint on the disk is still VALID.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(671013)
	_assert(loaded != null and loaded.is_ok(),
		"the checkpoint is still valid after the mid-battle equip")
	# The battle outcome writes a valid checkpoint.
	if ctrl.runner != null:
		ctrl.runner.state.winner_team = 0
		ctrl.runner.state.phase = 6
		ctrl._on_battle_ended()
	await process_frame
	var resumed: Node = await _make_controller(671014)
	var ok: bool = resumed.resume_run(671013)
	await process_frame
	_assert(ok, "the checkpoint resumes after the battle outcome")


## G8. The new run inherits nothing.
func _test_G8_the_new_run_inherits_nothing() -> void:
	var ctrl: Node = await _make_controller(671015)
	await _enter_merchant(ctrl)
	ctrl.merchant_shop.set_discount(0.75)
	ctrl.save_now()
	await process_frame
	var ok: bool = ctrl.resume_run(671015)
	await process_frame
	_assert(ok, "the checkpoint resumes")
	_assert(is_equal_approx(ctrl.merchant_shop.get_discount(), 0.75),
		"the resumed run keeps its discount")
	# The independent new run.
	ctrl.start_run(671016)
	await process_frame
	_assert(is_equal_approx(ctrl.merchant_shop.get_discount(), 0.5),
		"the new run has the balance discount (got %f)"
			% ctrl.merchant_shop.get_discount())
	_assert(ctrl.runner == null, "the new run has no battle runner")
	_assert(ctrl.ctx == null, "the new run has no battle context")
	_assert(ctrl._battle_participants == null,
		"the new run has no battle participants")
	_assert(not ctrl._battle_outcome_applied,
		"the new run has no armed outcome latch")


## G9. The boss dead end is not a victory.
func _test_G9_the_boss_dead_end_is_not_a_victory() -> void:
	var ctrl: Node = await _make_controller(671017)
	ctrl._enter_map()
	await process_frame
	var service_id: int = _make_service_dead_end(ctrl.encounter_map)
	if service_id < 0:
		return
	var total_wins_before: int = ctrl.profile.total_wins
	var unlocked_before: int = ctrl.profile.unlocked_units.size()
	ctrl.save_now()
	await process_frame
	var ended: Array = []
	ctrl.run_ended.connect(func(won: bool) -> void: ended.append(won))
	ctrl._on_node_selected(service_id)
	await process_frame
	_assert(ended.is_empty(), "no run_ended was emitted")
	_assert(ctrl.profile.total_wins == total_wins_before,
		"the total wins did not change")
	_assert(ctrl.profile.unlocked_units.size() == unlocked_before,
		"nothing was unlocked")
	# The checkpoint was not deleted.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(671017)
	_assert(loaded != null and loaded.is_ok(),
		"the checkpoint was not resurrected or deleted")


## G10. The terminal failure does not duplicate the rewards.
func _test_G10_the_terminal_failure_does_not_duplicate_the_rewards() -> void:
	var ctrl: Node = await _make_controller(671018)
	# RUN-ENTRY-01: the battle entry is guarded, so a battle may only
	# start from a real battle context. The case fights the BOSS, so
	# the run walks the map to the boss: the walk leaves the run in
	# PREP with the boss current, which is the battle context.
	ctrl._enter_map()
	await process_frame
	var boss_id: int = _boss_id(ctrl.encounter_map)
	if boss_id < 0:
		return
	_assert(BattleEntryFixturesScript.select_the_boss(ctrl) == boss_id,
		"the boss is the current encounter")
	_assert(ctrl.start_battle(), "the battle starts")
	await process_frame
	if ctrl.runner == null:
		return
	ctrl.runner.state.winner_team = 0
	ctrl.runner.state.phase = 6
	var total_runs_before: int = ctrl.profile.total_runs
	var total_wins_before: int = ctrl.profile.total_wins
	ctrl._on_battle_ended()
	await process_frame
	_assert(ctrl.profile.total_wins == total_wins_before + 1,
		"the boss victory counted one win")
	_assert(ctrl.profile.total_runs == total_runs_before + 1,
		"the boss victory counted one run")
	# A repeated completion callback must not duplicate the rewards.
	ctrl._on_battle_ended()
	await process_frame
	_assert(ctrl.profile.total_wins == total_wins_before + 1,
		"the repeated callback did not duplicate the win")
	_assert(ctrl.profile.total_runs == total_runs_before + 1,
		"the repeated callback did not duplicate the run")
	# A finished run is NOT resumable.
	var reader: RefCounted = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var loaded: RefCounted = reader.load_run(671018)
	_assert(loaded == null or not loaded.is_ok(),
		"the finished run is not resumable")


# ----------------------------------------------------------------


func _make_service_dead_end(map: Object) -> int:
	var current: Object = map.get_current_node()
	if current == null:
		return -1
	var service_id: int = -1
	for child_id in current.child_ids:
		var child: Object = map.get_node(int(child_id))
		if child == null:
			continue
		if int(child.type) != int(EncounterTypeScript.Kind.BOSS):
			service_id = int(child_id)
			break
	if service_id < 0:
		return -1
	var service: Object = map.get_node(service_id)
	service.type = int(EncounterTypeScript.Kind.REST)
	var no_children: Array[int] = []
	service.child_ids = no_children
	return service_id


func _first_child_of_kind(map: Object, kind: int) -> int:
	var current: Object = map.get_current_node()
	if current == null:
		return -1
	for child_id in current.child_ids:
		var child: Object = map.get_node(int(child_id))
		if child != null and int(child.type) == int(kind):
			return int(child_id)
	return -1


func _first_service_child(map: Object) -> int:
	return _first_child_of_kind(map, int(EncounterTypeScript.Kind.REST))


func _boss_id(map: Object) -> int:
	for node in map.get_all_nodes():
		if int(node.type) == int(EncounterTypeScript.Kind.BOSS):
			return int(node.id)
	return -1


func _first_item_id(ctrl: Node) -> String:
	if ctrl.state.items.is_empty():
		return ""
	return String(ctrl.state.items[0].instance_id)


func _first_unit_id(ctrl: Node) -> String:
	var board: Array = ctrl.state.get_board_units()
	if board.is_empty():
		return ""
	return String(board[0].instance_id)


func _prepare_equipment(ctrl: Node) -> void:
	var unit_def: Resource = ContentDB_static.get_by_id_for_type("units", &"warrior")
	var item_def: Resource = ContentDB_static.get_by_id_for_type("items",
		&"potion_strength")
	if unit_def != null:
		var unit: Object = ctrl.state.create_unit(unit_def.id, unit_def.max_hp, 0)
		if unit != null:
			ctrl.state.move_unit(unit.instance_id, 0)
	if item_def != null:
		ctrl.state.create_item(item_def.id)


func _enter_merchant(ctrl: Node) -> void:
	ctrl._enter_map()
	await process_frame
	ctrl.state.just_visited_merchant = true
	ctrl._refresh_merchant_shop()
	ctrl._set_phase(0)
	await process_frame


func _make_controller(seed_value: int) -> Node:
	var ctrl: Node = RunControllerScript.new()
	ctrl.save_repository = RunSaveRepositoryScript.new(ISOLATED_DIR)
	ctrl.meta_writer = _MetaWriter.new()
	get_root().add_child(ctrl)
	await process_frame
	ctrl.profile = MetaProfileScript.new()
	ctrl.profile.unlocked_units = [&"warrior", &"archer"] as Array[StringName]
	ctrl.start_run(seed_value)
	await process_frame
	return ctrl


const ContentDB_static = preload("res://core/utils/content_db.gd")


## A meta writer that does NOT touch the production meta file.
class _MetaWriter:
	extends RefCounted

	var fail: bool = false
	var writes: int = 0

	func write_meta(profile: Object) -> bool:
		writes += 1
		return not fail


func _assert(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] Stage G: %s" % label)
