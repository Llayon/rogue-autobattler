class_name EffectKind extends RefCounted
## Категории эффектов — для AI и UI-фильтрации.
## Сам алгоритм применения живёт в core/effects/.

const DAMAGE: int = 0
const HEAL: int = 1
const APPLY_STATUS: int = 2
const MOVE: int = 3
const SUMMON: int = 4
const SHIELD: int = 5
const DISPEL: int = 6
const REVIVE: int = 7
const CUSTOM: int = 99


static func name_of(k: int) -> StringName:
	match k:
		DAMAGE:        return &"damage"
		HEAL:          return &"heal"
		APPLY_STATUS:  return &"apply_status"
		MOVE:          return &"move"
		SUMMON:        return &"summon"
		SHIELD:        return &"shield"
		DISPEL:        return &"dispel"
		REVIVE:        return &"revive"
		_:             return &"custom"