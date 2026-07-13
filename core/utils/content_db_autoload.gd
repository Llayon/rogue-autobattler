extends Node
## Node-обёртка для ContentDB. Реальная логика — в class_name ContentDB.

func _ready() -> void:
	# Контент грузится лениво через ContentDB.ensure_loaded().
	pass