class_name Balance extends RefCounted
## Single source of truth для всех игровых констант баланса.
## Когда будешь балансить — меняй числа здесь, не в логике.
##
## Зачем так: если золото за раунд вынести в literal "5+round_index" в run_controller,
## через 2 месяца ты не вспомнишь где это и будешь балансить "не ту" переменную.
## Здесь — все числа в одном месте, с комментариями.

# === Старт рана ===
const STARTING_GOLD: int = 10                # золото в начале рана
const STARTING_LIVES: int = 1                # сколько раз можно проиграть
const STARTING_UNIT_IDS: Array[StringName] = [&"warrior", &"archer"]

# === Экономика ===
const WIN_BONUS_GOLD: int = 5                # базовый бонус за победу
const WIN_BONUS_PER_ROUND: int = 1           # +1 за каждый раунд (итого: 5+round)

# === Боевая сетка ===
const GRID_WIDTH: int = 7
const GRID_HEIGHT: int = 4

# === Время ===
const DEFAULT_TICK_DT: float = 1.0 / 20.0    # 20 тиков/сек — баланс между плавностью и CPU
const MIN_ATTACK_SPEED: float = 0.01         # защита от деления на 0

# === Формулы (веса) ===
## Сколько единиц armor = 1 единице процентной защиты.
## 0.5 значит armor слабее — иначе он бы доминировал.
const ARMOR_WEIGHT: float = 0.5
## Максимальное снижение урона от defense (anti-stacking).
const MAX_DAMAGE_REDUCTION: float = 0.75
## Максимальный шанс dodge (anti-immune).
const MAX_DODGE_CHANCE: float = 0.75
## Максимальный crit chance.
const MAX_CRIT_CHANCE: float = 1.0

# === Скорости по умолчанию (для UI) ===
const DEFAULT_BATTLE_SPEED: float = 1.0
const FAST_BATTLE_SPEED: float = 2.0
const ULTRA_BATTLE_SPEED: float = 4.0

# === AI ===
const AI_DEFAULT_SIGHT_RANGE: int = 8

# === Враги по раундам ===
# Сколько врагов в каждом раунде. v1: только goblins, v2 — добавим scaling.
const ENEMY_COUNT_BY_ROUND: Dictionary = {
	1: 1,
	2: 1,
	3: 2,
	4: 2,
	5: 3,
	6: 3,
	7: 3,
	8: 4,
	9: 4,
	10: 5,
}


## Возвращает количество врагов для раунда. Cap по max_key в ENEMY_COUNT_BY_ROUND.
static func enemy_count_for_round(round_index: int) -> int:
	var best: int = 1
	for key in ENEMY_COUNT_BY_ROUND.keys():
		if key <= round_index and key > best - 1:
			best = ENEMY_COUNT_BY_ROUND[key]
	# Cap: для раундов 11+ используем последнее значение.
	return best


## Пул врагов для каждого раунда. Tier 1 в первых раундах, tier 2 с раунда 3,
## tier 3 (boss) только в финальных раундах. Это single source of truth —
## run_controller использует эту функцию для spawn.
const ENEMY_POOL_BY_TIER: Dictionary = {
	1: [&"goblin", &"goblin_archer"],
	2: [&"orc_warrior", &"skeleton_mage"],
	3: [&"troll_chief"],
}


## Возвращает массив id врагов (StringName), подходящих для данного раунда.
## Tier подмешивается: 70% tier=round_index//3+1, 30% — соседние tier.
static func enemy_pool_for_round(round_index: int) -> Array:
	var tier: int = clampi(round_index / 4 + 1, 1, 3)
	return ENEMY_POOL_BY_TIER.get(tier, [&"goblin"])


## HP multiplier для врагов по раунду: раунд 1 = 1.0x, раунд 10 = 1.6x.
## Линейный рост: каждый раунд +6.7% HP.
static func enemy_hp_multiplier(round_index: int) -> float:
	return 1.0 + 0.067 * float(round_index - 1)


## Возвращает координату Y для заднего ряда команды.
static func back_row_y(team: int) -> int:
	return 0 if team == 1 else GRID_HEIGHT - 1  # 0=ENEMY (верх), 1=PLAYER (низ)


## Формула урона с учётом защиты: damage * 100 / (100 + defense).
## magic=true обходит часть защиты (30% пробития).
## v2: armor (flat) добавляется с весом ARMOR_WEIGHT, magic_pen режет magic_resist.
static func compute_damage(base: int, defense: int, is_magic: bool, variance: float, variance_factor: float) -> int:
	var raw: float = float(base) * variance_factor
	var eff_def: int = defense if not is_magic else int(defense * 0.3)
	return maxi(1, int(round(raw * (100.0 / (100.0 + float(eff_def))))))


## v3: расширенная формула урона.
## Учитывает: crit, dodge (callers-side), magic_pen, armor (flat).
## Возвращает {dealt, is_crit, dodged}.
static func compute_attack(
	attacker_attack: int,
	attacker_crit_chance: float,
	attacker_crit_damage: float,
	attacker_magic_pen: float,
	target_defense: int,
	target_armor: int,
	target_dodge: float,
	is_magic: bool,
	base_variance: float
) -> Dictionary:
	# Dodge roll.
	if Rng.chance(target_dodge):
		return {"dealt": 0, "is_crit": false, "dodged": true}
	# Crit roll.
	var is_crit: bool = Rng.chance(attacker_crit_chance)
	var crit_mult: float = attacker_crit_damage if is_crit else 1.0
	# Variance.
	var vf: float = 1.0 + Rng.randf_range(-base_variance, base_variance)
	# Defense: процентная + flat (с весом).
	var def_after_pen: int = target_defense
	if is_magic:
		def_after_pen = int(round(target_defense * (1.0 - attacker_magic_pen)))
	# Armor — слабее, чем процентная защита (вес 0.5).
	var eff_def: float = float(def_after_pen) + float(target_armor) * ARMOR_WEIGHT
	if is_magic:
		eff_def = int(eff_def)  # для magic тоже применяем armor, но в меньшей степени
	# Damage.
	var raw: float = float(attacker_attack) * crit_mult * vf
	var final: int = maxi(1, int(round(raw * (100.0 / (100.0 + eff_def)))))
	return {"dealt": final, "is_crit": is_crit, "dodged": false}


## Возвращает длительность атаки (сколько тиков копится до удара) с защитой от деления на 0.
static func attack_interval(attack_speed: float) -> float:
	return 1.0 / maxf(MIN_ATTACK_SPEED, attack_speed)


## Применяет CDR к кулдауну способности. cdr=0.25 → 25% быстрее.
static func apply_cdr(base_cooldown: float, cdr: float) -> float:
	return base_cooldown * (1.0 - clampf(cdr, 0.0, 0.9))


## Применяет healing_received к входящему хилу. 1.0 = норма, 0.5 = половина, 2.0 = двойной.
static func apply_healing_received(base_heal: int, healing_received: float) -> int:
	return maxi(0, int(round(float(base_heal) * healing_received)))


## Применяет shield_strength к размеру щита. 1.0 = стандарт, 1.5 = усиленный.
static func apply_shield_strength(base_shield: int, shield_strength: float) -> int:
	return int(round(float(base_shield) * maxf(0.0, shield_strength)))