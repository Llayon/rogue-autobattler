class_name UnitsMeta extends RefCounted
## Статический реестр всех UnitDef в content/units/.
##
## Используется для reward screen (S3.1.5), чтобы предложить юнитов
## которых у игрока ещё нет — независимо от unlocked_units в MetaProfile.
##
## v1: hardcoded список. v2: auto-scan content/units/*.tres.

const UNIT_IDS: Array[StringName] = [
	&"warrior", &"archer", &"cleric",
	&"mage", &"guardian", &"assassin", &"druid", &"berserker",
	&"beast", &"cavalry", &"warrior_v2",
	&"paladin", &"necromancer", &"knight", &"elementalist",
]


## Возвращает все id юнитов (включая заблокированные в MetaProfile).
static func all_ids() -> Array[StringName]:
	return UNIT_IDS.duplicate()


## Возвращает id юнитов определённого tier (1-3).
## Пустой массив если tier вне диапазона.
static func ids_by_tier(tier: int) -> Array[StringName]:
	var result: Array[StringName] = []
	for id in UNIT_IDS:
		var def: Resource = ContentDB_static.get_by_id(id)
		if def != null and def.tier == tier:
			result.append(id)
	return result
