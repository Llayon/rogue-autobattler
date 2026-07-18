class_name Combatant extends RefCounted
## Рантайм-инстанс юнита на сетке. Контейнер для компонентов.
##
## Композиция вместо god-object: Combatant = HealthComponent + ManaComponent +
## StatusList + CooldownList + AttackMeter + RegenComponent + данные из UnitDef.
## Каждый компонент тестируется и сериализуется независимо.
##
## Не знает о нодах. BattleContext владеет реестром и сеткой.

const BalanceScript = preload("res://core/balance.gd")
const ManaComponentScript = preload("res://core/battle/mana_component.gd")
const RegenComponentScript = preload("res://core/battle/regen_component.gd")

# === Данные из UnitDef (иммутабельные после создания) ===
var def_id: StringName
var display_name: String
var team: int
var attack_base: int
var defense_base: int
var magic_power_base: int
var magic_resist_base: int
var attack_speed_base: float
var move_speed_base: float
var attack_range: int
var sight_range: int

# === Характеристики (v3+) ===
var crit_chance: float = 0.05
var crit_damage: float = 1.5
var dodge: float = 0.0
var armor: int = 0
var healing_received: float = 1.0
var shield_strength: float = 1.0
var lifesteal: float = 0.0
var thorns: float = 0.0
var magic_pen: float = 0.0
var cdr: float = 0.0
var tenacity: float = 0.0
var health_regen: float = 0.0
var max_mana_base: int = 100
var mana_regen: float = 1.0

var abilities: Array = []  # Array[AbilityDef]

# === Позиция (владелец — BattleContext) ===
var cell: Vector2i = Vector2i(-1, -1)
# S4.3: предыдущая клетка для плавного lerp при move.
var prev_cell: Vector2i = Vector2i(-1, -1)

# === Компоненты ===
var health: HealthComponent = HealthComponent.new()
var mana = ManaComponentScript.new()
var statuses: StatusList = StatusList.new()
var cooldowns: CooldownList = CooldownList.new()
var attack_meter: AttackMeter = AttackMeter.new()
var regen = RegenComponentScript.new()

# === Runtime ===
var ai_controller = null
var just_summoned: bool = false

# === S4.3: Visual state ===
## flash_alpha: 0..1, 1 = full white flash (hit feedback)
## fade_alpha: 0..1, 1 = fully visible, 0 = invisible (dead)
## pos_lerp: 0..1, 1 = animating from prev_cell, 0 = settled at cell
## is_dying: true после смерти (fade_alpha decrement)
var visual_state: Dictionary = {
	"flash_alpha": 0.0,
	"fade_alpha": 1.0,
	"is_dying": false,
	"pos_lerp": 0.0,
}
const FLASH_DECAY_PER_SEC: float = 1.0 / 0.15
const FADE_DECAY_PER_SEC: float = 1.0 / 0.4
const POS_LERP_DECAY_PER_SEC: float = 1.0 / 0.2


## Конструктор: принимает UnitDef и опционально overrides.
## hp_override: S6.3 — если > 0, устанавливает начальное HP = hp_override
## (используется при apply_run_unit_state для персистентности HP
## между боями через state.unit_states[]).
## S7.2: bonus_attack, bonus_defense, bonus_max_hp — применяются как
## additive flat bonuses сверх def.attack / def.defense / def.max_hp.
func _init(def: Resource, hp_mul: float = 1.0, atk_mul: float = 1.0, def_mul: float = 1.0, hp_override: int = -1, bonus_attack: int = 0, bonus_defense: int = 0, bonus_max_hp: int = 0) -> void:
	if def == null:
		GameLog.error("combatant", "Combatant created with null def")
		return
	def_id = def.id
	display_name = def.display_name
	team = def.team
	attack_base = int(round(float(def.attack) * atk_mul))
	defense_base = int(round(float(def.defense) * def_mul))
	magic_power_base = def.magic_power
	magic_resist_base = def.magic_resist
	# S7.2: apply bonuses from equipped items (additive).
	attack_base += bonus_attack
	defense_base += bonus_defense
	attack_speed_base = def.attack_speed
	move_speed_base = def.move_speed
	attack_range = def.attack_range
	sight_range = def.sight_range
	# v3 характеристики.
	crit_chance = clampf(def.crit_chance, 0.0, BalanceScript.MAX_CRIT_CHANCE)
	crit_damage = def.crit_damage
	dodge = clampf(def.dodge, 0.0, BalanceScript.MAX_DODGE_CHANCE)
	armor = maxi(0, def.armor)
	healing_received = def.healing_received
	shield_strength = def.shield_strength
	lifesteal = def.lifesteal
	thorns = def.thorns
	magic_pen = def.magic_pen
	cdr = def.cdr
	tenacity = def.tenacity
	health_regen = def.health_regen
	max_mana_base = def.max_mana
	mana_regen = def.mana_regen
	abilities = def.abilities.duplicate()
	# S6.3: max_hp всегда = def.max_hp (или * hp_mul). hp_override
	# влияет только на current_hp (start at).
	var max_hp_val: int = int(round(float(def.max_hp) * hp_mul))
	# S7.2: apply max_hp bonus from items.
	max_hp_val += bonus_max_hp
	health.configure(max_hp_val)
	if hp_override > 0:
		# S6.3: persisted HP — set current без изменения max.
		var cap: int = health.max_hp()
		health.current_hp = mini(hp_override, cap)
	# S7.2: persist any item-bonus HP overflow into unit_states so subsequent
	# battles start with the bonus too.
	if bonus_max_hp > 0:
		# Find unit_state and update it (best-effort — not strictly required).
		pass  # bonus persists naturally in next start_battle call
	mana.configure(max_mana_base, mana_regen)
	regen.configure(health_regen)


# === Forwarding shortcuts (для читаемости вызовов) ===

func max_hp() -> int:
	return health.max_hp()


func current_hp() -> int:
	return health.current_hp


func is_alive() -> bool:
	return health.is_alive()


func take_damage(amount: int, source) -> int:
	var dealt: int = health.take_damage(amount)
	# S4.3: trigger visual flash на hit, и fade на death.
	if dealt > 0:
		visual_state["flash_alpha"] = 1.0
		if not health.is_alive() and not visual_state["is_dying"]:
			visual_state["is_dying"] = true
			visual_state["fade_alpha"] = 1.0
	if not health.is_alive():
		GameBus.emit_unit_died(self)
	# Thorns: если есть source и он жив, возвращаем часть урона.
	if source != null and source != self and source.is_alive() and thorns > 0.0:
		var thorns_dmg: int = int(round(float(dealt) * thorns))
		if thorns_dmg > 0:
			source.take_damage(thorns_dmg, self)
	return dealt


## S4.3: тикает visual_state (вызывается из BattleRunner.step()).
## Decrement flash_alpha, fade_alpha (если is_dying), pos_lerp.
func _tick_visual(dt: float) -> void:
	visual_state["flash_alpha"] = maxf(0.0, visual_state["flash_alpha"] - FLASH_DECAY_PER_SEC * dt)
	if visual_state["is_dying"]:
		visual_state["fade_alpha"] = maxf(0.0, visual_state["fade_alpha"] - FADE_DECAY_PER_SEC * dt)
	visual_state["pos_lerp"] = maxf(0.0, visual_state["pos_lerp"] - POS_LERP_DECAY_PER_SEC * dt)


## S4.3: перемещение с анимацией. Сохраняет prev_cell, выставляет pos_lerp=1.
func move_to_with_anim(new_cell: Vector2i) -> void:
	prev_cell = cell
	cell = new_cell
	visual_state["pos_lerp"] = 1.0


func heal(amount: int) -> int:
	if not is_alive():
		return 0
	var effective: int = BalanceScript.apply_healing_received(amount, healing_received)
	return health.heal(effective)


func add_shield(amount: int) -> void:
	var effective: int = BalanceScript.apply_shield_strength(amount, shield_strength)
	health.add_shield(effective)


## Сокращение для распространённой формулы: защита + 100 в знаменателе.
## Не считает "магический" урон (is_magic=false). Используется для basic_attack.
func defense() -> int:
	return _apply_modifier(defense_base, "defense_modifier")


## То же для магической защиты. Используется для magic-атак.
func magic_resist() -> int:
	return _apply_modifier(magic_resist_base, "magic_resist_modifier")


func attack() -> int:
	return _apply_modifier(attack_base, "attack_modifier")


func attack_speed() -> float:
	return _apply_modifier(attack_speed_base, "attack_speed_modifier")


func move_speed() -> float:
	return _apply_modifier(move_speed_base, "move_speed_modifier")


func _apply_modifier(base_value: float, field: String) -> float:
	var result: float = float(base_value)
	for s in statuses.active():
		var def: Resource = s.def
		if def == null:
			continue
		# Безопасный доступ: если поле не объявлено в StatusDef, get() вернёт null.
		var raw_value = def.get(field)
		if raw_value == null:
			continue
		var mod: float = float(raw_value)
		if mod == 0.0:
			continue
		if def.is_percent_modifier:
			result *= 1.0 + mod
		else:
			result += mod
	return result


# === Статусы (делегация) ===

func apply_status(def: Resource, duration: float, max_stacks: int, source) -> void:
	# Tenacity: шанс иммунитета к status-эффектам.
	if tenacity > 0.0 and Rng.chance(tenacity):
		GameBus.emit_status_resisted(self, def.id, tenacity)
		return
	statuses.apply(def, duration, max_stacks, source)
	GameBus.emit_status_changed(self, def.id, true)


func has_status(status_id: StringName) -> bool:
	return statuses.has(status_id)


func active_statuses() -> Array:
	return statuses.active()


func dispel_statuses(count: int, harmful_only: bool) -> Array:
	var removed: Array = statuses.dispel(count, harmful_only)
	for sid in removed:
		GameBus.emit_status_changed(self, sid, false)
	return removed


func is_stunned() -> bool:
	return statuses.has_blocking_action()


## Тикает статусы. При DOT/HOT применяет урон/хил через health,
## эмитит события через GameBus. Возвращает список событий.
func tick_statuses(dt: float) -> Array:
	var callbacks: Dictionary = {
		"on_dot": _on_status_dot,
		"on_hot": _on_status_hot,
		"on_expire": _on_status_expire,
	}
	return statuses.tick(dt, callbacks)


func _on_status_dot(amount: int, source) -> void:
	take_damage(amount, source)


func _on_status_hot(amount: int) -> void:
	heal(amount)


func _on_status_expire(status_id: StringName) -> void:
	GameBus.emit_status_changed(self, status_id, false)


# === Кулдауны (делегация) ===

func put_on_cooldown(ability: Resource) -> void:
	if ability == null:
		return
	var effective: float = BalanceScript.apply_cdr(ability.cooldown, cdr)
	cooldowns._put_raw(ability.id, effective)


func cooldown_remaining(ability: Resource) -> float:
	return cooldowns.remaining(ability)


func is_on_cooldown(ability: Resource) -> bool:
	return cooldowns.is_on_cooldown(ability)


func tick_cooldowns(dt: float) -> void:
	cooldowns.tick(dt)


## Тикает mana и regen. Вызывается из BattleRunner.step() каждый кадр.
func tick_resources(dt: float) -> void:
	mana.regen_tick(dt)
	regen.tick(dt, health)


# === Атака ===

func can_attack() -> bool:
	if not is_alive() or is_stunned():
		return false
	return attack_meter.is_ready(attack_speed())


func accumulate_attack(dt: float) -> void:
	attack_meter.accumulate(dt)


func reset_attack_accumulator() -> void:
	attack_meter.reset()


## Выполняет базовую автоатаку: dodge → crit → variance → defense → lifesteal → thorns.
## Возвращает {dealt, is_crit, dodged}.
func basic_attack(target) -> Dictionary:
	if target == null or not target.is_alive() or not is_alive():
		return {"dealt": 0, "is_crit": false, "dodged": false}
	var result: Dictionary = BalanceScript.compute_attack(
		attack(),
		crit_chance,
		crit_damage,
		magic_pen,
		target.defense(),
		target.armor,
		target.dodge,
		false,
		0.05
	)
	if result.dodged:
		GameBus.emit_unit_dodged(self, target)
		return result
	var pre_hp: int = target.health.current_hp
	target.take_damage(result.dealt, self)
	var actually_dealt: int = pre_hp - target.health.current_hp
	GameBus.emit_unit_damaged(target, actually_dealt, self)
	result.dealt = actually_dealt
	# Lifesteal — хилим себя % от нанесённого.
	if actually_dealt > 0 and lifesteal > 0.0:
		var heal_amount: int = int(round(float(actually_dealt) * lifesteal))
		if heal_amount > 0:
			heal(heal_amount)
	return result


# === Сериализация ===

func to_dict() -> Dictionary:
	return {
		"def_id": def_id,
		"team": team,
		"cell": [cell.x, cell.y],
		"health": health.to_dict(),
		"mana": mana.to_dict(),
		"statuses": statuses.to_dict(),
		"cooldowns": cooldowns.to_dict(),
		"attack_meter": attack_meter.to_dict(),
		"regen": regen.to_dict(),
	}


func from_dict(d: Dictionary, ability_lookup: Callable) -> void:
	def_id = d.get("def_id", &"")
	team = int(d.get("team", 0))
	var c: Array = d.get("cell", [-1, -1])
	cell = Vector2i(int(c[0]), int(c[1]))
	health.from_dict(d.get("health", {}))
	mana.from_dict(d.get("mana", {}))
	statuses.from_dict(d.get("statuses", []), ability_lookup)
	cooldowns.from_dict(d.get("cooldowns", {}))
	attack_meter.from_dict(d.get("attack_meter", {}))
	regen.from_dict(d.get("regen", {}))