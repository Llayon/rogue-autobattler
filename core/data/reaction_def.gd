class_name ReactionDef extends Resource
## Описание реакции: когда срабатывает, что делает.
##
## Примеры:
## - AoO (Attack of Opportunity): когда враг выходит из клетки рядом — атаковать.
## - Shield Block: при входящем уроне — шанс 30% заблокировать 50%.
## - Reactive Strike: при атаке на союзника — контратака.

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""

# Триггер: какой GameBus сигнал активирует.
# "unit_attacked", "unit_move_start", "round_started".
@export var trigger: StringName = &"unit_attacked"

# Шанс срабатывания (0.0-1.0).
@export var trigger_chance: float = 1.0

# Дополнительные фильтры (например, only melee).
@export var melee_only: bool = false
@export var range_cells: int = 1
