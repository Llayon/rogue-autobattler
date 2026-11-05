class_name BattleState extends Resource
## Состояние боя. Ресурс — чтобы можно было сохранять/инспектировать.
##
## Хранит:
##   - фазу (PREP / BATTLE / ENDED / APPLIED),
##
## APPLIED means the outcome of the finished battle was applied to the
## run state and written: the battle is over AND its outcome is
## settled, so it must not be applied a second time.
##   - время боя,
##   - ссылку на активный BattleRunner (опционально).

enum Phase { PREP, BATTLE, ENDED, APPLIED }

const SAVE_VERSION: int = 1

@export var version: int = SAVE_VERSION
@export var phase: int = Phase.PREP
@export var battle_time: float = 0.0
@export var winner_team: int = -1  # -1 = не определён
@export var round_index: int = 1


func to_dict() -> Dictionary:
	return {
		"version": version,
		"phase": phase,
		"battle_time": battle_time,
		"winner_team": winner_team,
		"round_index": round_index,
	}