class_name StatusDef extends Resource
## Описание длительного эффекта (бафф/дебафф). .tres в content/effects/.
##
## Примеры: BURN (DOT-урон), STUN (не может действовать), ATK_UP (+X% атаки).

@export var id: StringName = &""
@export var display_name: String = ""
@export var icon: Texture2D
@export_multiline var description: String = ""

# Длительность. 0 = мгновенный (но всё равно Status-обёртка ради UI/иконки).
@export var duration: float = 3.0

# Периодический тик (для DOT/HOT). 0 = срабатывает только при наложении.
@export var tick_interval: float = 1.0

# Модификаторы (применяются к Combatant на время действия статуса).
@export var attack_modifier: float = 0.0     # абсолютный/процентный — в зависимости от is_percent_modifier
@export var defense_modifier: float = 0.0
@export var move_speed_modifier: float = 0.0
@export var attack_speed_modifier: float = 0.0

@export var is_percent_modifier: bool = true  # true = +X%, false = +X абсолютно

# Поведение.
@export var blocks_actions: bool = false     # STUN
@export var is_harmful: bool = true
@export var stackable: bool = false
@export var max_stacks: int = 1

# DOT-урон/хил за тик (опционально).
@export var dot_damage: int = 0
@export var dot_heal: int = 0
@export var dot_damage_kind: int = 0          # 0 = physical, 1 = magic, 2 = true