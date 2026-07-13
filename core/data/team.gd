class_name Team extends RefCounted
## Сторона в бою. Простой enum-обёртка для читаемости кода.
##
## Использование:
##   var t: int = Team.PLAYER
##   if combatant.team == Team.ENEMY: ...

const PLAYER: int = 0
const ENEMY: int = 1
const NEUTRAL: int = 2


static func opposite(team: int) -> int:
	match team:
		PLAYER: return ENEMY
		ENEMY: return PLAYER
		_: return NEUTRAL


static func name_of(team: int) -> StringName:
	match team:
		PLAYER: return &"player"
		ENEMY:  return &"enemy"
		NEUTRAL:return &"neutral"
		_:      return &"unknown"