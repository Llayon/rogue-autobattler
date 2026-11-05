extends SceneTree

## RI-05: the battle outcome must be a TRANSACTION, and it must be
## IDEMPOTENT.
##
## The defects this pins:
##
## 1. TRANSACTION ORDER: `_on_battle_ended` called `save_now()` BEFORE
##    it applied the outcome, so the checkpoint on the disk was the
##    PRE-outcome state. A crash between the save and the apply left
##    the run on disk as if the battle had never happened: the win
##    bonus, the round advance, the combat drop and the reward offer
##    were all lost, and the battle would be replayed.
##
## 2. THE LOSS BRANCH NEVER SAVED: on a loss the state was mutated
##    (losses, lives, round_index) and never written, so the on-disk
##    state stayed pre-battle.
##
## 3. IDEMPOTENCE: `_on_battle_ended` could be applied twice. The
##    scene ticks the battle every frame and calls `_on_battle_ended`
##    whenever the runner reports ENDED; nothing consumed the ENDED
##    state, so the outcome could be applied again: a second win
##    bonus, a second combat drop, a second reward offer, a second
##    round advance.
##
## The contract:
##
##   - the outcome is applied ATOMICALLY: the mutation and the write
##     are one step, and the on-disk state is always the POST-outcome
##     state of a completed battle;
##   - applying the same outcome twice is a NO-OP.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const SaveServiceScript = preload("res://core/save/save_service.gd")
const RngServiceScript = preload("res://core/utils/rng_service.gd")

const ISOLATED_DIR: String = "user://run_integrity_ri05/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_a_win_is_persisted_with_its_outcome()
	await _test_B_a_loss_is_persisted_with_its_outcome()
	await _test_C_the_outcome_is_applied_only_once()
	await _test_D_the_checkpoint_is_written_after_the_outcome()
	print("")
	print("=== STAGE 4: BATTLE OUTCOME TRANSACTION: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A win must be on disk WITH its outcome: the win counter, the gold
## bonus and the advanced round.
func _test_A_a_win_is_persisted_with_its_outcome() -> void:
	var ctrl: Node = await _make_controller(510001)
	await _finish_battle(ctrl, 0)
	var before: Dictionary = _live_state(ctrl)
	_assert(int(before.get("wins", 0)) == 1,
		"the win was applied to the live state")
	var on_disk: Dictionary = _disk_state(ctrl, 510001)
	_assert(int(on_disk.get("wins", 0)) == 1,
		"the win is on the disk (got %d)" % int(on_disk.get("wins", 0)))
	_assert(int(on_disk.get("gold", 0)) == int(before.get("gold", 0)),
		"the gold on the disk is the post-outcome gold")
	_assert(int(on_disk.get("round_index", 0)) == int(before.get("round_index", 0)),
		"the round on the disk is the post-outcome round")


## A loss must be on disk too. The loss branch never saved at all.
func _test_B_a_loss_is_persisted_with_its_outcome() -> void:
	var ctrl: Node = await _make_controller(510002)
	await _finish_battle(ctrl, 1)
	var before: Dictionary = _live_state(ctrl)
	_assert(int(before.get("losses", 0)) == 1,
		"the loss was applied to the live state")
	var on_disk: Dictionary = _disk_state(ctrl, 510002)
	_assert(int(on_disk.get("losses", 0)) == 1,
		"the loss is on the disk (got %d)" % int(on_disk.get("losses", 0)))
	_assert(int(on_disk.get("lives", 0)) == int(before.get("lives", 0)),
		"the lives on the disk are the post-outcome lives")


## The outcome must be applied ONCE. The scene ticks every frame and
## calls `_on_battle_ended` whenever the runner reports ENDED; without
## consuming that state the outcome would be applied again.
func _test_C_the_outcome_is_applied_only_once() -> void:
	var ctrl: Node = await _make_controller(510003)
	await _finish_battle(ctrl, 0)
	var after_first: Dictionary = _live_state(ctrl)
	var gold_first: int = int(after_first.get("gold", 0))
	var round_first: int = int(after_first.get("round_index", 0))

	# The scene would call this again on the next frame.
	ctrl._on_battle_ended()
	await process_frame
	var after_second: Dictionary = _live_state(ctrl)
	_assert(int(after_second.get("wins", 0)) == int(after_first.get("wins", 0)),
		"the second application does not count a second win")
	_assert(int(after_second.get("gold", 0)) == gold_first,
		"the second application does not grant a second win bonus")
	_assert(int(after_second.get("round_index", 0)) == round_first,
		"the second application does not advance the round again")


## The write must happen AFTER the outcome is applied, so the on-disk
## state is never the pre-outcome state of a finished battle.
func _test_D_the_checkpoint_is_written_after_the_outcome() -> void:
	var ctrl: Node = await _make_controller(510004)
	await _finish_battle(ctrl, 0)
	var live: Dictionary = _live_state(ctrl)
	var on_disk: Dictionary = _disk_state(ctrl, 510004)
	_assert(int(on_disk.get("wins", 0)) == int(live.get("wins", 0)),
		"the on-disk wins equal the live wins")
	_assert(int(on_disk.get("round_index", 0)) == int(live.get("round_index", 0)),
		"the on-disk round equals the live round")
	_assert(int(on_disk.get("gold", 0)) == int(live.get("gold", 0)),
		"the on-disk gold equals the live gold")


# ----------------------------------------------------------------


## Builds a controller with the isolated saves and a started battle.
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


## Drives the battle to its end with the given winner.
##
## The winner is produced by the runner's own `_end_battle`, which is
## the production path: it derives the winner from the surviving
## teams. The test removes the losing team and then ends the battle.
func _finish_battle(ctrl: Node, winner: int) -> void:
	var started: bool = ctrl.start_battle()
	await process_frame
	var losing_team: int = 1 if winner == 0 else 0
	for combatant in ctrl.runner.ctx.combatants_of_team(losing_team):
		combatant.health.current_hp = 0
	ctrl.runner._cleanup_dead()
	ctrl.runner._end_battle()
	ctrl.tick_battle(0.016)
	await process_frame


## The live state, read through the public accessors.
func _live_state(ctrl: Node) -> Dictionary:
	return {
		"wins": ctrl.state.wins,
		"losses": ctrl.state.losses,
		"gold": ctrl.state.gold,
		"round_index": ctrl.state.round_index,
		"lives": ctrl.state.lives,
	}


## The state on the disk, read through the same repository the
## controller wrote.
##
## The repository does NOT create its directory -- it expects it to
## exist -- so the test creates it before building the repository.
func _disk_state(ctrl: Node, seed_value: int) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	var repo: Object = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var result: RefCounted = SaveServiceScript._load_run_v5_with_repository(
		seed_value, repo)
	if result == null or not result.is_ok():
		return {}
	var dto: Dictionary = result.data
	return {
		"wins": int(dto.get("wins", 0)),
		"losses": int(dto.get("losses", 0)),
		"gold": int(dto.get("gold", 0)),
		"round_index": int(dto.get("round_index", 0)),
		"lives": int(dto.get("lives", 0)),
	}


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
		print("  [FAIL] Stage 4: %s" % label)
