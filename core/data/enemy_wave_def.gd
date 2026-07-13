class_name EnemyWaveDef extends Resource
## Описание волны врагов для конкретного раунда.
## .tres в content/enemies/waves/.

@export var id: StringName = &""
@export var display_name: String = ""
@export var round_index: int = 1

# Список юнитов (id'ы UnitDef), которые появятся в волне.
# Количество, позиции и конкретные юниты определяются волной.
@export var unit_defs: Array[StringName] = []
@export var unit_count: int = 3

# Бонус к параметрам юнитов в этой волне (мультипликативно).
@export var hp_multiplier: float = 1.0
@export var attack_multiplier: float = 1.0
@export var defense_multiplier: float = 1.0