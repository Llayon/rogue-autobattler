class_name MetaProfile extends Resource
## Глобальный профиль игрока: разблокировки, статистика, настройки.
## Сохраняется отдельно от рана.

const SAVE_VERSION: int = 1

@export var version: int = SAVE_VERSION

# Разблокированные unit_def id.
@export var unlocked_units: Array[StringName] = [&"warrior", &"archer", &"goblin"]
@export var unlocked_enemies: Array[StringName] = [&"goblin"]

# Статистика за всё время.
@export var total_runs: int = 0
@export var total_wins: int = 0
@export var best_round: int = 0
@export var total_units_killed: int = 0

# Мета-валюта.
@export var soul_currency: int = 0

# S3.3: pointer на текущий активный ран. 0 = нет активного.
# Устанавливается при save_run, сбрасывается на _end_run.
# Один активный ран в момент времени — singleplayer roguelike pattern.
@export var current_run_seed: int = 0

# Настройки.
@export var battle_speed: float = 1.0   # 1.0 / 2.0 / 4.0
@export var show_damage_numbers: bool = true


func to_dict() -> Dictionary:
	return {
		"version": version,
		"unlocked_units": unlocked_units.duplicate(),
		"unlocked_enemies": unlocked_enemies.duplicate(),
		"total_runs": total_runs,
		"total_wins": total_wins,
		"best_round": best_round,
		"total_units_killed": total_units_killed,
		"soul_currency": soul_currency,
		"current_run_seed": current_run_seed,
		"battle_speed": battle_speed,
		"show_damage_numbers": show_damage_numbers,
	}