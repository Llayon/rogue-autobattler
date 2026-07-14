class_name RunController extends Node
## Главный контроллер рана: связывает RunState, BattleRunner, Shop, Economy.
##
## v1 — тонкая обёртка без UI. UI подписывается на сигналы EventBus и
## дёргает методы контроллера для покупки/расстановки/старта боя.

signal run_started
signal run_ended(won: bool)
signal phase_changed(phase: int)

enum Phase { PREP, BATTLE, REWARD, GAMEOVER }

const CombatantScript = preload("res://core/battle/combatant.gd")
const BattleRunnerScript = preload("res://core/battle/battle_runner.gd")
const GridScript = preload("res://core/battle/grid.gd")
const BalanceScript = preload("res://core/balance.gd")

var state: RunState = RunState.new()
var shop: Shop = Shop.new()
var ctx: BattleContext = null
var runner: BattleRunner = null
var phase: int = Phase.PREP
var profile: MetaProfile = null


func _ready() -> void:
	profile = SaveService.load_meta()
	if profile == null:
		profile = MetaProfile.new()


## Запускает новый ран с заданным seed.
## Если seed == 0 — берётся случайный.
func start_run(seed_value: int = 0) -> void:
	if seed_value == 0:
		seed_value = Rng.randi_range(1, 999999)
	Rng.seed_run(seed_value)
	state = RunState.new()
	state.seed = seed_value
	state.gold = BalanceScript.STARTING_GOLD
	state.round_index = 1
	state.lives = BalanceScript.STARTING_LIVES
	# Стартовый набор юнитов сразу на доску.
	state.player_unit_ids.clear()
	for id in BalanceScript.STARTING_UNIT_IDS:
		if ContentDB_static.get_by_id(id) != null:
			state.player_unit_ids.append(id)
	_set_phase(Phase.PREP)
	_refresh_shop()
	run_started.emit()
	GameBus.emit_round_started(state.round_index)
	GameLog.info("run", "Run started", {"seed": seed_value, "starting": state.player_unit_ids.size()})


## Покупает юнита из слота магазина и ставит на скамейку (bench).
## Возвращает купленный UnitDef или null.
func buy_unit(slot: int) -> Resource:
	if phase != Phase.PREP:
		return null
	var def: Resource = shop.offer_at(slot)
	if def == null:
		return null
	if state.gold < def.cost:
		GameLog.debug("run", "Not enough gold", {"need": def.cost, "have": state.gold})
		return null
	state.gold -= def.cost
	state.bench_unit_ids.append(def.id)
	shop.take_at(slot)
	GameBus.emit_gold_changed(state.gold)
	GameLog.info("run", "Bought unit", {"id": def.id, "gold_left": state.gold})
	return def


## Перемещает юнита со скамейки на доску (cell).
## v1 — упрощённо, без валидации cell.
func move_to_board(bench_index: int, _cell: Vector2i) -> bool:
	if bench_index < 0 or bench_index >= state.bench_unit_ids.size():
		return false
	var id: StringName = state.bench_unit_ids[bench_index]
	state.bench_unit_ids.remove_at(bench_index)
	state.player_unit_ids.append(id)
	return true


## Запускает бой текущего раунда.
func start_battle() -> bool:
	if phase != Phase.PREP:
		return false
	if state.player_unit_ids.is_empty():
		GameLog.warn("run", "No units on board")
		return false
	ctx = BattleContext.new()
	# Расставляем игроков.
	for i in state.player_unit_ids.size():
		var def: Resource = ContentDB_static.get_by_id(state.player_unit_ids[i])
		if def == null:
			continue
		var c = CombatantScript.new(def)
		var cell: Vector2i = Vector2i(i, 3)  # Grid.SIZE.y - 1 == 3
		if not ctx.register(c, cell):
			GameLog.warn("run", "Cannot place player unit", {"i": i})
	# Расставляем врагов (1 волна для v1: 1-3 врага).
	var wave: Array = _spawn_enemy_wave(state.round_index)
	for i in wave.size():
		var def: Resource = wave[i]
		if def == null:
			continue
		var c = CombatantScript.new(def)
		var cell: Vector2i = Vector2i(i, 0)
		ctx.register(c, cell)
	runner = BattleRunnerScript.new(ctx)
	runner.start()
	_set_phase(Phase.BATTLE)
	GameBus.emit_round_started(state.round_index)
	return true


## Тикает бой. Вызывай из сцены каждый кадр с учётом speed.
func tick_battle(dt: float) -> void:
	if runner == null:
		return
	runner.step(dt)
	if runner.state.phase == 2:  # BattleState.Phase.ENDED
		_on_battle_ended()


func _on_battle_ended() -> void:
	var winner: int = runner.state.winner_team
	if winner == 0:
		state.wins += 1
		state.gold += BalanceScript.WIN_BONUS_GOLD + state.round_index
		GameBus.emit_gold_changed(state.gold)
		state.round_index += 1
		_set_phase(Phase.PREP)
		_refresh_shop()
		GameBus.emit_round_started(state.round_index)
	elif winner == 1:
		state.losses += 1
		state.lives -= 1
		if state.lives <= 0:
			_end_run(false)
		else:
			state.round_index += 1
			_set_phase(Phase.PREP)
			_refresh_shop()
	else:
		_end_run(false)


func _end_run(won: bool) -> void:
	_set_phase(Phase.GAMEOVER)
	profile.total_runs += 1
	if won:
		profile.total_wins += 1
	profile.best_round = maxi(profile.best_round, state.round_index)
	UnlockManager.award_souls(profile, state.round_index)
	SaveService.save_meta(profile)
	SaveService.save_run(state)
	run_ended.emit(won)
	GameLog.info("run", "Run ended", {"round": state.round_index, "won": won})


func _set_phase(p: int) -> void:
	phase = p
	phase_changed.emit(p)


func _refresh_shop() -> void:
	shop.refresh(profile.unlocked_units)


func _spawn_enemy_wave(round_index: int) -> Array:
	# Количество врагов берётся из Balance (single source of truth).
	var n: int = BalanceScript.enemy_count_for_round(round_index)
	var goblin: Resource = ContentDB_static.get_by_id(&"goblin")
	var result: Array = []
	for i in n:
		if goblin != null:
			result.append(goblin)
	return result