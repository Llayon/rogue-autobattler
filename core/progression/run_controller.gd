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
var reward: RewardScreen = RewardScreen.new()
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
		# S3.1: победа на MAX_ROUND завершает ран.
		if state.round_index > BalanceScript.MAX_ROUND:
			_end_run(true)
			return
		# S3.1.5: после первой победы (round_index >= 2) — reward screen.
		# На round 1 → сразу PREP (стартовый набор).
		if state.round_index >= 2:
			_enter_reward()
		else:
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


## S3.1.5: переход в фазу REWARD после победы (кроме round 1).
func _enter_reward() -> void:
	reward.generate_offer(state.round_index)
	_set_phase(Phase.REWARD)
	GameBus.emit_reward_offered(reward.offered_ids())
	GameLog.info("run", "Reward offered", {"round": state.round_index, "ids": reward.offered_ids()})


## Игрок выбирает юнита из reward. Возвращает UnitDef или null.
## Переводит в PREP после выбора.
func choose_reward(slot: int) -> Resource:
	if phase != Phase.REWARD:
		return null
	var def: Resource = reward.offer_at(slot)
	if def == null:
		return null
	state.bench_unit_ids.append(def.id)
	GameBus.emit_reward_chosen(def.id, slot)
	GameLog.info("run", "Reward chosen", {"id": def.id, "round": state.round_index})
	_set_phase(Phase.PREP)
	_refresh_shop()
	GameBus.emit_round_started(state.round_index)
	return def


## Игрок пропускает reward. Возвращает true если успешно.
func skip_reward() -> bool:
	if phase != Phase.REWARD:
		return false
	GameLog.info("run", "Reward skipped", {"round": state.round_index})
	_set_phase(Phase.PREP)
	_refresh_shop()
	GameBus.emit_round_started(state.round_index)
	return true


func _set_phase(p: int) -> void:
	phase = p
	phase_changed.emit(p)


func _refresh_shop() -> void:
	shop.refresh(profile.unlocked_units)


func _spawn_enemy_wave(round_index: int) -> Array:
	# Количество врагов и пул берутся из Balance (single source of truth).
	var n: int = BalanceScript.enemy_count_for_round(round_index)
	var pool: Array = BalanceScript.enemy_pool_for_round(round_index)
	var hp_mult: float = BalanceScript.enemy_hp_multiplier(round_index)
	var result: Array = []
	for i in n:
		var pool_id: StringName = pool[Rng.randi_range(0, pool.size() - 1)] if not pool.is_empty() else &"goblin"
		var enemy_def: Resource = ContentDB_static.get_by_id(pool_id)
		if enemy_def == null:
			continue
		# HP scaling по раунду: применяем через временный def clone.
		# Клонируем Resource через .duplicate() — Godot поддерживает это.
		var scaled: Resource = enemy_def.duplicate()
		scaled.max_hp = int(round(float(scaled.max_hp) * hp_mult))
		result.append(scaled)
	return result