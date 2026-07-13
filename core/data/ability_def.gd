class_name AbilityDef extends Resource
## Описание способности. .tres в content/abilities/.
##
## Способность — это набор эффектов с условием срабатывания и таргетингом.
## Хочешь "огненный шар с поджогом" = [DamageEffect, ApplyStatusEffect(BURN)].

@export var id: StringName = &""
@export var display_name: String = ""
@export var icon: Texture2D
@export_multiline var description: String = ""

# Баланс.
@export var cooldown: float = 5.0       # секунд между применениями
@export var mana_cost: int = 0          # 0 = нет маны в v1

# Таргетинг и прицеливание.
@export var targeting: int = 0          # см. core/data/targeting.gd
@export var range: int = 6              # максимальная дистанция до цели
@export var aoe_radius: int = 0         # радиус AOE (для circle/cone/line)
@export var aoe_width: int = 0          # ширина линии
@export var aoe_length: int = 0         # длина конуса/линии

# Эффекты, которые применяются к цели/целям при применении способности.
# Это массив Effect-инстансов (DamageEffect, HealEffect, ...).
@export var effects: Array[Resource] = []

# Опционально: условие триггера (on_hit, on_damage_taken, on_death).
# v1 — все способности активные и кастуются AI; триггерные оставим на v2.
@export var trigger: int = 0            # 0 = active cast