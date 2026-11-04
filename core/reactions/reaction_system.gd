class_name ReactionSystemPure extends RefCounted
## Слушает GameBus и проверяет, есть ли у reactor-а подходящая реакция.
##
## Не знает про Effects — возвращает trigger, а UI/Combatant решает что делать.

var _reactions: Dictionary = {}  # combatant.def_id → Array[ReactionDef]


## Registers a reaction for a combatant.
##
## The registry is keyed by combatant.def_id, so every combatant of
## the same class shares one list. A reaction must therefore be
## registered ONCE per (def_id, reaction) pair.
##
## Without the dedup below, N combatants of the same class produced N
## entries for the same reaction, and poll_reaction() draws the
## chance gate once per entry. The effective trigger chance became
## 1-(1-p)^N instead of p:
##
##   1 paladin  -> 0.287 (correct)
##   2 paladins -> 0.550 (should be 0.300)
##   3 paladins -> 0.713 (should be 0.300)
##
## and because nothing unregisters between battles, a multi-round run
## kept appending the same reaction until the chance approached 1.0.
func register_reaction(combatant, reaction: Resource) -> void:
	if combatant == null or reaction == null:
		return
	var id: StringName = combatant.def_id
	if not _reactions.has(id):
		_reactions[id] = []
	var list: Array = _reactions[id]
	# The same (reaction id, trigger) pair must not be registered
	# twice for one class. The id is the reaction's identity: two
	# views of the same reaction (for example the Phase-3 resource
	# and the legacy view) are distinct ids and stay distinct
	# entries. The trigger is part of the key because
	# poll_reaction() matches the trigger EXACTLY: collapsing two
	# registrations that differ only in trigger would silently drop
	# one of them and make that trigger unreachable.
	for existing in list:
		if existing == null:
			continue
		var same_id: bool = StringName(existing.get("id")) == StringName(reaction.get("id"))
		var same_trigger: bool = StringName(existing.get("trigger")) == StringName(reaction.get("trigger"))
		if same_id and same_trigger:
			return
	list.append(reaction)


## Removes EVERY registration for every class.
##
## The registry is process-lifetime state, so a battle that starts
## without clearing it inherits the reactions of the previous battle.
## That is wrong for two reasons:
##
##   - a class that owned a reaction in battle A would keep that
##     reaction in battle B even when the new battle has no such
##     unit (stale ownership), and
##   - the chance gate would be evaluated once per leftover entry,
##     inflating the effective probability.
##
## The registry is keyed by def_id, so unregistering per combatant is
## NOT a safe substitute: removing one Paladin's reaction would also
## remove the reaction of every other living Paladin of that class.
##
## A battle boundary therefore clears the whole registry at once.
func clear_all() -> void:
	_reactions.clear()


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
