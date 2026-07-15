class_name BattleRunner extends RefCounted
## Тиковый раннер боя. Вызывай step(dt) из play_scene каждый кадр.
##
## Логика тика:
##   1. tick_statuses (DOT/HOT + длительности) для всех.
##   2. tick_cooldowns.
##   3. Если есть мёртвые — удалить и emit unit_died.
##   4. Для каждого живого юнита:
##      a) AI выбирает цель (move + attack).
##      b) Если цель в радиусе атаки — накапливается _attack_acc, потом бьёт.
##      c) Иначе двигается к цели.
##      d) Пробует применить способности (если кулдаун 0 и AI решил).
##   5. Если одна из сторон без живых — завершить бой.
##
## dt рекомендуется 1.0/20.0 (20 тиков/сек).
## При speed=2 — передавай dt * 2.0, при speed=4 — * 4.0.

const BattleStateScript = preload("res://core/battle/battle_state.gd")
const DefaultAiScript = preload("res://core/ai/default_ai.gd")
const BalanceScript = preload("res://core/balance.gd")

const DEFAULT_TICK_DT: float = BalanceScript.DEFAULT_TICK_DT

var ctx = null  # BattleContext (RefCounted)
var state = null  # BattleState (Resource)
var ai_factory: Callable = Callable()  # (combatant) -> AiController


func _init(battle_ctx, battle_state = null) -> void:
	ctx = battle_ctx
	state = battle_state if battle_state != null else BattleStateScript.new()


func step(dt: float) -> void:
	if state.phase != 1:  # BATTLE
		return
	state.battle_time += dt
	# S4.3: тикаем visual_state (flash/fade/pos_lerp) ПЕРЕД основной логикой.
	for c in ctx.all_combatants():
		c._tick_visual(dt)
	# S4.3: чистим faded combatants (когда fade_alpha=0 после смерти).
	_cleanup_faded()
	# 1. Статусы + ресурсы (mana, regen).
	for c in ctx.all_combatants():
		c.tick_statuses(dt)
		c.tick_cooldowns(dt)
		c.tick_resources(dt)
	_cleanup_dead()
	if _is_battle_over():
		_end_battle()
		return
	for c in ctx.all_combatants():
		_tick_unit(c, dt)


func start() -> void:
	state.phase = 1
	state.battle_time = 0.0
	state.winner_team = -1
	GameBus.emit_battle_started()


func _tick_unit(c, dt: float) -> void:
	if c == null or not c.is_alive() or c.is_stunned():
		return
	var ai = c.ai_controller
	if ai == null and ai_factory.is_valid():
		ai = ai_factory.call(c)
		c.ai_controller = ai
	if ai == null:
		ai = DefaultAiScript.new()
		c.ai_controller = ai
	ai.tick(c, ctx, dt)


## Возвращает true, если выполнено условие завершения.
func _is_battle_over() -> bool:
	return ctx.combatants_of_team(0).is_empty() or ctx.combatants_of_team(1).is_empty()


func _end_battle() -> void:
	state.phase = 2
	if ctx.combatants_of_team(0).is_empty() and ctx.combatants_of_team(1).is_empty():
		state.winner_team = -1
	elif ctx.combatants_of_team(0).is_empty():
		state.winner_team = 1
	else:
		state.winner_team = 0
	GameBus.emit_battle_ended(state.winner_team)
	var winner_name: String = "neutral"
	if state.winner_team == 0:
		winner_name = "player"
	elif state.winner_team == 1:
		winner_name = "enemy"
	GameLog.info("battle", "Battle ended", {"winner": winner_name})


func _cleanup_dead() -> void:
	var to_remove: Array = []
	for c in ctx.combatant_registry:
		if c == null:
			continue
		if not c.is_alive():
			to_remove.append(c)
	for c in to_remove:
		ctx.unregister(c)


## S4.3: удаляет combatant после полного fade-out (fade_alpha <= 0).
func _cleanup_faded() -> void:
	var to_remove: Array = []
	for c in ctx.combatant_registry:
		if c == null:
			continue
		if c.visual_state["is_dying"] and c.visual_state["fade_alpha"] <= 0.0:
			to_remove.append(c)
	for c in to_remove:
		ctx.unregister(c)