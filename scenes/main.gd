extends Node
## Корневой узел. Загружает RootScene который содержит MainMenu + BattleScene
## как sub-views с visibility switching (без queue_free).

func _ready() -> void:
    var scene: PackedScene = load("res://scenes/root/root_scene.tscn") as PackedScene
    if scene == null:
        push_error("Failed to load root_scene.tscn")
        return
    var inst: Node = scene.instantiate()
    add_child(inst)