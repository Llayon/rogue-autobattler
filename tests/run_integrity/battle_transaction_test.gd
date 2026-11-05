extends SceneTree

## RI-05: the battle outcome must be a TRANSACTION.
##
## The finding: `RunController._on_battle_ended` calls `save_now()`
## BEFORE the outcome is applied. The save therefore persists the
## PRE-battle state, and the on-disk checkpoint is one battle behind
## the live state:
##
##   run_controller.gd:622  save_now()          <- the save
##   run_controller.gd:628  state.wins += 1    <- the outcome
##   run_controller.gd:629  state.gold += ...  <- the outcome
##   run_controller.gd:634  state.round_index += 1
##
## The loss branch applies losses / lives / round and NEVER saves at
## all, so a lost battle leaves the pre-battle state on disk forever.
##
## The contract this suite pins:
##
##   1. A WON battle persists the APPLIED outcome: the checkpoint on
##      disk has the new wins, the new gold and the new round index.
##   2. A LOST battle persists the APPLIED outcome too: the checkpoint
##      on disk has the new losses and the new lives.
##   3. The outcome is applied EXACTLY ONCE: calling the end handler
##      again does not apply it a second time.

const RunControllerScript = preload("res://core/progression/run_controller.gd")
const BattleStateScriptForCtrl = preload("res://core/battle/battle_state.gd")
const RunSaveRepositoryScript = preload("res://core/save/run_save_repository.gd")
const SaveServiceScript = preload("res://core/save/save_service.gd")
const MetaProfileScript = preload("res://core/progression/meta_profile.gd")
const BalanceScript = preload("res://core/balance.gd")

const ISOLATED_DIR: String = "user://run_integrity_battle_transaction/"

var _passed: int = 0
var _failed: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ISOLATED_DIR))
	await _test_A_a_won_battle_persists_the_applied_outcome()
	await _test_B_a_lost_battle_persists_the_applied_outcome()
	await _test_C_the_outcome_is_applied_exactly_once()
	print("")
	print("=== STAGE 4A: BATTLE OUTCOME TRANSACTION: %d pass / %d fail ==="
		% [_passed, _failed])
	if _failed > 0:
		quit(1)
		return
	quit(0)


## A won battle must persist the APPLIED outcome.
func _test_A_a_won_battle_persists_the_applied_outcome() -> void:
	var ctrl: Node = await _make_controller(520001)
	ctrl.state.round_index = 3
	ctrl.state.wins = 2
	ctrl.state.gold = 40

	var ok: bool = ctrl.start_battle()
	_assert(ok, "the battle starts")
	ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
	ctrl.runner.state.winner_team = 0
	ctrl.tick_battle(0.1)
	await process_frame

	# The live state has the outcome applied.
	_assert(ctrl.state.wins == 3,
		"the live state has the win applied (got %d)" % ctrl.state.wins)
	_assert(ctrl.state.round_index == 4,
		"the live state has the round advanced (got %d)" % ctrl.state.round_index)

	# The checkpoint on disk must have it too.
	var dto: Dictionary = _load_dto(520001)
	_assert(not dto.is_empty(), "the checkpoint was persisted")
	if dto.is_empty():
		return
	_assert(int(dto.get("wins", -1)) == 3,
		"the persisted checkpoint has the win applied (got %d)"
			% int(dto.get("wins", -1)))
	_assert(int(dto.get("round_index", -1)) == 4,
		"the persisted checkpoint has the round advanced (got %d)"
			% int(dto.get("round_index", -1)))
	_assert(int(dto.get("gold", -1)) > 40,
		"the persisted checkpoint has the gold bonus applied (got %d)"
			% int(dto.get("gold", -1)))
	ctrl.queue_free()
	await process_frame


## A lost battle must persist the APPLIED outcome too. Today the loss
## branch never saves, so the disk keeps the pre-battle state.
func _test_B_a_lost_battle_persists_the_applied_outcome() -> void:
	var ctrl: Node = await _make_controller(520002)
	ctrl.state.round_index = 3
	ctrl.state.losses = 1
	ctrl.state.lives = 3

	var ok: bool = ctrl.start_battle()
	_assert(ok, "the battle starts")
	ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
	ctrl.runner.state.winner_team = 1
	ctrl.tick_battle(0.1)
	await process_frame

	_assert(ctrl.state.losses == 2,
		"the live state has the loss applied (got %d)" % ctrl.state.losses)
	_assert(ctrl.state.lives == 2,
		"the live state has the life spent (got %d)" % ctrl.state.lives)

	var dto: Dictionary = _load_dto(520002)
	_assert(not dto.is_empty(), "the checkpoint was persisted")
	if dto.is_empty():
		return
	_assert(int(dto.get("losses", -1)) == 2,
		"the persisted checkpoint has the loss applied (got %d)"
			% int(dto.get("losses", -1)))
	_assert(int(dto.get("lives", -1)) == 2,
		"the persisted checkpoint has the life spent (got %d)"
			% int(dto.get("lives", -1)))
	ctrl.queue_free()
	await process_frame


## The outcome must be applied EXACTLY ONCE.
##
## The handler is reachable more than once: the battle state stays
## ENDED, and `tick_battle` calls the handler on every tick until the
## phase leaves BATTLE. There is no idempotency guard.
func _test_C_the_outcome_is_applied_exactly_once() -> void:
	var ctrl: Node = await _make_controller(520003)
	ctrl.state.round_index = 3
	ctrl.state.wins = 2
	ctrl.state.gold = 40

	var ok: bool = ctrl.start_battle()
	_assert(ok, "the battle starts")
	ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
	ctrl.runner.state.winner_team = 0
	ctrl.tick_battle(0.1)
	await process_frame

	var wins_after_first: int = ctrl.state.wins
	var round_after_first: int = ctrl.state.round_index
	var gold_after_first: int = ctrl.state.gold

	# The battle state is still ENDED: another tick would call the
	# handler again.
	_assert(ctrl.runner.state.phase == BattleStateScriptForCtrl.Phase.ENDED,
		"the battle state is still ENDED after the outcome")
	ctrl.tick_battle(0.1)
	await process_frame

	_assert(ctrl.state.wins == wins_after_first,
		"a second end does not apply the win again (got %d, expected %d)"
			% [ctrl.state.wins, wins_after_first])
	_assert(ctrl.state.round_index == round_after_first,
		"a second end does not advance the round again (got %d, expected %d)"
			% [ctrl.state.round_index, round_after_first])
	_assert(ctrl.state.gold == gold_after_first,
		"a second end does not grant the gold again (got %d, expected %d)"
			% [ctrl.state.gold, gold_after_first])
	ctrl.queue_free()
	await process_frame


# ----------------------------------------------------------------


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


func _load_dto(seed_value: int) -> Dictionary:
	var repo: Object = RunSaveRepositoryScript.new(ISOLATED_DIR)
	var result: RefCounted = SaveServiceScript._load_run_v5_with_repository(
		seed_value, repo)
	if result == null or not result.is_ok():
		return {}
	return result.data


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
		print("  [FAIL] Stage 4A: %s" % label)
