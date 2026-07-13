extends Node
## Корневой узел. Сейчас сразу загружает BattleScene.
## В v2 здесь будет главное меню → выбор рана → переход на BattleScene.

func _ready() -> void:
	var scene: PackedScene = load("res://scenes/battle/battle_scene.tscn") as PackedScene
	if scene == null:
		GameLog.error("main", "Failed to load battle scene")
		return
	var inst: Node = scene.instantiate()
	add_child(inst)