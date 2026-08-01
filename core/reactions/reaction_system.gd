class_name ReactionSystemPure extends RefCounted
## Слушает GameBus и проверяет, есть ли у reactor-а подходящая реакция.
##
## Не знает про Effects — возвращает trigger, а UI/Combatant решает что делать.

var _reactions: Dictionary = {}  # combatant.def_id → Array[ReactionDef]


func register_reaction(combatant, reaction: Resource) -> void:
	if combatant == null or reaction == null:
		return
	var id: StringName = combatant.def_id
	if not _reactions.has(id):
		_reactions[id] = []
	_reactions[id].append(reaction)


func unregister_all(combatant) -> void:
	if combatant == null:
		return
	_reactions.erase(combatant.def_id)


## Возвращает первую реакцию, которая срабатывает на это событие.
## Не вызывает никаких эффектов — только проверяет условия.
func poll_reaction(combatant, trigger: StringName, _trigger_data: Dictionary) -> Resource:
	if combatant == null:
		return null
	var id: StringName = combatant.def_id
	if not _reactions.has(id):
		return null
	for reaction in _reactions[id]:
		if reaction == null:
			continue
		if reaction.trigger != trigger:
			continue
		if not Rng.chance(reaction.trigger_chance):
			continue
		return reaction
	return null
