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
const BattleStateScript = preload("res://core/battle/battle_state.gd")
const GridScript = preload("res://core/battle/grid.gd")
const BalanceScript = preload("res://core/balance.gd")
const EncounterMapScript = preload("res://core/encounter/encounter_map.gd")
const EncounterTypeScript = preload("res://core/encounter/encounter_type.gd")
const ShopScreenScript = preload("res://core/progression/shop_screen.gd")
const RunDomainStateScript = preload("res://core/progression/run_domain_state.gd")
const RunStateV4MapperScript = preload("res://core/progression/run_state_v4_mapper.gd")
const RunCheckpointV5MapperScript = preload("res://core/progression/run_checkpoint_v5_mapper.gd")
const RunSaveReportScript = preload("res://core/progression/run_save_report.gd")
const SaveSchemaV5Script = preload("res://core/save/save_schema_v5.gd")
const RngServiceScript = preload("res://core/utils/rng_service.gd")
const LegacyBattleParticipantMapScript = preload("res://core/battle/legacy_battle_participant_map.gd")
const ReactionDefScript = preload("res://core/data/reaction_def.gd")

## Id of the LEGACY view of the Shield Block reaction.
##
## The shipping content id is &"shield_block" (the Phase-3
## pre-damage window). The legacy view gets its own id so the two
## combat systems can never select the same reaction object.
const LEGACY_SHIELD_BLOCK_ID: StringName = &"shield_block_legacy"

## The legacy trigger name the old combat system polls for.
const LEGACY_SHIELD_BLOCK_TRIGGER: StringName = &"unit_attacked"

var state: RunDomainState = RunDomainStateScript.new()
var shop: Shop = Shop.new()
var merchant_shop = ShopScreenScript.new()
var reward: RewardScreen = RewardScreen.new()
var ctx: BattleContext = null
var runner: BattleRunner = null
var phase: int = Phase.PREP
var profile: MetaProfile = null
## The save seam. A test points the whole controller at a temporary
## directory, so the suites never write into the production save tree
## and never touch the developer's meta profile.
var save_repository: Object = null
var meta_writer: Object = null
## The one-shot latch of the battle outcome. See `_on_battle_ended`.
var _battle_outcome_applied: bool = false
## H-05: the outcome was applied to the live state, but its
## checkpoint did NOT land. The live state already holds the applied
## outcome, so the retry only has to WRITE it -- it must never
## re-apply it.
var _outcome_pending_persist: bool = false
## H-05: the retry is rate limited, so a persistent filesystem failure
## does not turn into a write on every frame. The value is the
## timestamp of the last attempt in milliseconds.
var _outcome_retry_after_ms: int = 0
## H-05: the minimum interval between two persistence retries.
const OUTCOME_RETRY_INTERVAL_MS: int = 1000
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
	# RI-07: the transient runtime belongs to the run, so a new run
	# starts from a clean one. The map is the important case: it is
	# created LAZILY in `_enter_map`, so a map that survived here
	# would make the new run continue in the middle of the old one.
	_reset_transient_runtime()
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


## The allowed phases of every public mutation command.
##
## RI-09: the matrix is the source of truth, and the guards are derived
## from it, so they cannot drift apart. See
## docs/ri09_command_phase_matrix.md for the rationale of every row.
##
## The board and the gold commands are only editable between the
## battles: the battle snapshot is taken from the board units in
## `start_battle`, and the participants are already captured, so a
## mutation during a battle would change the live state under the
## fight.
##
## The equipment commands are allowed in every live phase: the
## inventory is an overlay inside the battle scene and is reachable at
## any time, and the equipment bonuses are read ONCE, at the start of
## a battle, so equipping during a battle changes the NEXT battle.
const COMMAND_PHASES: Dictionary = {
	# The board: only between the battles.
	"board_to_bench": [Phase.PREP],
	"bench_to_board": [Phase.PREP],
	"swap_board_units": [Phase.PREP],
	"swap_units_by_id": [Phase.PREP],
	"board_to_bench_by_id": [Phase.PREP],
	"bench_to_board_by_id": [Phase.PREP],
	"move_to_board": [Phase.PREP],
	# The gold: only between the battles.
	"buy_unit": [Phase.PREP],
	"buy_item": [Phase.PREP],
	# The inventory, apart from the equipment: only between the
	# battles. Granting and removing an item changes what the next
	# battle starts with.
	#
	# The game's OWN reward delivery (the TREASURE node and the
	# combat drop) does NOT go through this command: it uses the
	# internal `_grant_reward_item`, which is not a command and has no
	# phase guard. The delivery happens in the MAP and the BATTLE
	# phase, where a command would be refused.
	"grant_item": [Phase.PREP],
	"remove_item_at": [Phase.PREP],
	# The index pair of the equipment commands carries the same rule
	# as the by-id pair: two commands that mean the same thing must
	# not have different phase sets.
	"equip_item_at": [Phase.PREP, Phase.BATTLE, Phase.REWARD,
		Phase.MAP, Phase.SERVICE],
	"unequip_item_at": [Phase.PREP, Phase.BATTLE, Phase.REWARD,
		Phase.MAP, Phase.SERVICE],
	# The equipment: in every live phase.
	"equip_item_by_id": [Phase.PREP, Phase.BATTLE, Phase.REWARD,
		Phase.MAP, Phase.SERVICE],
	"unequip_item_by_id": [Phase.PREP, Phase.BATTLE, Phase.REWARD,
		Phase.MAP, Phase.SERVICE],
}


## Whether the current phase may persist a checkpoint.
##
## H-09: the equipment commands are allowed in every live phase, but
## a checkpoint is only STABLE in the phases the v5 format can
## describe. The BATTLE phase is excluded on purpose: the v5 format
## does not persist the battle simulation runtime, and
## `wire_phase_for()` maps the BATTLE phase to PREP -- so a write
## during a battle would produce a checkpoint with a FALSE phase and
## a stale battle state.
##
## The GAMEOVER phase is excluded too: a finished run must not stay
## resumable.
func _phase_may_persist() -> bool:
	match phase:
		Phase.PREP, Phase.MAP, Phase.REWARD, Phase.SERVICE:
			return true
		_:
			return false


## Persists the equipment change, but only a REAL one.
##
## H-09: `RunDomainState.equip_item()` returns TRUE for an already
## equipped item WITHOUT changing anything, and
## `unequip_item()` returns the result of the reference purge. So
## "the operation returned true" is NOT "the state changed", and a
## naive save-after-return would write a redundant checkpoint on
## every idempotent repeat.
##
## The ownership BEFORE and AFTER the call is what decides.
func _persist_equipment_change(item_instance_id: String,
		owner_before: String) -> void:
	if state == null:
		return
	var item: RunItem = state.get_item(item_instance_id)
	var owner_after: String = "" if item == null else String(item.owner_unit_id)
	if owner_after == owner_before:
		# A no-op: the ownership did not change, so nothing is
		# persisted.
		return
	if not _phase_may_persist():
		# The BATTLE phase: the live inventory changes, but the
		# checkpoint waits for the next correct boundary.
		return
	save_now()


## Answers whether a command may run in the current phase.
##
## A refusal is logged and changes NOTHING: the guard is the FIRST
## statement of the command, so no gold, no inventory, no unit, no
## map/reward state, no RNG draw, no event and no checkpoint can be
## touched.
func _command_allowed(command: String) -> bool:
	var allowed: Variant = COMMAND_PHASES.get(command, null)
	if allowed == null:
		# An unknown command is refused: the matrix is the contract,
		# and a command that is not in it has no allowed phase.
		GameLog.error("run", "the command is not in the phase matrix",
			{"command": command})
		return false
	var phases: Array = allowed as Array
	if phases.has(phase):
		return true
	GameLog.warn("run", "the command is not allowed in this phase",
		{"command": command, "phase": phase})
	return false


## Покупает юнита из слота магазина и ставит на скамейку (bench).
## Возвращает купленный UnitDef или null.
func buy_unit(slot: int) -> Resource:
	if not _command_allowed("buy_unit"):
		return null
	var def: Resource = shop.offer_at(slot)
	if def == null:
		return null
	if state.gold < def.cost:
		GameLog.debug("run", "Not enough gold", {"need": def.cost, "have": state.gold})
		return null
	# RI-10: the bench has a capacity. The check is BEFORE any
	# mutation, so a refused purchase changes nothing: the gold stays,
	# no unit is created and the offer is not taken.
	if state.get_bench_units().size() >= BalanceScript.MAX_BENCH_UNITS:
		GameLog.warn("run", "Bought unit: the bench is full",
			{"size": state.get_bench_units().size(),
			"max": BalanceScript.MAX_BENCH_UNITS})
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
	if not _command_allowed("board_to_bench"):
		return false
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
	if not _command_allowed("bench_to_board"):
		return false
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
	if not _command_allowed("swap_board_units"):
		return false
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
	if not _command_allowed("swap_units_by_id"):
		return false
	if src_id == "" or dst_id == "" or src_id == dst_id:
		return false
	return state.swap_units(src_id, dst_id)


## Move a RunUnit to the bench by `instance_id`. Returns false if
## the unit does not exist or the bench is full.
func board_to_bench_by_id(src_id: String) -> bool:
	if not _command_allowed("board_to_bench_by_id"):
		return false
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
	if not _command_allowed("bench_to_board_by_id"):
		return false
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
	if not _command_allowed("equip_item_by_id"):
		return false
	if item_instance_id == "" or target_unit_instance_id == "":
		return false
	var item: RunItem = state.get_item(item_instance_id)
	if item == null or ContentDB_static.get_by_id_for_type("items", item.definition_id) == null:
		return false
	var owner_before: String = String(item.owner_unit_id)
	var ok: bool = state.equip_item(item_instance_id, target_unit_instance_id)
	if ok:
		# H-09: the equipment change is persisted, but only a REAL
		# one and only in a phase the checkpoint can describe.
		_persist_equipment_change(item_instance_id, owner_before)
	return ok


## Unequip a RunItem by `instance_id`. The item lands in
## inventory (owner_unit_id becomes "").
func unequip_item_by_id(item_instance_id: String) -> bool:
	if not _command_allowed("unequip_item_by_id"):
		return false
	if item_instance_id == "":
		return false
	var item: RunItem = state.get_item(item_instance_id)
	if item == null:
		return false
	var owner_before: String = String(item.owner_unit_id)
	var ok: bool = state.unequip_item(item_instance_id)
	if ok:
		# H-09: the equipment change is persisted, but only a REAL
		# one and only in a phase the checkpoint can describe.
		_persist_equipment_change(item_instance_id, owner_before)
	return ok


## Перемещает юнита со скамейки на доску (cell).
## v1 — упрощённо, без валидации cell.
func move_to_board(bench_index: int, _cell: Vector2i) -> bool:
	if not _command_allowed("move_to_board"):
		return false
	return bench_to_board(bench_index, -1)


# === S7.1: Inventory ===

## Добавляет предмет в инвентарь. Создаёт новый RunItem с
## stable instance_id. Capacity rule is total item count
## (inventory + equipped), matching legacy semantics.
## Возвращает true если успешно. Если уже MAX_INVENTORY предметов, returns false.
func grant_item(item_id: StringName) -> bool:
	if not _command_allowed("grant_item"):
		return false
	if item_id == &"":
		GameLog.warn("inventory", "grant_item: empty id")
		return false
	# The content check and the null check are the inventory contract;
	# the internal helper carries them, because the reward delivery
	# goes through it.
	return _grant_reward_item(item_id)


## Удаляет предмет по индексу (compatibility coordinate).
## index 0..state.items.size()-1 covers BOTH inventory and
## equipped items, matching legacy item_ids.
## Возвращает true если успешно.
func remove_item_at(idx: int) -> bool:
	if not _command_allowed("remove_item_at"):
		return false
	if idx < 0 or idx >= state.items.size():
		return false
	var removed_id: String = state.items[idx].instance_id
	var ok: bool = state.remove_item(removed_id)
	if ok:
		GameLog.info("inventory", "item removed",
			{"id": removed_id, "idx": idx, "size": state.items.size()})
	return ok


## Removes an item EVEN WHEN the live inventory is inconsistent.
##
## The repair path: the whole item subsystem fails closed when the
## live gate is false, so a removal that refuses too would lock the
## player out of their own inventory with no way out. It is NOT a
## phase-guarded command: it repairs a broken state, so it must work
## in any phase.
func remove_item_force_at(idx: int) -> bool:
	if idx < 0 or idx >= state.items.size():
		return false
	var removed_id: String = state.items[idx].instance_id
	var ok: bool = state.remove_item_force(removed_id)
	if ok:
		GameLog.warn("inventory", "item removed from an inconsistent inventory",
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
	if not _command_allowed("equip_item_at"):
		return false
	if item_idx < 0 or item_idx >= state.items.size():
		return false
	var board := state.get_board_units()
	if board_idx < 0 or board_idx >= board.size():
		return false
	var item: RunItem = state.items[item_idx]
	var target: RunUnit = board[board_idx]
	return equip_item_by_id(item.instance_id, target.instance_id)


## Снимает предмет с юнита (возвращает в инвентарь).
func unequip_item_at(item_idx: int) -> bool:
	if not _command_allowed("unequip_item_at"):
		return false
	if item_idx < 0 or item_idx >= state.items.size():
		return false
	var item: RunItem = state.items[item_idx]
	# H-09: the index pair routes through the by-id path, so it gets
	# the same persistence contract. Two commands that mean the same
	# thing must not behave differently.
	return unequip_item_by_id(item.instance_id)


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
	if not _command_allowed("buy_item"):
		return false
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
	# H-06: the purchase is persisted. The write happens AFTER the
	# mutation, so a failed write leaves a STALE checkpoint with the
	# PRE-purchase state: the item is not duplicated and the gold is
	# not charged twice.
	save_now()
	GameLog.info("run", "Shop buy",
		{"id": id, "price": price, "gold_left": state.gold})
	return true


## S7.4: выходит из shop/MERCHANT в MAP phase (используется shop_scene Close).
func exit_shop_to_map() -> void:
	# H-06: the exit requires a REAL merchant context. The phase
	# alone is not enough: without the merchant flag the exit was
	# reachable from an ordinary PREP, which is not a shop.
	if phase != Phase.PREP:
		return
	if state == null or not state.just_visited_merchant:
		GameLog.warn("run", "the shop exit needs a real merchant context")
		return
	state.just_visited_merchant = false
	_set_phase(Phase.MAP)
	# H-06: the exit is persisted, so the merchant context does not
	# survive a Continue.
	save_now()


## Empties the legacy reaction registry at a battle boundary.
##
## The registry lives in the ReactionSystem autoload (process-lifetime
## state). Clearing it here means a new battle never inherits the
## previous battle's registrations.
##
## It is static so the regression suite can drive the same path.
static func _clear_legacy_reaction_registry() -> void:
	var tree = Engine.get_main_loop()
	if tree == null:
		return
	var sys = tree.root.get_node_or_null("ReactionSystem")
	if sys == null:
		return
	if sys.has_method("clear_all"):
		sys.call("clear_all")


## Registers the LEGACY Shield Block view for a combatant.
##
## This is the production registration path for the legacy combat
## system. It is static so the regression suite can exercise the
## REAL path (including the ownership decision) without booting a
## whole run.
##
## Ownership: only the Paladin and the Guardian carry Shield Block.
static func _register_legacy_shield_block(p_combatant, p_unit_id: StringName) -> void:
	if p_combatant == null:
		return
	if not (p_unit_id in [&"paladin", &"guardian"]):
		return
	var view = _make_legacy_shield_block_view()
	if view == null:
		return
	GameBus.emit_reaction_registered(p_combatant, view)


## Builds the LEGACY view of the Shield Block reaction.
##
## The shipping resource is the Phase-3 view (trigger = &"",
## DAMAGE_STARTED + MODIFY_PENDING_DAMAGE). The legacy combat
## system polls &"unit_attacked" and matches the trigger EXACTLY,
## so it needs a view that declares that trigger.
##
## The view is a runtime duplicate of the shipping resource:
##   - trigger_chance is inherited (30% stays a single source of
##     truth — the shipping resource),
##   - the id is the legacy id, so the Phase-3 provider (which only
##     sees the reaction ids owned by a unit) never sees it,
##   - the Phase-3 event/effect fields are cleared, because the
##     legacy runtime does not use them and a legacy reaction must
##     never be mistaken for an executable Phase-3 reaction.
##
## Returns null when the shipping resource is unavailable.
##
## Static so the legacy view can be inspected directly by the
## regression suite without booting a whole run.
static func _make_legacy_shield_block_view() -> Resource:
	var shipping: Resource = ContentDB_static.get_by_id(&"shield_block")
	if shipping == null:
		return null
	var view = ReactionDefScript.new()
	view.id = LEGACY_SHIELD_BLOCK_ID
	view.display_name = String(shipping.get("display_name"))
	view.description = String(shipping.get("description"))
	view.trigger = LEGACY_SHIELD_BLOCK_TRIGGER
	view.trigger_chance = float(shipping.get("trigger_chance"))
	view.output_tag = StringName(shipping.get("output_tag"))
	# The legacy runtime drives the effect itself, so the Phase-3
	# executable fields stay inert.
	view.event_type = -1
	view.effect_kind = -1
	return view


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
	# BATTLE BOUNDARY: the legacy reaction registry is process-lifetime
	# state, so it must be emptied before THIS battle registers its
	# own reactions.
	#
	# The clear happens at the START boundary rather than only at the
	# end, because the previous battle may have ended abnormally (the
	# runtime was interrupted, the scene was torn down) and a new
	# battle must always begin from a clean registry.
	#
	# Clearing the WHOLE registry is required: it is keyed by def_id,
	# so unregistering one combatant would also drop the reaction of
	# every other living combatant of the same class, and a class
	# that owned a reaction in the previous battle would otherwise
	# inherit it here even when this battle has no such unit.
	_clear_legacy_reaction_registry()
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
		#
		# The LEGACY combat system (BattleRunner ->
		# ReactionSystem.poll_reaction) selects a reaction by an
		# EXACT trigger name match. The legacy chain polls
		# &"unit_attacked".
		#
		# The shipping resource content/reactions/shield_block.tres
		# is the PHASE-3 view: trigger = &"", event_type =
		# DAMAGE_STARTED, effect_kind = MODIFY_PENDING_DAMAGE. It
		# declares no legacy trigger on purpose, so the legacy
		# runtime can never select it.
		#
		# The legacy chain therefore needs its own VIEW of the same
		# reaction. The view is built at runtime from the shipping
		# resource with a legacy trigger and a legacy id:
		#
		#   - the chance stays 30% (single source of truth: the
		#     shipping resource; the legacy view never invents its
		#     own chance),
		#   - the id becomes &"shield_block_legacy" so the Phase-3
		#     provider (which only sees the reaction ids owned by
		#     the unit) and the legacy runtime never meet.
		#
		# The legacy DamageEffect recognises the reaction by its
		# id, so the legacy view keeps a distinct id and the
		# consumer check is taught to accept it.
		if def.id in [&"paladin", &"guardian"]:
			_register_legacy_shield_block(c, def.id)
	# Расставляем врагов (1 волна для v1: 1-3 врага).
	var wave: Array = _spawn_enemy_wave(state.round_index)
	for i in wave.size():
		var def: Resource = wave[i]
		if def == null:
			continue
		var c = CombatantScript.new(def)
		var cell: Vector2i = Vector2i(i, 0)
		ctx.register(c, cell)
		# Attack of Opportunity is NOT registered with the legacy
		# reaction system.
		#
		# The shipping resource content/reactions/
		# attack_of_opportunity.tres is the PHASE-3 view: trigger =
		# &"", event_type = UNIT_MOVE_STARTED, effect_kind =
		# PERFORM_ATTACK. The legacy chain polls reactions by an
		# EXACT trigger name, and across the whole project history the
		# only legacy poll was &"unit_attacked" in DamageEffect.
		# &"unit_move_start" was emitted but never polled, so a legacy
		# AoO was never executable.
		#
		# Registering it here therefore put a reaction in the legacy
		# registry that no legacy code could ever consume — a zombie
		# registration. The Phase-3 provider discovers AoO from the
		# unit's own reaction_ids instead, which is the only path
		# that actually executes it.
	runner = BattleRunnerScript.new(ctx)
	runner.start()
	# A new battle may produce a new outcome.
	_battle_outcome_applied = false
	# H-05: a fresh battle has no pending outcome, and a fresh run
	# has no stale pending persistence.
	_outcome_pending_persist = false
	_outcome_retry_after_ms = 0
	_set_phase(Phase.BATTLE)
	GameBus.emit_round_started(state.round_index)
	return true


## Тикает бой. Вызывай из сцены каждый кадр с учётом speed.
func tick_battle(dt: float) -> void:
	# H-05: the pending outcome is recovered by the ORDINARY game
	# loop, so the retry is REACHABLE and not a dead method without a
	# caller. It is rate limited, so a persistent filesystem failure
	# does not become a write on every frame.
	_retry_pending_outcome_persistence()
	if runner == null:
		return
	runner.step(dt)
	if runner.state.phase == BattleStateScript.Phase.ENDED:
		_on_battle_ended()


## Whether the outcome was applied but its checkpoint did not land.
##
## H-05: the third state of the outcome contract:
##
##   OUTCOME_NOT_APPLIED
##   OUTCOME_APPLIED_PENDING_PERSIST
##   OUTCOME_PERSISTED
func outcome_persistence_pending() -> bool:
	return _outcome_pending_persist


## Retries the persistence of an ALREADY applied outcome.
##
## The retry writes the CURRENT live state, which already holds the
## applied outcome. It therefore CANNOT re-apply anything: no second
## win counter, no second gold, no second round advance, no second
## loot, no second reward offer, no extra gameplay RNG draw and no
## repeated gameplay event.
##
## Returns true when there was pending work and it landed.
func retry_outcome_persistence() -> bool:
	if not _outcome_pending_persist:
		return false
	var report: RefCounted = save_now_report()
	if not bool(report.checkpoint_committed):
		_outcome_retry_after_ms = Time.get_ticks_msec() + OUTCOME_RETRY_INTERVAL_MS
		GameLog.error("run", "the outcome persistence retry failed",
			{"seed": state.seed})
		return false
	_outcome_pending_persist = false
	_outcome_retry_after_ms = 0
	GameLog.info("run", "the outcome persistence retry landed",
		{"seed": state.seed})
	return true


## The internal retry, driven by the tick and RATE LIMITED.
func _retry_pending_outcome_persistence() -> void:
	if not _outcome_pending_persist:
		return
	var now: int = Time.get_ticks_msec()
	if now < _outcome_retry_after_ms:
		return
	_outcome_retry_after_ms = now + OUTCOME_RETRY_INTERVAL_MS
	retry_outcome_persistence()


## Applies the outcome of the finished battle and writes the
## checkpoint.
##
## RI-05: the outcome is a TRANSACTION.
##
## The outcome used to be applied AFTER `save_now()`, so the checkpoint
## on the disk was the PRE-outcome state of a battle that had already
## been fought: a crash between the write and the apply lost the win
## bonus, the round advance, the combat drop and the reward offer, and
## the battle would be replayed. The loss branch never wrote at all,
## so the on-disk state stayed pre-battle.
##
## The transaction is now: apply the outcome, then write it. The disk
## therefore holds the POST-outcome state of a completed battle.
##
## The application is IDEMPOTENT. The scene ticks the battle every
## frame and calls this whenever the runner reports ENDED; nothing
## consumed that state, so the outcome could be applied twice: a
## second win bonus, a second combat drop, a second reward offer and a
## second round advance. The guard consumes the ENDED state, so the
## second call is a no-op.
func _on_battle_ended() -> void:
	# Phase 1 / T3F.5: do NOT introduce new post-battle HP writeback.
	# Legacy semantics did not persist combat runtime HP back into
	# run state, and that contract is preserved.
	if runner == null:
		return
	# IDEMPOTENCE: the outcome is applied exactly once.
	#
	# The scene ticks the battle every frame and calls this whenever
	# the runner reports ENDED, so without the guard the outcome would
	# be applied again on the very next frame: a second win bonus, a
	# second combat drop, a second reward offer and a second round
	# advance.
	#
	# The latch is a one-shot, not a state check. A state check would
	# only hold as long as nothing set the phase back to ENDED; the
	# latch removes the whole class of the defect. It lives in the
	# controller because the runner is replaced by every new battle.
	if _battle_outcome_applied:
		return
	runner.state.phase = BattleStateScript.Phase.APPLIED
	var winner: int = runner.state.winner_team
	# Clear battle lifetime bridge BEFORE the outcome is applied: the
	# participants belong to the finished battle.
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
		# S6.1: после каждой победы (включая round 1) показываем REWARD.
		# Затем _enter_prep_or_map_after_reward() маршрутизирует:
		# round 1 → PREP (стартовый набор уже на доске).
		# round 2..MAX_ROUND-1 → MAP (игрок выбирает следующий нод).
		#
		# The offer is generated BEFORE the write: the offer IS part of
		# the outcome, so it must be in the SAME checkpoint as the
		# counters. Writing it later left a window in which the disk
		# held the outcome but no offer, and the resumed run could not
		# reach the reward at all.
		# S3.1: победа над боссом завершает ран.
		#
		# RI-08: the completion is the BOSS, not the count of the won
		# battles. The round grows by one per won battle, while the map
		# has 10 layers with 2..4 nodes each, so the count could run
		# out on the EARLY layers: the run ended on round 11 with the
		# boss never fought.
		#
		# The end of the run is decided BEFORE the write: a finished
		# run must NOT write a checkpoint, not even to delete it right
		# afterwards. Writing it first left a window in which a
		# finished run was resumable, and the window was not tight: it
		# spanned the reward emission and the meta-unlock draws.
		if _is_boss_encounter(state.current_encounter_id):
			_end_run(true)
			return
		_enter_reward_offer()
		_set_phase(Phase.REWARD)
		# The TRANSACTION: the outcome, the offer and the stream
		# position are on the disk in ONE write.
		_write_outcome()
		GameBus.emit_reward_offered(reward.offered_ids())
	elif winner == 1:
		state.losses += 1
		state.lives -= 1
		if state.lives <= 0:
			# The run is over: the checkpoint of a finished run must not
			# stay resumable, so it is removed instead of written.
			_end_run(false)
			return
		state.round_index += 1
		_set_phase(Phase.PREP)
		# The shop refresh draws from the run stream, so it happens
		# BEFORE the write: the checkpoint then carries the CURRENT
		# offer and the CURRENT stream position, and the resumed run
		# continues the same stream.
		_refresh_shop()
		# The TRANSACTION: the outcome is on the disk in ONE write.
		_write_outcome()
	else:
		# A neutral outcome ends the run too, and it is not counted as
		# a loss. The run file is removed with the run.
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
	# The run file is removed: the run is over, and a resumable
	# checkpoint at a finished round would let it be continued past
	# MAX_ROUND.
	_delete_run_file()
	_save_meta(profile)
	run_ended.emit(won)
	GameLog.info("run", "Run ended", {"round": state.round_index, "won": won})


## The save seam.
##
## Without an injected repository the production service is used; a
## test injects a repository over a temporary directory, so the suites
## never write into `user://saves`.
func _save_run_v5(seed_value: int, dto: Dictionary) -> RefCounted:
	if save_repository == null:
		return SaveService.save_run_v5(seed_value, dto)
	return SaveService._save_run_v5_with_repository(seed_value, dto, save_repository)


## The load seam. See `_save_run_v5`.
func _load_run_v5(seed_value: int) -> RefCounted:
	if save_repository == null:
		return SaveService.load_run_v5(seed_value)
	return SaveService._load_run_v5_with_repository(seed_value, save_repository)


## The meta seam. See `_save_run_v5`.
func _save_meta(meta_profile: MetaProfile) -> bool:
	if meta_writer != null and meta_writer.has_method("write_meta"):
		return bool(meta_writer.write_meta(meta_profile))
	return SaveService.save_meta(meta_profile)


# === S3.3: Save/Load в середине рана ===

## Сохраняет текущий state + обновляет profile.current_run_seed.
## Phase 1 / T3F.6: live state is RunDomainState. We map to a
## canonical v4 DTO via RunStateV4Mapper, hand it to
## SaveService.save_run_v4 (which routes through the hardened
## RunSaveRepository + file ops seam), and inspect the returned
## SaveLoadResult. On failure: do not update profile.current_run_seed
## (the meta would otherwise lie about an active run that did not
## actually persist).
## The stable wire name of the current checkpoint phase.
##
## The runtime has no MERCHANT phase: a merchant visit is the PREP
## phase with the `just_visited_merchant` flag set. The wire contract
## keeps the two apart.
func checkpoint_phase_wire() -> String:
	return SaveSchemaV5Script.wire_phase_for(phase, state.just_visited_merchant)


## Builds the canonical v5 checkpoint DTO of the CURRENT runtime.
##
## Every subsystem publishes its own snapshot, so the mapper never
## reaches into a private field.
func build_checkpoint_dto() -> Dictionary:
	var map_snapshot: Dictionary = {}
	if encounter_map != null and encounter_map.has_method("snapshot"):
		map_snapshot = encounter_map.snapshot()
	return RunCheckpointV5MapperScript.to_v5_dto(
		state,
		checkpoint_phase_wire(),
		shop.snapshot(),
		merchant_shop.snapshot(),
		map_snapshot,
		reward.snapshot(),
		RngServiceScript.snapshot())


func save_now() -> bool:
	# The boolean contract is kept for the existing callers: a COMPLETE
	# success. A partial success (the checkpoint landed, the meta
	# pointer did not) is NOT a complete success, so it is reported as
	# false -- and the checkpoint itself stays valid on the disk.
	#
	# H-08: the outcome latch is bound to the CHECKPOINT, not to this
	# boolean, so a meta failure can never make the outcome
	# reapplicable. See `_write_outcome`.
	return save_now_report().is_complete()


## The structured result of a checkpoint attempt.
##
## H-08: the checkpoint commit and the meta pointer commit are TWO
## separate writes, so they are reported separately:
##
##   checkpoint success + meta success -> complete success
##   checkpoint success + meta failure -> a PARTIAL success: the
##                                      checkpoint stays VALID, the
##                                      status reports the partial
##                                      failure, no false run_saved
##                                      success is emitted, and only
##                                      the META publication is
##                                      retried
##   checkpoint failure               -> no claim of a persisted
##                                      checkpoint
func save_now_report() -> RefCounted:
	if state == null or state.seed == 0:
		GameLog.warn("run", "save_now: no active state")
		return RunSaveReportScript.failed(0, 0, "no active state")
	var dto: Dictionary = build_checkpoint_dto()
	if dto.is_empty():
		GameLog.error("run", "save_now: the checkpoint DTO is empty")
		return RunSaveReportScript.failed(state.seed, 0, "the checkpoint DTO is empty")
	var result: RefCounted = _save_run_v5(state.seed, dto)
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
		return RunSaveReportScript.failed(state.seed, 0, "the checkpoint write failed")
	# The CHECKPOINT landed. The meta pointer is a SECOND, separate
	# write.
	if profile != null:
		profile.current_run_seed = state.seed
		if not _save_meta(profile):
			# The checkpoint is valid and stays on the disk, but the
			# pointer that makes Continue discoverable was not
			# published. This is a PARTIAL success, NOT a complete
			# one: no `run_saved` is emitted, because the caller would
			# believe the run is discoverable.
			GameLog.error("run",
				"the checkpoint landed but the meta pointer did not: a partial success",
				{"seed": state.seed})
			return RunSaveReportScript.checkpoint_only(state.seed, 0,
				"the meta pointer write failed")
		GameBus.emit_run_saved(state.seed)
	GameLog.info("run", "Run saved", {"seed": state.seed, "round": state.round_index})
	return RunSaveReportScript.complete(state.seed)


## Retries ONLY the meta publication.
##
## H-08: the meta pointer is a separate write from the checkpoint, so
## it gets its own retry. The retry writes ONLY the meta: it never
## replays the gameplay outcome, never touches the checkpoint and never
## draws from the gameplay RNG.
func retry_meta_publication() -> bool:
	if profile == null or state == null:
		return false
	profile.current_run_seed = state.seed
	if not _save_meta(profile):
		GameLog.error("run", "the meta publication retry failed",
			{"seed": state.seed})
		return false
	GameBus.emit_run_saved(state.seed)
	GameLog.info("run", "Run meta published",
		{"seed": state.seed, "round": state.round_index})
	return true


## The checkpoints that are on the disk and can be recovered.
##
## H-08: when the meta pointer is stale or zero, the committed
## checkpoint must still be DISCOVERABLE, so the Continue path can
## find it.
##
## The controller does NOT choose one of the candidates silently: the
## list is returned, and the caller decides. The active run is never
## switched by this call.
func recoverable_checkpoints() -> Array[int]:
	var seeds: Array[int] = []
	if save_repository != null and save_repository.has_method("list_saved_seeds"):
		var listed: Variant = save_repository.list_saved_seeds()
		if listed is Array:
			for s in listed:
				seeds.append(int(s))
		return seeds
	# The production path: the service lists the run files.
	var listed_service: Variant = SaveService.list_runs()
	if listed_service is Array:
		for s in listed_service:
			seeds.append(int(s))
	return seeds


## S3.3: сбрасывает active run marker. Вызывается при _end_run.
func _clear_active_run() -> void:
	if profile != null and profile.current_run_seed != 0:
		profile.current_run_seed = 0
		# meta save уже вызывается в _end_run — здесь не дублируем.


## Removes the run file of the finished run.
##
## The run is over: there is nothing to continue. A checkpoint that
## stayed on the disk would be resumable, and the run could be
## continued past MAX_ROUND.
func _delete_run_file() -> void:
	if state == null:
		return
	var removed: bool = false
	if save_repository != null:
		removed = SaveService._delete_run_with_repository(
			state.seed, save_repository)
	else:
		removed = SaveService.delete_run(state.seed)
	if not removed:
		# A finished run that stays on the disk is resumable, so the
		# failure must be visible.
		GameLog.error("run", "the finished run file was not removed",
			{"seed": state.seed})

## Writes the checkpoint of the applied outcome.
##
## The idempotence latch is consumed ONLY when the checkpoint landed.
## A failed write leaves the outcome applied in memory and still
## persistable: the latch would otherwise make the outcome
## unrecoverable, because every later attempt would return early.
func _write_outcome() -> bool:
	# H-08: the latch is bound to the CHECKPOINT commit, NOT to the
	# complete success. The checkpoint and the meta pointer are two
	# separate writes: if the checkpoint landed and the meta pointer
	# failed, the outcome IS persisted and the latch MUST be
	# consumed. Binding the latch to the complete success would make
	# the outcome reapplicable -- and a second application repeats the
	# win counter, the gold, the round, the loot and the reward offer.
	var report: RefCounted = save_now_report()
	var written: bool = bool(report.checkpoint_committed)
	if written:
		_battle_outcome_applied = true
		_outcome_pending_persist = false
	else:
		# H-05: the outcome IS applied to the live state -- the win
		# counter, the gold, the round, the loot and the offer are
		# already there. Only the WRITE failed, so the outcome is
		# PENDING, not lost and not reapplicable.
		_outcome_pending_persist = true
		_outcome_retry_after_ms = 0
		GameLog.error("run", "the outcome checkpoint failed to write",
			{"seed": state.seed})
	return written

## Resets the transient runtime of a finished or abandoned run.
##
## RI-07: the map, the reward offer, the battle runtime and the
## participant bridge belong to the RUN, not to the controller. A new
## run must start from a clean runtime: the map is created lazily, so
## a map that survived would make the new run continue in the middle
## of the old one, and the reward offer would be the one that was
## generated for the previous run.
func _reset_transient_runtime() -> void:
	encounter_map = null
	reward.reset_offer()
	# The merchant offer is run-scoped as well: it is generated by the
	# MERCHANT effect, snapshotted into the checkpoint and restored on
	# resume. Left behind, it leaked into the new run and into its
	# checkpoint, and it broke the determinism of the checkpoint for a
	# fixed seed.
	merchant_shop.reset_offer()
	# H-02: the merchant discount is run-scoped as well. The v5
	# checkpoint persists it, so a resumed run installs a non-default
	# one; without this reset the next independent run inherited it and
	# priced its merchant items with the previous run's discount.
	merchant_shop.reset_discount()
	runner = null
	ctx = null
	_battle_participants = null
	_battle_outcome_applied = false
	# H-05: a fresh battle has no pending outcome, and a fresh run
	# has no stale pending persistence.
	_outcome_pending_persist = false
	_outcome_retry_after_ms = 0

## Grants an item to the run.
##
## This is the INTERNAL grant: the game's own reward delivery (the
## TREASURE node and the post-victory combat drop) goes through it, and
## it is not a player command, so it has no phase guard.
##
## The player-facing `grant_item` is a COMMAND: it is PREP-only, so a
## caller cannot hand out items from anywhere else. The two are kept
## apart deliberately: the reward delivery happens in MAP and in
## BATTLE, where the command would be refused.
##
## The check of the inventory capacity is shared, so both paths obey
## it.
func _grant_reward_item(item_id: StringName) -> bool:
	if item_id == &"":
		return false
	if state.items.size() >= BalanceScript.MAX_INVENTORY:
		GameLog.warn("inventory", "grant_item: inventory full",
			{"size": state.items.size(), "max": BalanceScript.MAX_INVENTORY})
		return false
	# The content boundary: an item with no definition is not granted.
	if ContentDB_static.get_by_id_for_type("items", item_id) == null:
		return false
	# `create_item` returns null for an inconsistent inventory or an
	# exhausted cursor, and the inventory contract makes that a
	# refusal: a silent success there would be a lie.
	if state.create_item(item_id) == null:
		GameLog.warn("inventory", "grant_item: the item was not created",
			{"id": item_id})
		return false
	GameLog.info("inventory", "item granted",
		{"id": item_id, "size": state.items.size()})
	return true

## Whether the given encounter node was the boss.
##
## RI-08: the run is terminated by the BOSS, so the completion must
## know whether the fight it just won was the final one.
func _is_boss_encounter(node_id: int) -> bool:
	if encounter_map == null:
		return false
	var node = encounter_map.get_node(node_id)
	if node == null:
		return false
	return node.type == EncounterTypeScript.Kind.BOSS

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
	# The runtime is NOT touched until every piece of the checkpoint
	# has been loaded AND validated. If any step fails, the live
	# runtime stays exactly as it was, the save stays unchanged, and
	# no replacement run is started.
	var result: RefCounted = _load_run_v5(seed_value)
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

	# A v4 file carries no checkpoint layers. It is migrated with the
	# documented conservative fallback, and the migration is reported.
	var migrated: bool = false
	if int(dto.get("schema_version", 0)) != SaveSchemaV5Script.SCHEMA_VERSION:
		var mig: Dictionary = RunCheckpointV5MapperScript.migrate_v4_to_v5(dto)
		if not bool(mig.get("ok", false)):
			GameLog.error("run", "resume_run: the v4 migration failed",
				{"seed": seed_value})
			return false
		dto = mig.get("dto", {}) as Dictionary
		migrated = true
		for note in mig.get("diagnostics", []):
			GameLog.warn("save", "resume_run migration", {"note": str(note)})

	var decoded: Dictionary = RunCheckpointV5MapperScript.from_v5_dto(dto)
	if not bool(decoded.get("ok", false)):
		GameLog.error("run", "resume_run: the checkpoint could not be decoded",
			{"seed": seed_value, "reason": str(decoded.get("reason", ""))})
		return false

	# ---- construct the temporary runtime -------------------------------
	var loaded_state = decoded.get("state")
	if loaded_state == null:
		GameLog.error("run", "resume_run: the domain state is missing")
		return false

	# The subsystems are restored into TEMPORARY objects first: a bad
	# snapshot must not leave the live runtime half-restored.
	var new_shop: Shop = Shop.new()
	if not new_shop.restore_snapshot(decoded.get("unit_shop", {}) as Dictionary):
		GameLog.error("run", "resume_run: the unit-shop snapshot is invalid")
		return false
	var new_merchant: ShopScreen = ShopScreenScript.new()
	if not new_merchant.restore_snapshot(decoded.get("merchant", {}) as Dictionary):
		GameLog.error("run", "resume_run: the merchant snapshot is invalid")
		return false
	var new_reward: RewardScreen = RewardScreen.new()
	if not new_reward.restore_snapshot(decoded.get("reward", {}) as Dictionary):
		GameLog.error("run", "resume_run: the reward snapshot is invalid")
		return false

	var map_snapshot: Dictionary = decoded.get("map", {}) as Dictionary
	var new_map: EncounterMap = null
	if not map_snapshot.is_empty():
		new_map = EncounterMapScript.new()
		if not new_map.restore_snapshot(map_snapshot):
			GameLog.error("run", "resume_run: the encounter-map snapshot is invalid")
			return false
	elif loaded_state.current_encounter_id != -1:
		# The checkpoint has no map snapshot but the domain state
		# references a node.
		#
		# A v5 checkpoint ALWAYS carries the map, so this can only be a
		# v4 file that was migrated: v4 never persisted the map. The
		# v4 map was generated from the run seed, so it is reproduced
		# EXACTLY, not invented: the same seed produces the same graph.
		# The generation happens on a scratch stream, and the run's
		# persisted RNG continuation is restored afterwards.
		if not migrated:
			GameLog.error("run", "resume_run: the map snapshot is missing",
				{"encounter_id": loaded_state.current_encounter_id})
			return false
		new_map = EncounterMapScript.new()
		var saved_rng: Dictionary = RngServiceScript.snapshot()
		RngServiceScript.seed_run(loaded_state.seed)
		new_map.generate(loaded_state.seed)
		new_map.start_run()
		# The walked path is NOT reproducible from the seed: the graph is,
		# but the nodes the run actually walked are not. The authoritative
		# list is the domain state's, so it is applied to the graph.
		new_map.mark_visited(loaded_state.encounter_visited_ids)
		if loaded_state.current_encounter_id != -1:
			new_map.goto_node(loaded_state.current_encounter_id)
		# The scratch generation must not consume the run's stream.
		var saved_seed: int = int(saved_rng.get("seed", 0))
		if saved_seed != 0:
			# The bookkeeping only: current_seed and _is_seeded.
			RngServiceScript.seed_run(saved_seed)
		# The machine state is ALWAYS restored: `restore` writes the
		# captured PRNG position, and it is exact for every seed,
		# including 0.
		RngServiceScript.restore(saved_rng)
		GameLog.warn("run", "resume_run: the map was reproduced from the seed",
			{"encounter_id": loaded_state.current_encounter_id})

	# ---- commit -------------------------------------------------------
	# Every piece validated. Now the live runtime is replaced.
	#
	# The RNG continuation is restored BEFORE the live runtime is
	# replaced, not after. The restore must not be observable: a
	# half-committed runtime that is observed with the OLD stream
	# would let a consumer draw from the wrong position. No shop
	# refresh, no merchant refresh, no reward generation and no map
	# generation happen between the restore and the commit either.
	var rng_snapshot: Dictionary = decoded.get("rng", {}) as Dictionary
	var rng_seed: int = int(rng_snapshot.get("seed", loaded_state.seed))
	if rng_seed != 0:
		# The bookkeeping only: current_seed and _is_seeded.
		RngServiceScript.seed_run(rng_seed)
	# The machine state is ALWAYS restored: `restore` writes the
	# captured PRNG position, and it is exact for every seed,
	# including 0.
	RngServiceScript.restore(rng_snapshot)

	# The BATTLE runtime is cleared before the new state is installed.
	#
	# The resume replaces the domain state, the shop, the merchant, the
	# reward and the map -- but it must also clear the battle
	# runtime. A stale runner survives otherwise: `tick_battle`
	# advances it unconditionally, and when it ENDS,
	# `_on_battle_ended()` applies the OLD battle's outcome to the NEW
	# state -- the round grows, the gold changes and the phase leaves
	# the resumed phase.
	_reset_transient_runtime()

	state = loaded_state
	shop = new_shop
	merchant_shop = new_merchant
	reward = new_reward
	encounter_map = new_map

	# The phase is restored from the stable wire name.
	var wire_phase: String = str(decoded.get("phase", SaveSchemaV5Script.PHASE_PREP))
	match wire_phase:
		SaveSchemaV5Script.PHASE_MAP:
			_set_phase(Phase.MAP)
		SaveSchemaV5Script.PHASE_REWARD:
			_set_phase(Phase.REWARD)
		SaveSchemaV5Script.PHASE_MERCHANT:
			state.just_visited_merchant = true
			_set_phase(Phase.PREP)
		_:
			_set_phase(Phase.PREP)

	if profile != null:
		profile.current_run_seed = state.seed
	# The meta seam, like everywhere else: a test that installs a
	# meta writer must not have the production profile written.
	_save_meta(profile)
	GameBus.emit_run_resumed(state.seed)
	GameLog.info("run", "Run resumed",
		{"seed": state.seed, "round": state.round_index,
			"phase": wire_phase, "migrated": migrated})
	return true


## S5.1.5: переход в фазу REWARD после победы (кроме round 1).
## Generates the reward offer for the finished round.
##
## The offer is generated WITHOUT a write: the caller writes it as
## part of the outcome transaction, so the offer and the counters are
## in ONE checkpoint. A second write here would leave a window in
## which the disk held the outcome but no offer.
func _enter_reward_offer() -> void:
	reward.generate_offer(state.round_index)
	GameLog.info("run", "Reward offered", {"round": state.round_index, "ids": reward.offered_ids()})


## Enters the reward phase and writes the checkpoint.
##
## Used by the flows that are NOT the battle outcome transaction.
func _enter_reward() -> void:
	_enter_reward_offer()
	_set_phase(Phase.REWARD)
	GameBus.emit_reward_offered(reward.offered_ids())
	# S3.3: auto-save после генерации offer.
	save_now()


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
	#
	# H-03: the save happens AFTER the transition, never before it.
	# The baseline saved while the phase was still MAP, so the
	# checkpoint described the MAP phase with the combat node already
	# selected -- and after Continue the player could select the NEXT
	# node and skip the battle.
	#
	# The service path persists ITS OWN authoritative checkpoint, after
	# the effect and after the final stable phase is known, so the
	# transaction is written ONCE and it describes a stable phase.
	if node.is_combat():
		_set_phase(Phase.PREP)
		# The TRANSACTION: the selected combat and the PREP phase are
		# on the disk in ONE write.
		save_now()
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
	#
	# H-03: the save comes AFTER the final phase is known, so the
	# checkpoint describes a STABLE phase and the transaction is
	# written ONCE. The baseline saved three times: before the effect,
	# inside the handler and after it -- an intermediate checkpoint
	# could describe a phase the run never rested in.
	if stay_in_current_phase:
		# The MERCHANT stays in PREP: the checkpoint describes the
		# merchant context.
		save_now()
		return
	if encounter_map == null:
		return
	var available: Array[int] = encounter_map.get_available_next_ids()
	if available.is_empty():
		# H-07: an empty successor list DOES NOT IMPLY that the boss
		# was defeated. A corrupted map whose service node has no
		# successors reaches this branch too, and ending the run here
		# produced a FALSE VICTORY: `run_ended(true)`, a total win, a
		# meta unlock and the DELETION of the checkpoint of a run that
		# was never won.
		#
		# The map knows the difference: `is_valid()` requires a boss
		# and rejects a dead end that is not the boss. A corrupted map
		# is a CONTROLLED FAILURE -- an explicit error, no victory, no
		# meta unlock, no checkpoint deletion -- and not a game loss
		# and not a game win.
		#
		# The legitimate case is untouched: the boss node has no
		# successors either, and the run still ends there -- but
		# through the BOSS path, where the outcome was confirmed.
		if not encounter_map.is_valid():
			GameLog.error("run",
				"the map has no successor and is not a valid map: the run is NOT a victory",
				{"seed": int(state.seed)})
			return
		# Нет следующих ходов: это конец карты, то есть победа над
		# боссом. Завершаем.
		_end_run(true)
		return
	_set_phase(Phase.MAP)
	# S5.4: atomic save AFTER the service effect and AFTER the final
	# phase is known — guarantees the save file contains the
	# post-effect state (including the rest_attack_bonus after REST
	# and the gold after TREASURE) in a stable phase.
	save_now()


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
		# The internal grant: the reward delivery happens in the MAP
		# phase, where the player-facing command is refused.
		item_granted = _grant_reward_item(item_id)
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
	# The internal grant: the combat drop happens in the BATTLE phase
	# (the outcome is applied before the phase changes), where the
	# player-facing command is refused.
	var ok: bool = _grant_reward_item(item_id)
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
