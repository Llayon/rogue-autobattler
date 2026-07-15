class_name EncounterNode extends RefCounted
## Узел карты энкаунтеров (S5.1).
##
## Содержит id (уникальный в EncounterMap), type (EncounterType.Kind),
## depth (1..10 — слой на карте = round_index), parent_ids и child_ids
## для связей в DAG.

var id: int = -1
var type: int = 0  # EncounterType.Kind
var depth: int = 0  # 1..MAP_MAX_DEPTH (round_index / слой)
var parent_ids: Array[int] = []
var child_ids: Array[int] = []
## True если игрок уже посетил этот нод в текущем ране.
var visited: bool = false
## True если нод доступен из текущей позиции игрока (для UI подсветки).
var available: bool = false


func _init(p_id: int = -1, p_type: int = 0, p_depth: int = 0) -> void:
	id = p_id
	type = p_type
	depth = p_depth


## Возвращает true если это combat-тип (бой с врагами).
func is_combat() -> bool:
	return EncounterType.is_combat(type)


## Возвращает display name типа (для UI).
func get_display_name() -> String:
	return EncounterType.display_name(type)