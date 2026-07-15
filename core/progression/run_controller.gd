class_name RunController extends Node
## Главный контроллер рана: связывает RunState, BattleRunner, Shop, Economy.
##
## v1 — тонкая обёртка без UI. UI подписывается на сигналы EventBus и
## дёргает методы контроллера для покупки/расстановки/старта боя.

signal run_started
signal run_ended(won: bool)
signal phase_changed(phase: int)

enum Phase { PREP, BATTLE, REWARD, GAMEOVER, MAP, SERVICE }

const CombatantScript = preload("res://core/battle/combatant.gd")
const BattleRunnerScript = preload("res://core/battle/battle_runner.gd")
const GridScript = preload("res://core/battle/grid.gd")
const BalanceScript = preload("res://core/balance.gd")
const EncounterMapScript = preload("res://core/encounter/encounter_map.gd")
const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")

var state: RunState = RunState.new()
var shop: Shop = Shop.new()
var reward: RewardScreen = RewardScreen.new()
var ctx: BattleContext = null
var runner: BattleRunner = null
var phase: int = Phase.PREP
var profile: MetaProfile = null
# S5.3: encounter map owned by RunController после первого перехода в MAP phase.
# Scene получает его через get_encounter_map() и передаёт в EncounterMapScene.set_encounter_map().
var encounter_map: EncounterMap = null


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
	# S3.3: auto-save после создания state (если игрок сразу выйдет).
	save_now()
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
	if phase != Phase.PREP and phase != Phase.MAP:
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
	# S3.3: auto-save ПОСЛЕ боя, ДО перехода в PREP/REWARD/GAMEOVER.
	# Это гарантирует, что state на диске = последний завершённый бой.
	save_now()
	if winner == 0:
		state.wins += 1
		state.gold += BalanceScript.WIN_BONUS_GOLD + state.round_index
		GameBus.emit_gold_changed(state.gold)
		state.round_index += 1
		# S3.1: победа на MAX_ROUND завершает ран.
		if state.round_index > BalanceScript.MAX_ROUND:
			_end_run(true)
			return
		# S5.3: round 1 → PREP (стартовый набор, без MAP и без REWARD).
		if state.round_index == 2:
			# Победа в первом бою — без reward, сразу в PREP для следующего раунда.
			# Это сохраняет существующее поведение round 1 → PREP.
			_set_phase(Phase.PREP)
			_refresh_shop()
			GameBus.emit_round_started(state.round_index)
		else:
			# Round 2..MAX_ROUND-1 → reward screen.
			_enter_reward()
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
		# S3.2: за каждую победу — unlock юнита в meta profile.
		# META_UNLOCKS_PER_WIN=1 по умолчанию (расширяется в балансе).
		for _i in BalanceScript.META_UNLOCKS_PER_WIN:
			var new_id: StringName = UnlockManager.grant_random_unit(profile, state.round_index)
			if new_id != &"":
				GameBus.emit_unit_unlocked(new_id)
	profile.best_round = maxi(profile.best_round, state.round_index)
	UnlockManager.award_souls(profile, state.round_index)
	# S3.3: ран завершён — current_run_seed = 0 (нечего продолжать).
	_clear_active_run()
	SaveService.save_meta(profile)
	run_ended.emit(won)
	GameLog.info("run", "Run ended", {"round": state.round_index, "won": won})


# === S3.3: Save/Load в середине рана ===

## Сохраняет текущий state + обновляет profile.current_run_seed.
## Вызывай вручную (кнопка "Save") или из auto-save хуков.
## Возвращает true если сохранено успешно.
func save_now() -> bool:
	if state == null or state.seed == 0:
		GameLog.warn("run", "save_now: no active state")
		return false
	var ok: bool = SaveService.save_run(state)
	if ok and profile != null:
		profile.current_run_seed = state.seed
		SaveService.save_meta(profile)
		GameBus.emit_run_saved(state.seed)
		GameLog.info("run", "Run saved", {"seed": state.seed, "round": state.round_index})
	return ok


## S3.3: сбрасывает active run marker. Вызывается при _end_run.
func _clear_active_run() -> void:
	if profile != null and profile.current_run_seed != 0:
		profile.current_run_seed = 0
		# meta save уже вызывается в _end_run — здесь не дублируем.


## S3.3: загружает RunState из диска по seed и продолжает ран с PREP фазы.
## Возвращает true если state загружен успешно.
## НЕ пересоздаёт state — заменяет self.state на загруженный.
## Если файла нет — возвращает false, state остаётся прежним.
func resume_run(seed_value: int) -> bool:
	if seed_value == 0:
		GameLog.warn("run", "resume_run: seed == 0")
		return false
	var loaded: RunState = SaveService.load_run(seed_value)
	if loaded == null:
		GameLog.warn("run", "resume_run: no save for seed", {"seed": seed_value})
		return false
	state = loaded
	# Rng восстанавливаем из seed для детерминизма (на случай если seed_run не звался).
	Rng.seed_run(state.seed)
	# Shop перегенерируем (transient — был утерян при restart).
	_refresh_shop()
	_set_phase(Phase.PREP)
	if profile != null:
		profile.current_run_seed = state.seed
		SaveService.save_meta(profile)
	GameBus.emit_run_resumed(state.seed)
	GameLog.info("run", "Run resumed", {"seed": state.seed, "round": state.round_index})
	return true


## S5.1.5: переход в фазу REWARD после победы (кроме round 1).
func _enter_reward() -> void:
	reward.generate_offer(state.round_index)
	_set_phase(Phase.REWARD)
	GameBus.emit_reward_offered(reward.offered_ids())
	# S3.3: auto-save после генерации offer.
	save_now()
	GameLog.info("run", "Reward offered", {"round": state.round_index, "ids": reward.offered_ids()})


## S5.3: возвращает куда переходить после REWARD (round 1 → PREP, иначе → MAP).
func _enter_prep_or_map_after_reward() -> void:
	# round 1: после skip_reward → PREP (стартовый набор уже на доске).
	# round 2..MAX_ROUND: после REWARD → MAP (игрок выбирает следующий нод).
	# round > MAX_ROUND: boss победили → GAMEOVER (уже сработал в _on_battle_ended).
	if state.round_index >= 2 and state.round_index <= BalanceScript.MAX_ROUND:
		_enter_map()
	else:
		_set_phase(Phase.PREP)
		_refresh_shop()
		GameBus.emit_round_started(state.round_index)


## Игрок выбирает юнита из reward. Возвращает UnitDef или null.
## Переводит в MAP или PREP после выбора (S5.3).
func choose_reward(slot: int) -> Resource:
	if phase != Phase.REWARD:
		return null
	var def: Resource = reward.offer_at(slot)
	if def == null:
		return null
	state.bench_unit_ids.append(def.id)
	GameBus.emit_reward_chosen(def.id, slot)
	GameLog.info("run", "Reward chosen", {"id": def.id, "round": state.round_index})
	_enter_prep_or_map_after_reward()
	return def


## Игрок пропускает reward. Возвращает true если успешно.
func skip_reward() -> bool:
	if phase != Phase.REWARD:
		return false
	GameLog.info("run", "Reward skipped", {"round": state.round_index})
	# S5.3: round 1 → PREP, иначе → MAP.
	_enter_prep_or_map_after_reward()
	return true


func _set_phase(p: int) -> void:
	phase = p
	phase_changed.emit(p)


## S5.3: возвращает encounter_map (или null если MAP phase ещё не наступила).
func get_encounter_map() -> EncounterMap:
	return encounter_map


## S5.3: внешний вход для UI — игрок кликнул на ноде в encounter_map_view.
## Если фаза MAP и узел доступен — переходит в combat или применяет service effect.
func _on_node_selected(node_id: int) -> void:
	if phase != Phase.MAP:
		return
	if encounter_map == null:
		GameLog.warn("run", "_on_node_selected: no encounter_map")
		return
	# Validate: node_id должен быть в available_next_ids (UI тоже это проверяет).
	if node_id not in encounter_map.get_available_next_ids():
		GameLog.warn("run", "_on_node_selected: invalid node_id", {"node_id": node_id})
		return
	# Применяем переход по графу.
	if not encounter_map.choose_next(node_id):
		GameLog.warn("run", "_on_node_selected: choose_next failed", {"node_id": node_id})
		return
	var node = encounter_map.get_node(node_id)
	if node == null:
		return
	# Сохраняем в state.
	state.current_encounter_id = node_id
	state.encounter_visited_ids.append(node_id)
	save_now()
	# Dispatch.
	if node.is_combat():
		start_battle()
	else:
		_apply_service_effect(node)


## S5.3: применяет service-эффект выбранного нода (HEAL/TREASURE/MERCHANT/REST/SHRINE).
## После эффекта — назад в MAP (если есть следующие узлы) или GAMEOVER.
## MERCHANT устанавливает phase=PREP и stay там (UI остаётся прежним — игрок
## покупает через buy_unit). Остальные эффекты возвращают в MAP для следующего выбора.
func _apply_service_effect(node) -> void:
	if phase != Phase.MAP:
		return
	var kind: int = node.type
	var stay_in_current_phase: bool = false
	match kind:
		EncounterTypeScript.Kind.HEAL:
			_apply_heal_effect()
		EncounterTypeScript.Kind.TREASURE:
			_apply_treasure_effect()
		EncounterTypeScript.Kind.MERCHANT:
			_apply_merchant_effect()
			stay_in_current_phase = true  # MERCHANT переходит в PREP
		EncounterTypeScript.Kind.REST:
			_apply_rest_effect()
		EncounterTypeScript.Kind.SHRINE:
			_apply_shrine_effect()
		_:
			GameLog.warn("run", "Unknown service kind", {"kind": kind})
	# После service-эффекта — обратно в MAP (если эффект не оставил нас в другой фазе).
	if stay_in_current_phase:
		return
	if state.round_index > BalanceScript.MAX_ROUND:
		_end_run(true)
		return
	if encounter_map == null:
		return
	var available: Array[int] = encounter_map.get_available_next_ids()
	if available.is_empty():
		# Нет следующих ходов (boss-only path) — завершаем.
		_end_run(true)
		return
	_set_phase(Phase.MAP)


# === S5.3: service effect implementations ===

## HEAL: восстанавливает HP-ratio всем юнитам + 1 жизнь (cap).
func _apply_heal_effect() -> void:
	var heal_amount: int = int(round(BalanceScript.MAP_HEAL_HP_RATIO * 100.0))
	# HP восстанавливается напрямую на max_hp ratio (текущий hp + ratio * max_hp, capped).
	for id in state.player_unit_ids:
		var def: Resource = ContentDB_static.get_by_id(id)
		if def == null:
			continue
		var max_hp: int = def.max_hp
		# Healed = ratio * max_hp (от max, не от текущего — упрощение).
		var hp_now: int = _get_player_unit_hp(id)
		var new_hp: int = mini(max_hp, hp_now + int(round(float(max_hp) * BalanceScript.MAP_HEAL_HP_RATIO)))
		_set_player_unit_hp(id, new_hp)
	# +1 жизнь cap = STARTING_LIVES * 2 (можно перенести в Balance).
	state.lives = mini(state.lives + 1, BalanceScript.STARTING_LIVES * 2)
	GameBus.emit_lives_changed(state.lives)
	GameLog.info("run", "HEAL: restored HP + 1 life",
		{"heal_amount": heal_amount, "lives": state.lives})


## TREASURE: +gold + 1 meta unlock юнита.
func _apply_treasure_effect() -> void:
	var gold_before: int = state.gold
	state.gold += BalanceScript.MAP_TREASURE_GOLD
	GameBus.emit_gold_changed(state.gold)
	var unlocked: StringName = UnlockManager.grant_random_unit(profile, state.round_index)
	GameLog.info("run", "TREASURE",
		{"gold": state.gold - gold_before, "unlocked": unlocked})


## MERCHANT: переходит в PREP (shop уже обновлён в _refresh_shop).
func _apply_merchant_effect() -> void:
	GameLog.info("run", "MERCHANT: shop opened")
	_set_phase(Phase.PREP)
	_refresh_shop()


## REST: heal all + +1 attack всем юнитам игрока (permanent на ран).
func _apply_rest_effect() -> void:
	for id in state.player_unit_ids:
		var def: Resource = ContentDB_static.get_by_id(id)
		if def == null:
			continue
		var max_hp: int = def.max_hp
		var new_hp: int = mini(max_hp,
			int(round(float(max_hp) * BalanceScript.MAP_REST_HP_RATIO)))
		_set_player_unit_hp(id, new_hp)
		# +attack bonus — модифицируем State (для трекинга), не Resource.
	state.meta_modifiers["rest_attack_bonus"] = int(state.meta_modifiers.get("rest_attack_bonus", 0)) + BalanceScript.MAP_REST_ATTACK_BONUS
	GameLog.info("run", "REST",
		{"hp_restore_pct": BalanceScript.MAP_REST_HP_RATIO,
		"attack_bonus": BalanceScript.MAP_REST_ATTACK_BONUS})


## SHRINE: случайный buff из 4 опций (Rng-детерминированно).
func _apply_shrine_effect() -> void:
	var pick: int = Rng.randi_range(0, 3)
	match pick:
		0:
			state.gold += BalanceScript.MAP_SHRINE_GOLD_BONUS
			GameBus.emit_gold_changed(state.gold)
			GameLog.info("run", "SHRINE: gold +%d" % BalanceScript.MAP_SHRINE_GOLD_BONUS)
		1:
			state.lives = mini(state.lives + 1, BalanceScript.STARTING_LIVES * 2)
			GameBus.emit_lives_changed(state.lives)
			GameLog.info("run", "SHRINE: lives +1 (now %d)" % state.lives)
		2:
			# +HP всем юнитам (cap = max_hp * 1.5)
			for id in state.player_unit_ids:
				var def: Resource = ContentDB_static.get_by_id(id)
				if def == null:
					continue
				var max_hp: int = def.max_hp
				var new_hp: int = mini(int(round(float(max_hp) * 1.5)),
					int(round(float(max_hp) * BalanceScript.MAP_SHRINE_HP_BONUS / 100.0 + _get_player_unit_hp(id))))
				_set_player_unit_hp(id, new_hp)
			GameLog.info("run", "SHRINE: HP +%d" % BalanceScript.MAP_SHRINE_HP_BONUS)
		_:
			# +attack (мультик) — увеличиваем meta_modifiers
			state.meta_modifiers["shrine_attack_bonus"] = int(state.meta_modifiers.get("shrine_attack_bonus", 0)) + BalanceScript.MAP_SHRINE_ATTACK_BONUS
			GameLog.info("run", "SHRINE: attack +%d" % BalanceScript.MAP_SHRINE_ATTACK_BONUS)


## S5.3: получить HP игрока. Упрощение — возвращает max_hp (по факту мы
## не отслеживаем HP на уровне state, Combatant хранит в бою). Heal работает
## относительно max_hp, что означает "исцеление на MAP возвращает к max".
func _get_player_unit_hp(_id: StringName) -> int:
	return 0


## S5.3: установить HP игрока (для тестов и эффектов). В v1 — no-op,
## эффекты работают в относительных терминах.
func _set_player_unit_hp(_id: StringName, _new_hp: int) -> void:
	pass


## S5.3: вызывается из _on_battle_ended() после REWARD.
## Создаёт encounter_map (lazy) и переключает в MAP.
func _enter_map() -> void:
	if encounter_map == null:
		# Lazy create.
		Rng.seed_run(state.seed)
		encounter_map = EncounterMapScript.new()
		encounter_map.generate(state.seed)
	# Если MAP phase прерывается на середине — продолжаем с того же current.
	if encounter_map.get_current_node_id() == -1:
		encounter_map.start_run()
	state.current_encounter_id = encounter_map.get_current_node_id()
	_set_phase(Phase.MAP)
	save_now()
	GameLog.info("run", "Map entered", {
		"current": state.current_encounter_id,
		"available": encounter_map.get_available_next_ids().size(),
	})


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
