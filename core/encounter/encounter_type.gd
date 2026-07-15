class_name EncounterType extends RefCounted
## Типы энкаунтеров на карте. Каждый нод на карте — один из этих типов.
##
## Combat-типы: COMBAT, ELITE, BOSS (вызывают битву через BattleRunner).
## Service-типы: HEAL, TREASURE, MERCHANT, REST, SHRINE (дают ресурсы / выбор).
##
## Combat-типы определяются через is_combat() — для фильтрации в UI и логике.

enum Kind {
	COMBAT,    # обычный бой
	ELITE,     # сложный бой (бонус reward)
	HEAL,      # восстановление HP
	TREASURE,  # золото + reward unit
	MERCHANT,  # магазин со скидками
	REST,      # heal + upgrade
	SHRINE,    # random buff/choice
	BOSS,      # финальный бой (всегда слой 10)
}


## Возвращает true если этот kind — combat (бой с врагами).
static func is_combat(kind: int) -> bool:
	return kind == Kind.COMBAT or kind == Kind.ELITE or kind == Kind.BOSS


## Отображаемое имя для UI.
static func display_name(kind: int) -> String:
	match kind:
		Kind.COMBAT: return "Combat"
		Kind.ELITE: return "Elite"
		Kind.HEAL: return "Heal"
		Kind.TREASURE: return "Treasure"
		Kind.MERCHANT: return "Merchant"
		Kind.REST: return "Rest"
		Kind.SHRINE: return "Shrine"
		Kind.BOSS: return "Boss"
		_: return "Unknown"


## Короткое имя (1-2 символа) для иконок.
static func short_label(kind: int) -> String:
	match kind:
		Kind.COMBAT: return "C"
		Kind.ELITE: return "E"
		Kind.HEAL: return "H"
		Kind.TREASURE: return "T"
		Kind.MERCHANT: return "M"
		Kind.REST: return "R"
		Kind.SHRINE: return "S"
		Kind.BOSS: return "B"
		_: return "?"