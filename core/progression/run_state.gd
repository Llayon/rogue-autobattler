class_name RunState extends Resource
## Состояние одного рана (прогон игрока от старта до смерти).
##
## Не включает состояние боя (BattleState) — это мета-обёртка:
## кто в команде, сколько золота, какой раунд, что в магазине.

const SAVE_VERSION: int = 3

@export var version: int = SAVE_VERSION
@export var seed: int = 0

@export var round_index: int = 1
@export var gold: int = 10
@export var xp: int = 0
@export var level: int = 1
@export var lives: int = 1   # сколько раз можно проиграть (по умолчанию 1 = стандартный рогалик)

# Юниты игрока (id'ы UnitDef, расставленные).
@export var player_unit_ids: Array[StringName] = []
# Юниты в "запасе" (bench).
@export var bench_unit_ids: Array[StringName] = []
# Предметы.
@export var item_ids: Array[StringName] = []

# Статистика рана.
@export var wins: int = 0
@export var losses: int = 0
@export var units_killed: int = 0

# S5.3: encounter map tracking.
# Текущий encounter id, где находится игрок (DAG state). -1 = карта не начата.
@export var current_encounter_id: int = -1
# История посещённых encounter id (для сохранения и визуальной подсветки).
@export var encounter_visited_ids: Array[int] = []

# Модификаторы мета-прогрессии на этот ран.
@export var meta_modifiers: Dictionary = {}

# S5.4: per-unit state (HP, bonus_attack). Параллелен player_unit_ids.
# Index в массиве соответствует index в player_unit_ids. Может быть короче,
# если юнит был перемещён в bench или убит.
@export var unit_states: Array = []  # Array[RunUnitState]


func to_dict() -> Dictionary:
	var unit_states_dicts: Array = []
	for us in unit_states:
		unit_states_dicts.append(us.to_dict())
	return {
		"version": version,
		"seed": seed,
		"round_index": round_index,
		"gold": gold,
		"xp": xp,
		"level": level,
		"lives": lives,
		"player_unit_ids": player_unit_ids.duplicate(),
		"bench_unit_ids": bench_unit_ids.duplicate(),
		"item_ids": item_ids.duplicate(),
		"wins": wins,
		"losses": losses,
		"units_killed": units_killed,
		"meta_modifiers": meta_modifiers.duplicate(),
		"current_encounter_id": current_encounter_id,
		"encounter_visited_ids": encounter_visited_ids.duplicate(),
		"unit_states": unit_states_dicts,
	}