class_name Targeting extends RefCounted
## Тип таргетинга для способностей и эффектов.
##
## SINGLE_ENEMY  — одна цель противника.
## SINGLE_ALLY   — одна цель союзника.
## AOE_CIRCLE    — круг радиуса N от центра.
## AOE_LINE      — линия по горизонтали/вертикали.
## AOE_CONE      — конус.
## SELF          — кастер сам себе.
## RANDOM_ENEMY  — случайный противник (цель определяется резолвером).
## ALL_ENEMIES   — все противники.
## ALL_ALLIES    — все союзники (включая себя если уместно).

const SINGLE_ENEMY: int = 0
const SINGLE_ALLY: int = 1
const AOE_CIRCLE: int = 2
const AOE_LINE: int = 3
const AOE_CONE: int = 4
const SELF: int = 5
const RANDOM_ENEMY: int = 6
const ALL_ENEMIES: int = 7
const ALL_ALLIES: int = 8


static func requires_explicit_target(t: int) -> bool:
	return t == SINGLE_ENEMY or t == SINGLE_ALLY or t == AOE_CIRCLE or t == AOE_LINE or t == AOE_CONE


static func name_of(t: int) -> StringName:
	match t:
		SINGLE_ENEMY: return &"single_enemy"
		SINGLE_ALLY:  return &"single_ally"
		AOE_CIRCLE:   return &"aoe_circle"
		AOE_LINE:     return &"aoe_line"
		AOE_CONE:     return &"aoe_cone"
		SELF:         return &"self"
		RANDOM_ENEMY: return &"random_enemy"
		ALL_ENEMIES:  return &"all_enemies"
		ALL_ALLIES:   return &"all_allies"
		_:            return &"unknown"