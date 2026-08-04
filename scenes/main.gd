extends Node
## Корневой узел. Загружает MainMenu — игрок выбирает New Run или Continue.

func _ready() -> void:
    var scene: PackedScene = load("res://scenes/main_menu/main_menu.tscn") as PackedScene
    if scene == null:
        push_error("Failed to load main_menu scene")
        return
    var inst: Node = scene.instantiate()
    add_child(inst)