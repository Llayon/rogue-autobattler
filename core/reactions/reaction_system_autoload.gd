class_name ReactionSystemAutoload extends Node
## Autoload-обёртка. Регистрируется как "ReactionSystem".
##
## Сам ReactionSystem — RefCounted для тестирования. Эта обёртка — Node
## чтобы стать autoload, и держит экземпляр ReactionSystem в `_inner`.

const ReactionSystemScript = preload("res://core/reactions/reaction_system.gd")

var _inner: ReactionSystemPure = null


func _ready() -> void:
	_inner = ReactionSystemScript.new()
	# Подключаемся к GameBus сигналам.
	#
	# The connect is guarded: in headless --script mode the autoload
	# can be initialised more than once, and connecting the same
	# method twice makes Godot write an error to stderr. The guard
	# also keeps a test that wired the same handler from producing a
	# duplicate handler.
	if has_node("/root/EventBus"):
		var bus: Node = get_node("/root/EventBus")
		if bus.has_signal("reaction_registered"):
			if not bus.reaction_registered.is_connected(_on_reaction_registered):
				bus.reaction_registered.connect(_on_reaction_registered)
		if bus.has_signal("reaction_unregistered"):
			if not bus.reaction_unregistered.is_connected(_on_reaction_unregistered):
				bus.reaction_unregistered.connect(_on_reaction_unregistered)


## Forward API к inner (для тестов и интеграции).
func register_reaction(combatant, reaction: Resource) -> void:
	if _inner != null:
		_inner.register_reaction(combatant, reaction)


## Removes every registration for every class.
##
## Called at the start of a battle so the registry never inherits
## the previous battle's reactions.
func clear_all() -> void:
	if _inner != null:
		_inner.clear_all()


func unregister_all(combatant) -> void:
	if _inner != null:
		_inner.unregister_all(combatant)


func poll_reaction(combatant, trigger: StringName, trigger_data: Dictionary) -> Resource:
	if _inner != null:
		return _inner.poll_reaction(combatant, trigger, trigger_data)
	return null


func _on_reaction_registered(combatant, reaction: Resource) -> void:
	register_reaction(combatant, reaction)


func _on_reaction_unregistered(combatant) -> void:
	unregister_all(combatant)
