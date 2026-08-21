class_name RunController extends Node
## Главный контроллер рана: связывает RunDomainState, BattleRunner, Shop, Economy.
##
## Phase 1 / T3F: live state is `RunDomainState` (canonical instance-id
## domain). All identity is bound to `RunUnit.instance_id` and
## `RunItem.instance_id`. Board / bench come from
## `RunUnit.location` + `RunUnit.order`. Equipment ownership is
## owned by `RunItem.owner_unit_id` and mirrored in
## `RunUnit.equipped_item_ids`. Persistence goes
## RunDomainState -> RunStateV4Mapper -> v4 DTO -> SaveService v4
## facade -> hardened RunSaveRepository.
##
## The legacy `RunState` Resource is FROZEN legacy wire-format only
## (it is the format the v1->v4 migrator and the v4 mapper's
## `from_v4_dto` reconstruct from, but it is NOT a mutable live
## state anymore). `RunUnitState` is similarly legacy and is no
## longer read or written by the live controller.
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
const ShopScreenScript = preload("res://core/progression/shop_screen.gd")
const RunDomainStateScript = preload("res://core/progression/run_domain_state.gd")
const RunStateV4MapperScript = preload("res://core/progression/run_state_v4_mapper.gd")
const LegacyBattleParticipantMapScript = preload("res://core/battle/legacy_battle_participant_map.gd")

var state: RunDomainState = RunDomainStateScript.new()
var shop: Shop = Shop.new()
var merchant_shop = ShopScreenScript.new()
var reward: RewardScreen = RewardScreen.new()
var ctx: BattleContext = null
var runner: BattleRunner = null
var phase: int = Phase.PREP
var profile: MetaProfile = null
# S5.3: encounter map owned by RunController после первого перехода в MAP phase.
# Scene получает его через get_encounter_map() и передаёт в EncounterMapScene.set_encounter_map().
var encounter_map: EncounterMap = null
# Phase 1 / T3F.5: per-battle identity bridge. Fresh for every
# start_battle. Maps each player Combatant Object to the
# RunUnit.instance_id it was built from. Cleared in
# `_on_battle_ended`. Enemies are NOT mapped.
var _battle_participants: LegacyBattleParticipantMap = null


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
	# Fresh canonical live state. Sequence counters start at 1.
	state = RunDomainStateScript.new()
	state.seed = seed_value
	state.gold = BalanceScript.STARTING_GOLD
	state.round_index = 1
	state.lives = BalanceScript.STARTING_LIVES
	# Стартовый набор юнитов сразу на доску. Each starter unit gets
	# a stable, freshly allocated instance_id (unit_000001,
	# unit_000002, ...). Duplicate starter definitions (e.g. two
	# warriors) would still get distinct instance_ids, but
	# BalanceScript.STARTING_UNIT_IDS today is [&"warrior", &"archer"]
	# which is distinct definitions.
	for id in BalanceScript.STARTING_UNIT_IDS:
		if ContentDB_static.get_by_id(id) == null:
			continue
		var def: Resource = ContentDB_static.get_by_id(id)
		var max_hp: int = def.max_hp if def != null else 100
		state.create_unit(id, max_hp, RunUnit.LOCATION_BOARD)
	_set_phase(Phase.PREP)
	_refresh_shop()
	run_started.emit()
	GameBus.emit_round_started(state.round_index)
	# S3.3: auto-save после создания state (если игрок сразу выйдет).
	save_now()
	GameLog.info("run", "Run started", {"seed": seed_value, "starting": state.units.size()})


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
	# Stable instance_id is allocated by RunDomainState.create_unit.
	state.create_unit(def.id, def.max_hp if def != null else 100, RunUnit.LOCATION_BENCH)
	shop.take_at(slot)
	GameBus.emit_gold_changed(state.gold)
	GameLog.info("run", "Bought unit", {"id": def.id, "gold_left": state.gold})
	return def


## S6.2: перемещает юнита в bench по позиции (board_index). Возвращает true если успешно.
func board_to_bench(board_index: int) -> bool:
	var board := state.get_board_units()
	if board_index < 0 or board_index >= board.size():
		return false
	if state.get_bench_units().size() >= BalanceScript.MAX_BENCH_UNITS:
		GameLog.warn("run", "board_to_bench: bench full", {"size": state.get_bench_units().size()})
		return false
	var u: RunUnit = board[board_index]
	return state.move_unit(u.instance_id, RunUnit.LOCATION_BENCH, -1)


## S6.2: перемещает юнита из bench на доску в указанную позицию. Возвращает true если успешно.
## Если board_index == -1, ищет первую свободную позицию (append).
func bench_to_board(bench_index: int, board_index: int = -1) -> bool:
	var bench := state.get_bench_units()
	if bench_index < 0 or bench_index >= bench.size():
		return false
	if state.get_board_units().size() >= BalanceScript.MAX_BOARD_UNITS:
		GameLog.warn("run", "bench_to_board: board full", {"size": state.get_board_units().size()})
		return false
	var u: RunUnit = bench[bench_index]
	return state.move_unit(u.instance_id, RunUnit.LOCATION_BOARD, board_index)


## S6.2: меняет местами двух юнитов на доске по позициям (0..MAX_BOARD_UNITS-1).
## Если b == -1, перемещает board[a] в bench.
func swap_board_units(a: int, b: int) -> bool:
	var board := state.get_board_units()
	var board_size: int = board.size()
	if a < 0 or a >= board_size:
		return false
	if b < 0 or b >= board_size:
		return false
	if a == b:
		return false
	var ua: RunUnit = board[a]
	var ub: RunUnit = board[b]
	return state.swap_units(ua.instance_id, ub.instance_id)


## Phase 1 / T3G.1: stable-identity mutations.
## These take `instance_id` directly so the scene never has to
## remember a board/bench index across events. The lookup
## happens at call time, against the current state.

## Swap two RunUnits by `instance_id` regardless of which side
## (board or bench) they currently occupy.
func swap_units_by_id(src_id: String, dst_id: String) -> bool:
	if src_id == "" or dst_id == "" or src_id == dst_id:
		return false
	return state.swap_units(src_id, dst_id)


## Move a RunUnit to the bench by `instance_id`. Returns false if
## the unit does not exist or the bench is full.
func board_to_bench_by_id(src_id: String) -> bool:
	if src_id == "":
		return false
	var u: RunUnit = state.get_unit(src_id)
	if u == null or u.location != RunUnit.LOCATION_BOARD:
		return false
	if state.get_bench_units().size() >= BalanceScript.MAX_BENCH_UNITS:
		GameLog.warn("run", "board_to_bench_by_id: bench full",
			{"size": state.get_bench_units().size()})
		return false
	return state.move_unit(src_id, RunUnit.LOCATION_BENCH, -1)


## Move a RunUnit from the bench to the board by `instance_id`.
## If `board_index` is -1, append to the first free slot.
func bench_to_board_by_id(src_id: String, board_index: int = -1) -> bool:
	if src_id == "":
		return false
	var u: RunUnit = state.get_unit(src_id)
	if u == null or u.location != RunUnit.LOCATION_BENCH:
		return false
	if state.get_board_units().size() >= BalanceScript.MAX_BOARD_UNITS:
		GameLog.warn("run", "bench_to_board_by_id: board full",
			{"size": state.get_board_units().size()})
		return false
	return state.move_unit(src_id, RunUnit.LOCATION_BOARD, board_index)


## Phase 1 / T3G.1: equip/unequip by RunItem.instance_id.
## The scene must not pass an item array index across events.
## Equips `item_instance_id` to the board unit whose
## `RunUnit.instance_id == target_unit_instance_id`. Returns
## false if the item or target unit does not exist.
func equip_item_by_id(item_instance_id: String,
		target_unit_instance_id: String) -> bool:
	if item_instance_id == "" or target_unit_instance_id == "":
		return false
	return state.equip_item(item_instance_id, target_unit_instance_id)


## Unequip a RunItem by `instance_id`. The item lands in
## inventory (owner_unit_id becomes "").
func unequip_item_by_id(item_instance_id: String) -> bool:
	if item_instance_id == "":
		return false
	return state.unequip_item(item_instance_id)


## Перемещает юнита со скамейки на доску (cell).
## v1 — упрощённо, без валидации cell.
func move_to_board(bench_index: int, _cell: Vector2i) -> bool:
	return bench_to_board(bench_index, -1)


# === S7.1: Inventory ===

## Добавляет предмет в инвентарь. Создаёт новый RunItem с
## stable instance_id. Capacity rule is total item count
## (inventory + equipped), matching legacy semantics.
## Возвращает true если успешно. Если уже MAX_INVENTORY предметов, returns false.
func grant_item(item_id: StringName) -> bool:
	if item_id == &"":
		GameLog.warn("inventory", "grant_item: empty id")
		return false
	if state.items.size() >= BalanceScript.MAX_INVENTORY:
		GameLog.warn("inventory", "grant_item: inventory full",
			{"size": state.items.size(), "max": BalanceScript.MAX_INVENTORY})
		return false
	state.create_item(item_id)
	GameLog.info("inventory", "item granted",
		{"id": item_id, "size": state.items.size()})
	return true


## Удаляет предмет по индексу (compatibility coordinate).
## index 0..state.items.size()-1 covers BOTH inventory and
## equipped items, matching legacy item_ids.
## Возвращает true если успешно.
func remove_item_at(idx: int) -> bool:
	if idx < 0 or idx >= state.items.size():
		return false
	var removed_id: String = state.items[idx].instance_id
	var ok: bool = state.remove_item(removed_id)
	if ok:
		GameLog.info("inventory", "item removed",
			{"id": removed_id, "idx": idx, "size": state.items.size()})
	return ok


## Кол-во предметов в инвентаре + equipped (legacy semantics).
func inventory_count() -> int:
	return state.items.size()


## Возвращает ItemDef для предмета по индексу или null.
func get_item_def_at(idx: int) -> Resource:
	if idx < 0 or idx >= state.items.size():
		return null
	return ContentDB_static.get_by_id(state.items[idx].definition_id)


# === S7.2: Equip ===

## Эипит предмет (item_idx) на board юнита (board_idx). Возвращает true.
## Если board_idx невалиден (нет такого юнита), returns false.
## Допускается эипить несколько предметов на одного юнита.
func equip_item_at(item_idx: int, board_idx: int) -> bool:
	if item_idx < 0 or item_idx >= state.items.size():
		return false
	var board := state.get_board_units()
	if board_idx < 0 or board_idx >= board.size():
		return false
	var item: RunItem = state.items[item_idx]
	var target: RunUnit = board[board_idx]
	return state.equip_item(item.instance_id, target.instance_id)


## Снимает предмет с юнита (возвращает в инвентарь).
func unequip_item_at(item_idx: int) -> bool:
	if item_idx < 0 or item_idx >= state.items.size():
		return false
	var item: RunItem = state.items[item_idx]
	return state.unequip_item(item.instance_id)


## Возвращает board_idx куда эипится item, или -1 если в инвентаре.
## Если владелец сейчас на bench — возвращает -1 (наследует
## legacy semantics: equip state was tracked per board index).
func get_equipped_board_idx(item_idx: int) -> int:
	if item_idx < 0 or item_idx >= state.items.size():
		return -1
	var item: RunItem = state.items[item_idx]
	var owner_id: String = String(item.owner_unit_id)
	if owner_id == "":
		return -1
	var owner: RunUnit = state.get_unit(owner_id)
	if owner == null:
		return -1
	if int(owner.location) != int(RunUnit.LOCATION_BOARD):
		return -1
	var board := state.get_board_units()
	for i in board.size():
		if board[i].instance_id == owner_id:
			return i
	return -1


## Возвращает array of item indices эипленных на board_idx.
func get_items_equipped_to_board(board_idx: int) -> Array:
	var result: Array = []
	var board := state.get_board_units()
	if board_idx < 0 or board_idx >= board.size():
		return result
	var target: RunUnit = board[board_idx]
	var equipped_items: Array[RunItem] = state.get_equipped_items(target.instance_id)
	# Translate to item indices for legacy caller compatibility.
	for it in equipped_items:
		var i: int = state.items.find(it)
		if i >= 0:
			result.append(i)
	return result


## Возвращает Dictionary {attack, defense, max_hp} — сумма bonus_*
## предметов эипленных на board_idx. Используется Combatant creation.
func get_unit_bonus_stats(board_idx: int) -> Dictionary:
	var stats: Dictionary = {"attack": 0, "defense": 0, "max_hp": 0}
	var board := state.get_board_units()
	if board_idx < 0 or board_idx >= board.size():
		return stats
	var u: RunUnit = board[board_idx]
	var equipped: Array[RunItem] = state.get_equipped_items(u.instance_id)
	for it in equipped:
		var def: Resource = ContentDB_static.get_by_id(it.definition_id)
		if def == null:
			continue
		stats["attack"] = int(stats.get("attack", 0)) + int(def.bonus_attack)
		stats["defense"] = int(stats.get("defense", 0)) + int(def.bonus_defense)
		stats["max_hp"] = int(stats.get("max_hp", 0)) + int(def.bonus_max_hp)
	return stats


## S7.4: покупает item из текущего shop offer (с MAP_MERCHANT_DISCOUNT).
## Возвращает true если успешно.
func buy_item(slot: int) -> bool:
	var offered: int = merchant_shop.get_offered_count()
	if slot < 0 or slot >= offered:
		return false
	var id: StringName = merchant_shop.get_item_id(slot)
	if id == &"":
		return false
	var price: int = merchant_shop.get_discounted_price(slot)
	if state.gold < price:
		GameLog.warn("run", "Shop buy: not enough gold",
			{"gold": state.gold, "price": price})
		return false
	if not grant_item(id):
		GameLog.warn("run", "Shop buy: grant_item failed (inv full?)", {"id": id})
		return false
	state.gold -= price
	GameBus.emit_gold_changed(state.gold)
	GameLog.info("run", "Shop buy",
		{"id": id, "price": price, "gold_left": state.gold})
	return true


## S7.4: выходит из shop/MERCHANT в MAP phase (используется shop_scene Close).
func exit_shop_to_map() -> void:
	if phase != Phase.PREP:
		return
	state.just_visited_merchant = false
	_set_phase(Phase.MAP)


## Запускает бой текущего раунда.
func start_battle() -> bool:
	if phase != Phase.PREP and phase != Phase.MAP:
		return false
	if state.get_board_units().is_empty():
		GameLog.warn("run", "No units on board")
		return false
	# Phase 1 / T3F.5: deterministic board snapshot used for the
	# entire start_battle call. Any mutation of state.units during
	# battle setup is reflected in state, but the participants
	# list is captured at THIS moment.
	var board_units: Array[RunUnit] = state.get_board_units()
	# S5.4: суммарный attack bonus от REST/SHRINE (для всех юнитов игрока).
	var total_attack_bonus: int = int(state.meta_modifiers.get("rest_attack_bonus", 0)) + \
		int(state.meta_modifiers.get("shrine_attack_bonus", 0))
	var atk_mul: float = 1.0 + float(total_attack_bonus) / 100.0
	ctx = BattleContext.new()
	# Fresh participant bridge for THIS battle.
	_battle_participants = LegacyBattleParticipantMapScript.new()
	# Расставляем игроков.
	for i in board_units.size():
		var u: RunUnit = board_units[i]
		var def: Resource = ContentDB_static.get_by_id(u.definition_id)
		if def == null:
			continue
		# Skip dead units.
		if not u.is_alive():
			continue
		var hp_override: int = -1
		if u.current_hp > 0:
			hp_override = u.current_hp
		# Apply per-unit persistent bonus_attack and equipped items.
		var bonuses: Dictionary = get_unit_bonus_stats(i)
		var bonus_atk: int = int(bonuses.get("attack", 0)) + int(u.bonus_attack)
		var bonus_def: int = int(bonuses.get("defense", 0))
		var bonus_hp: int = int(bonuses.get("max_hp", 0))
		var c = CombatantScript.new(def, 1.0, atk_mul, 1.0, hp_override, bonus_atk, bonus_def, bonus_hp)
		var cell: Vector2i = Vector2i(i, 3)  # Grid.SIZE.y - 1 == 3
		if not ctx.register(c, cell):
			GameLog.warn("run", "Cannot place player unit", {"i": i})
			continue
		# Bind Combatant Object -> RunUnit.instance_id.
		var bind_ok: bool = _battle_participants.bind(c, u.instance_id)
		if not bind_ok:
			# Invariant error: bridge already has this combatant or this id.
			# This should never happen for a fresh bridge in start_battle.
			GameLog.error("run", "participant bind failed",
				{"combatant": str(c), "instance_id": u.instance_id,
					"last_error": _battle_participants.get_last_error()})
		# Shield Block для paladin и guardian.
		if def.id in [&"paladin", &"guardian"]:
			var sb: Resource = ContentDB_static.get_by_id(&"shield_block")
			if sb != null:
				GameBus.emit_reaction_registered(c, sb)
	# Расставляем врагов (1 волна для v1: 1-3 врага).
	var wave: Array = _spawn_enemy_wave(state.round_index)
	for i in wave.size():
		var def: Resource = wave[i]
		if def == null:
			continue
		var c = CombatantScript.new(def)
		var cell: Vector2i = Vector2i(i, 0)
		ctx.register(c, cell)
		# Зарегистрировать AoO для врагов с меле-реакцией.
		if def.id in [&"orc_warrior", &"knight", &"paladin"]:
			var aoo: Resource = ContentDB_static.get_by_id(&"attack_of_opportunity")
			if aoo != null:
				GameBus.emit_reaction_registered(c, aoo)
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
	# Phase 1 / T3F.5: do NOT introduce new post-battle HP writeback.
	# Legacy semantics did not persist combat runtime HP back into
	# run state, and that contract is preserved.
	var winner: int = runner.state.winner_team
	# S3.3: auto-save ПОСЛЕ боя, ДО перехода в PREP/REWARD/GAMEOVER.
	# Это гарантирует, что state на диске = последний завершённый бой.
	save_now()
	# Clear battle lifetime bridge AFTER save.
	if _battle_participants != null:
		_battle_participants.clear()
		_battle_participants = null
	if winner == 0:
		state.wins += 1
		state.gold += BalanceScript.WIN_BONUS_GOLD + state.round_index
		GameBus.emit_gold_changed(state.gold)
		# S7.3: roll для drop random item (35% chance). Inventory full
		# обрабатывается silently в _grant_combat_drop.
		_grant_combat_drop()
		state.round_index += 1
		# S3.1: победа на MAX_ROUND завершает ран.
		if state.round_index > BalanceScript.MAX_ROUND:
			_end_run(true)
			return
		# S6.1: после каждой победы (включая round 1) показываем REWARD.
		# Затем _enter_prep_or_map_after_reward() маршрутизирует:
		# round 1 → PREP (стартовый набор уже на доске).
		# round 2..MAX_ROUND-1 → MAP (игрок выбирает следующий нод).
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
## Phase 1 / T3F.6: live state is RunDomainState. We map to a
## canonical v4 DTO via RunStateV4Mapper, hand it to
## SaveService.save_run_v4 (which routes through the hardened
## RunSaveRepository + file ops seam), and inspect the returned
## SaveLoadResult. On failure: do not update profile.current_run_seed
## (the meta would otherwise lie about an active run that did not
## actually persist).
func save_now() -> bool:
	if state == null or state.seed == 0:
		GameLog.warn("run", "save_now: no active state")
		return false
	var dto: Dictionary = RunStateV4MapperScript.to_v4_dto(state)
	var result: RefCounted = SaveService.save_run_v4(state.seed, dto)
	if result == null or not result.is_ok():
		var err: String = "unknown"
		var ctx_msg: String = ""
		if result != null:
			err = str(result.status)
			ctx_msg = str(result.context)
			if result.diagnostics != null:
				for d in result.diagnostics:
					GameLog.error("save", "save_now diagnostic",
						{"code": str(d.code),
						"detail": str(d.detail),
						"context": str(d.context)})
		GameLog.error("run", "save_now failed",
			{"seed": state.seed, "status": err, "context": ctx_msg})
		return false
	if profile != null:
		profile.current_run_seed = state.seed
		SaveService.save_meta(profile)
		GameBus.emit_run_saved(state.seed)
		GameLog.info("run", "Run saved", {"seed": state.seed, "round": state.round_index})
	return true


## S3.3: сбрасывает active run marker. Вызывается при _end_run.
func _clear_active_run() -> void:
	if profile != null and profile.current_run_seed != 0:
		profile.current_run_seed = 0
		# meta save уже вызывается в _end_run — здесь не дублируем.


## S3.3: загружает RunDomainState из диска по seed и продолжает ран.
## Phase 1 / T3F.7: live state is RunDomainState. We load the
## canonical v4 DTO through SaveService.load_run_v4 (which goes
## through the hardened RunSaveRepository and migrates legacy v1
## transparently), then run the DTO through RunStateV4Mapper.
## Transactional: if ANY step fails, self.state is left unchanged
## (the previous live state is preserved exactly as it was).
func resume_run(seed_value: int) -> bool:
	if seed_value == 0:
		GameLog.warn("run", "resume_run: seed == 0")
		return false
	# Save current state reference. If the load fails for any
	# reason, we DO NOT touch self.state.
	var previous: RunDomainState = state
	var result: RefCounted = SaveService.load_run_v4(seed_value)
	if result == null or not result.is_ok():
		var err: String = "unknown"
		if result != null:
			err = str(result.status)
			if result.diagnostics != null:
				for d in result.diagnostics:
					GameLog.error("save", "resume_run diagnostic", {"diag": str(d)})
		GameLog.warn("run", "resume_run: load failed", {"seed": seed_value, "status": err})
		return false
	var dto: Dictionary = result.data
	var loaded: RunDomainState = RunStateV4MapperScript.from_v4_dto(dto)
	if loaded == null:
		GameLog.error("run", "resume_run: mapper returned null", {"seed": seed_value})
		return false
	# All steps succeeded. Commit the new state.
	state = loaded
	# Rng восстанавливаем из seed для детерминизма (на случай если seed_run не звался).
	Rng.seed_run(state.seed)
	# Shop перегенерируем (transient — был утерян при restart).
	_refresh_shop()
	# S5.4: восстанавливаем encounter_map по seed. Карта детерминирована seed'ом,
	# поэтому можно регенерировать её при resume. goto_node(id) устанавливает
	# current_node_id на сохранённый (без проверки visited).
	if state.current_encounter_id != -1:
		encounter_map = EncounterMapScript.new()
		encounter_map.generate(state.seed)
		if not encounter_map.goto_node(state.current_encounter_id):
			GameLog.warn("run", "resume_run: saved encounter_id not in map",
				{"encounter_id": state.current_encounter_id})
			# Fallback: start fresh.
			encounter_map.start_run()
		else:
			_set_phase(Phase.MAP)
	else:
		_set_phase(Phase.PREP)

	if profile != null:
		profile.current_run_seed = state.seed
		SaveService.save_meta(profile)
	GameBus.emit_run_resumed(state.seed)
	GameLog.info("run", "Run resumed", {"seed": state.seed, "round": state.round_index, "encounter": state.current_encounter_id})
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
## Авто-размещение: если на доске меньше MAX_BOARD_UNITS, юнит сразу идёт
## на board. Иначе — на bench для будущего UI drag-drop.
## Переводит в MAP или PREP после выбора (S5.3).
func choose_reward(slot: int) -> Resource:
	if phase != Phase.REWARD:
		return null
	var def: Resource = reward.offer_at(slot)
	if def == null:
		return null
	# S6.1.1: auto-place reward unit onto board if there's room.
	if state.get_board_units().size() < BalanceScript.MAX_BOARD_UNITS:
		state.create_unit(def.id, def.max_hp if def != null else 100, RunUnit.LOCATION_BOARD)
		GameLog.info("run", "Reward chosen (auto-placed on board)",
			{"id": def.id, "round": state.round_index, "board_size": state.get_board_units().size()})
	else:
		# Board full — bench. Будет виден в future bench UI.
		if state.get_bench_units().size() >= BalanceScript.MAX_BENCH_UNITS:
			GameLog.warn("run", "Reward chosen but bench full",
				{"id": def.id, "bench": state.get_bench_units().size()})
			return null
		state.create_unit(def.id, def.max_hp if def != null else 100, RunUnit.LOCATION_BENCH)
		GameLog.info("run", "Reward chosen (sent to bench)",
			{"id": def.id, "round": state.round_index, "bench_size": state.get_bench_units().size()})
	GameBus.emit_reward_chosen(def.id, slot)
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
	# S6.2: combat → PREP (placement screen перед боем), не BATTLE напрямую.
	# Игрок расставляет юнитов, нажимает Ready → start_battle().
	# S5.4: combat -> battle, save happens в _on_battle_ended (before phase transition).
	save_now()
	if node.is_combat():
		_set_phase(Phase.PREP)
	else:
		_apply_service_effect(node)
		# S5.4: atomic save AFTER service effect.
		save_now()


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
	# S5.4: atomic save — guarantees save file содержит post-effect state
	# (включая rest_attack_bonus после REST, gold_after_treasure, и т.д.).
	save_now()
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
# Phase 1 / T3F.4: each effect iterates the BOARD units (matching
# legacy semantics: "player_unit_ids" was the board list) and
# mutates each RunUnit by instance_id. No definition_id lookups,
# no board-index ownership.

## HEAL: восстанавливает HP-ratio всем board юнитам + 1 жизнь (cap).
func _apply_heal_effect() -> void:
	# HEAL: hp + 40% от max_hp, additive поверх current_hp.
	# Operates on a snapshot because healing mutates board
	# (no — healing does not move units; snapshot is just defensive
	# against future schema changes that could).
	for u in state.get_board_units():
		var def: Resource = ContentDB_static.get_by_id(u.definition_id)
		if def == null:
			continue
		var heal_amount: int = int(round(float(u.max_hp) * BalanceScript.MAP_HEAL_HP_RATIO))
		_heal_run_unit(u, heal_amount)
	# +1 жизнь cap = STARTING_LIVES * 2 (можно перенести в Balance).
	state.lives = mini(state.lives + 1, BalanceScript.STARTING_LIVES * 2)
	GameBus.emit_lives_changed(state.lives)
	GameLog.info("run", "HEAL: restored HP + 1 life",
		{"hp_ratio": BalanceScript.MAP_HEAL_HP_RATIO, "lives": state.lives})


## TREASURE: +gold + 1 meta unlock юнита + random inventory item.
func _apply_treasure_effect() -> void:
	var gold_before: int = state.gold
	state.gold += BalanceScript.MAP_TREASURE_GOLD
	GameBus.emit_gold_changed(state.gold)
	var unlocked: StringName = UnlockManager.grant_random_unit(profile, state.round_index)
	# S7.1: каждый TREASURE ещё grants 1 random ItemDef в инвентарь.
	var item_id: StringName = _pick_random_item_id()
	var item_granted: bool = false
	if item_id != &"":
		item_granted = grant_item(item_id)
	GameLog.info("run", "TREASURE",
		{
			"gold": state.gold - gold_before,
			"unlocked": unlocked,
			"item": item_id,
			"item_granted": item_granted,
		})


## S7.3: roll для drop random item после combat victory. Возвращает true если granted.
## Вызывается из _on_battle_ended. Inventory full → returns false silently.
func _grant_combat_drop() -> bool:
	if Rng.randf() >= BalanceScript.MAP_COMBAT_DROP_CHANCE:
		return false
	var item_id: StringName = _pick_random_item_id()
	if item_id == &"":
		return false
	var ok: bool = grant_item(item_id)
	if ok:
		GameLog.info("run", "Combat drop", {"id": item_id, "wins": state.wins})
	return ok


## S7.1: выбирает random ItemDef id из ContentDB. Возвращает &"" если ничего нет.
func _pick_random_item_id() -> StringName:
	var ids: Array = ContentDB_static.get_all_ids_for_type("items")
	if ids.is_empty():
		return &""
	var idx: int = int(Rng.randf_range(0.0, float(ids.size())))
	if idx >= ids.size():
		idx = ids.size() - 1
	return ids[idx] if idx >= 0 else &""


## MERCHANT: переходит в PREP с отдельным item offer.
func _apply_merchant_effect() -> void:
	GameLog.info("run", "MERCHANT: shop opened")
	state.just_visited_merchant = true
	_refresh_merchant_shop()
	_set_phase(Phase.PREP)


## REST: heal all board units + +1 attack всем юнитам игрока (permanent на ран).
func _apply_rest_effect() -> void:
	for u in state.get_board_units():
		var def: Resource = ContentDB_static.get_by_id(u.definition_id)
		if def == null:
			continue
		var heal_amount: int = int(round(float(u.max_hp) * BalanceScript.MAP_REST_HP_RATIO))
		_heal_run_unit(u, heal_amount)
	# +attack bonus — модифицируем meta_modifiers (transient, applied in start_battle).
	# Per-unit RunUnit.bonus_attack is a separate persistent field
	# that survives save/load independently of meta_modifiers.
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
			# +HP всем board units (cap = max_hp * 1.5)
			for u in state.get_board_units():
				var def: Resource = ContentDB_static.get_by_id(u.definition_id)
				if def == null:
					continue
				var heal_amount: int = maxi(1, int(round(float(u.max_hp) * BalanceScript.MAP_SHRINE_HP_BONUS / 100.0)))
				_heal_run_unit(u, heal_amount)
			GameLog.info("run", "SHRINE: HP +%d" % BalanceScript.MAP_SHRINE_HP_BONUS)
		_:
			# +attack (мультик) — увеличиваем meta_modifiers
			state.meta_modifiers["shrine_attack_bonus"] = int(state.meta_modifiers.get("shrine_attack_bonus", 0)) + BalanceScript.MAP_SHRINE_ATTACK_BONUS
			GameLog.info("run", "SHRINE: attack +%d" % BalanceScript.MAP_SHRINE_ATTACK_BONUS)


## Phase 1 / T3F.4: per-RunUnit heal, replacing the old
## `_heal_unit_state` helper. Operates by instance_id, respects
## the sentinel (-1 = use max_hp). Does NOT touch dead units
## (current_hp == 0 explicitly).
func _heal_run_unit(u: RunUnit, heal_amount: int) -> int:
	if u == null:
		return 0
	if not u.is_alive():
		return 0  # мёртвые не хилируются
	if u.max_hp <= 0:
		return 0
	# Sentinel: current_hp == -1 means "use max_hp".
	var current: int = u.current_hp
	if current < 0:
		current = u.max_hp
	var new_hp: int = mini(u.max_hp, current + heal_amount)
	u.current_hp = new_hp
	return new_hp - current


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


func _refresh_merchant_shop() -> void:
	merchant_shop.refresh()




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
