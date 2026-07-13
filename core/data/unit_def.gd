class_name UnitDef extends Resource
## Описание типа юнита. Хранится как .tres в content/units/.
##
## Содержит статические параметры (HP, атака и т.п.) и список способностей.
## Рантайм-данные (текущий HP, кулдауны, статусы) живут в Combatant.

@export var id: StringName = &""
@export var display_name: String = ""
@export var icon: Texture2D
@export var team: int = 0  # 0=PLAYER, 1=ENEMY, 2=NEUTRAL (см. core/data/team.gd)

# Боевые параметры.
# === Базовые боевые параметры ===
@export var max_hp: int = 100
@export var attack: int = 10
@export var defense: int = 0
@export var magic_power: int = 0
@export var magic_resist: int = 0
@export var attack_speed: float = 1.0   # атак в секунду
@export var move_speed: float = 1.0     # клеток в секунду
@export var attack_range: int = 1       # в клетках
@export var sight_range: int = 8

# === Crit ===
## Шанс критического удара (0.0 = никогда, 1.0 = всегда).
## Применяется к автоатакам и к эффектам, помеченным can_crit.
@export var crit_chance: float = 0.05
## Множитель урона при крите (1.5 = +50% урона).
@export var crit_damage: float = 1.5

# === Defensive ===
## Шанс увернуться от атаки (0.0-0.5, default 0).
## Не работает против DOT (постоянный урон).
@export var dodge: float = 0.0
## Flat защита (в отличие от defense — процентной). Складывается с defense.
@export var armor: int = 0
## % от входящего хила (1.0 = 100%, 0.5 = уменьшенный, 2.0 = усиленный).
@export_range(0.0, 3.0) var healing_received: float = 1.0
## Множитель эффективности щита (1.0 = стандарт).
@export_range(0.5, 3.0) var shield_strength: float = 1.0

# === Offense / sustain ===
## % от нанесённого урона → HP. Применяется после успешной атаки.
@export_range(0.0, 1.0) var lifesteal: float = 0.0
## % возвращённого урона атакующему.
@export_range(0.0, 1.0) var thorns: float = 0.0
## % игнорируемой magic_resist (0.0-1.0).
@export_range(0.0, 1.0) var magic_pen: float = 0.0

# === Mana / Cooldowns ===
@export var max_mana: int = 100
@export var mana_regen: float = 1.0      # mana per second
## Уменьшение кулдаунов (0.0-0.5, default 0).
@export_range(0.0, 0.5) var cdr: float = 0.0

# === Regen / Resist ===
## HP, восстанавливаемое в секунду вне боя и в бою.
@export var health_regen: float = 0.0
## Шанс иммунитета к status-эффектам (0.0-0.8, default 0).
@export_range(0.0, 0.8) var tenacity: float = 0.0

# === Тир и стоимость (для магазина) ===
@export var tier: int = 1
@export var cost: int = 1

# === Способности ===
@export var abilities: Array[Resource] = []  # AbilityDef[]

# Мета.
@export_multiline var description: String = ""