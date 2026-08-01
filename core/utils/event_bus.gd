extends Node
class_name GameBus
## Глобальная шина событий. Регистрируется в project.godot как autoload "EventBus".
## Доступ через имя "GameBus" (class_name) — это даёт тип.
## Сигналы — instance-level (не static), потому что static signal в GDScript невозможен.
##
## Использование в core/*:
##   GameBus.emit_unit_died(self)   # безопасный вызов без зависимости от autoload instance
##
## Использование в scene/* (UI):
##   EventBus.unit_died.connect(_on_unit_died)  # подписка через autoload instance

signal unit_damaged(combatant, amount: int, source)
signal unit_died(combatant)
signal unit_dodged(attacker, target)  # v3: dodge сработал
signal status_resisted(combatant, status_id: StringName, tenacity: float)  # v3: tenacity сработал
signal ability_cast(ability, caster, target)
signal effect_applied(effect, target, source)
signal status_changed(combatant, status_id: StringName, added: bool)
signal round_started(round_index: int)
signal round_ended(round_index: int, winner_team: int)
signal battle_started
signal battle_ended(winner_team: int)
signal gold_changed(new_value: int)
signal lives_changed(new_value: int)
signal xp_changed(new_xp: int, new_level: int)
# S3.1.5: reward screen signals
signal reward_offered(unit_ids: Array[StringName])
signal reward_chosen(unit_id: StringName, slot: int)
# S3.2: meta progression unlock signal
signal unit_unlocked(unit_id: StringName)
# S3.3: save/load в середине рана
signal run_saved(seed: int)
signal run_resumed(seed: int)
# S4.2: floating damage numbers (для BattleView overlay)
signal damage_dealt(target, amount: int, source)
# Reactions: dispatcher для AoO, Shield Block, и т.п.
signal reaction_registered(combatant, reaction: Resource)
signal reaction_unregistered(combatant)
signal reaction_triggered(combatant, reaction: Resource)


## Возвращает инстанс шины событий (autoload или созданный вручную в тестах).
## Если autoload не зарегистрирован (например, в --script режиме) — возвращает null,
## и хелперы ниже работают как no-op.
static func _instance() -> Node:
	# Ищем autoload-инстанс. autoload "EventBus" даёт Node по пути "/root/EventBus".
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.root.get_node_or_null("EventBus")


## Хелперы для безопасной эмиссии из core/* (без зависимости от autoload instance).

static func emit_unit_died(combatant) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.unit_died.emit(combatant)


static func emit_unit_dodged(attacker, target) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.unit_dodged.emit(attacker, target)


static func emit_status_resisted(combatant, status_id: StringName, tenacity: float) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.status_resisted.emit(combatant, status_id, tenacity)


static func emit_unit_damaged(combatant, amount: int, source) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.unit_damaged.emit(combatant, amount, source)


static func emit_status_changed(combatant, status_id: StringName, added: bool) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.status_changed.emit(combatant, status_id, added)


static func emit_battle_started() -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.battle_started.emit()


static func emit_battle_ended(winner_team: int) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.battle_ended.emit(winner_team)


static func emit_round_started(round_index: int) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.round_started.emit(round_index)


static func emit_gold_changed(value: int) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.gold_changed.emit(value)


static func emit_lives_changed(value: int) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.lives_changed.emit(value)


static func emit_ability_cast(ability, caster, target) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.ability_cast.emit(ability, caster, target)


static func emit_effect_applied(effect, target, source) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.effect_applied.emit(effect, target, source)


static func emit_reward_offered(unit_ids: Array[StringName]) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.reward_offered.emit(unit_ids)


static func emit_reward_chosen(unit_id: StringName, slot: int) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.reward_chosen.emit(unit_id, slot)


## S3.2: meta progression — игрок разблокировал нового юнита за пределами рана.
## Используется UI для показа уведомления "Вы разблокировали X!".
static func emit_unit_unlocked(unit_id: StringName) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.unit_unlocked.emit(unit_id)


## S3.3: state рана сохранён на диск. UI может показать "Saved".
static func emit_run_saved(seed_value: int) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.run_saved.emit(seed_value)


## S3.3: state рана загружен с диска через resume_run(). UI переходит в PREP.
static func emit_run_resumed(seed_value: int) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.run_resumed.emit(seed_value)


## S4.2: emit при нанесении урона. UI показывает floating number.
static func emit_damage_dealt(target, amount: int, source) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.damage_dealt.emit(target, amount, source)


## Регистрирует reaction_у Combatant-а в ReactionSystem.
static func emit_reaction_registered(combatant, reaction: Resource) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.reaction_registered.emit(combatant, reaction)


static func emit_reaction_unregistered(combatant) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.reaction_unregistered.emit(combatant)


## Реакция успешно сработала (например, контратака произошла).
static func emit_reaction_triggered(combatant, reaction: Resource) -> void:
	var inst: Node = _instance()
	if inst != null:
		inst.reaction_triggered.emit(combatant, reaction)