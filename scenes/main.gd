extends Node
## Корневой узел. Сейчас сразу загружает BattleScene.
## Sprint 3 MainMenu scene создан но временно отключён для стабильности Web build —
## будет re-enabled после fix reward modal race condition.

func _ready() -> void:
    var scene: PackedScene = load("res://scenes/battle/battle_scene.tscn") as PackedScene
    if scene == null:
        GameLog.error("main", "Failed to load battle scene")
        return
    var inst: Node = scene.instantiate()
    add_child(inst)