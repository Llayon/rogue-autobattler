class_name Effect extends Resource
## Базовый класс эффекта. Эффект — переиспользуемый кусок логики,
## который применяется к одной или нескольким целям в BattleContext.
##
## Все конкретные эффекты (Damage, Heal, ApplyStatus, ...) наследуют этот
## класс и реализуют метод apply().
##
## Конвенция: данные эффекта хранятся как @export поля на .tres.
## Логика применяется в apply() — она получает BattleContext и список целей.
##
## Чтобы добавить новый эффект:
##   1. Создай core/effects/my_effect.gd, extends Effect.
##   2. Реализуй apply().
##   3. Создай .tres в content/effects/ с параметрами.
##   4. Ссылайся на него из AbilityDef.effects.

## Категория эффекта (для фильтрации/UI). см. core/data/effect_kind.gd.
@export var kind: int = EffectKind.CUSTOM


## Применяет эффект к целям.
## ctx: BattleContext — текущее состояние боя (см. core/battle/battle_context.gd).
## source: Combatant — кто применяет (кастер/предмет/статус).
## targets: Array — список целей (уже отфильтрованный по таргетингу).
##
## Должен вернуть массив результатов (каждый результат — Dictionary,
## описывающий что произошло: {target, applied: bool, ...}).
func apply(ctx, source, targets: Array) -> Array:
	GameLog.warn("effects", "Effect.apply() not implemented", {"kind": kind})
	return []


## Удобный хелпер: возвращает true, если эффект применим хотя бы к одной цели.
func has_valid_targets(targets: Array) -> bool:
	return targets != null and not targets.is_empty()