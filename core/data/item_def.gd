class_name ItemDef extends Resource
## Предмет (экипировка или расходник). v1 — заглушка для архитектуры,
## реальная система предметов появится в v3.
##
## Зарезервированные поля — чтобы .tres-файлы предметов не ломали загрузку
## когда мы добавим модуль.

@export var id: StringName = &""
@export var display_name: String = ""
@export var icon: Texture2D
@export_multiline var description: String = ""

@export var cost: int = 1
@export var tier: int = 1

# Базовые бонусы.
@export var bonus_max_hp: int = 0
@export var bonus_attack: int = 0
@export var bonus_defense: int = 0
@export var bonus_attack_speed: float = 0.0