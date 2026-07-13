# AGENTS.md — Project Context for AI Agents

> Этот файл — single source of truth для AI-ассистентов (Claude, Cursor, Copilot, Continue).
> Прочитай перед тем как предлагать код. Код, нарушающий правила ниже, будет отклонён в ревью.

## Проект

**Rogue AutoBattler** — roguelike RPG автобаттлер на Godot 4.7.
- Working directory: `C:\Users\user\Documents\GodotProjects\RogueAutoBattler`
- Язык: GDScript 2.0 (статически типизированный где возможно)
- Лицензия цели: ранний доступ в Steam (коммерческая)
- Разработчик: solo, 6-12 месяцев

**Текущее состояние**: 53 .gd файла, 98/98 тестов проходят, играбельный прототип (warrior + archer vs goblin, есть магазин, способности, статусы, экономика, прогрессия, **13 характеристик на юните: crit/dodge/lifesteal/thorns/mana/cdr/tenacity/regen/armor/healing_received/shield_strength/magic_pen**).

## Критические правила (НЕ нарушать)

### Decision tree: class_name vs preload

```
Я хочу ссылаться на X из другого файла.
│
├─ X в core/utils/, core/data/, core/effects/effect.gd?
│  └─ class_name X  (GameBus, GameLog, Rng, UnitDef, Effect, ...)
│     └─ Ссылаюсь: `X.method()` (в editor-mode работает стабильно)
│
├─ X в core/battle/, core/abilities/, core/ai/, core/progression/?
│  └─ class_name X  (но не цитируй через class_name в extends!)
│     └─ Ссылаюсь ТОЛЬКО через const preload:
│        const XScript = preload("res://path/x.gd")
│        var x = XScript.new()
│
└─ X extends Y (наследование)?
   └─ `extends "res://path/y.gd"`  (НЕ через class_name!)
      Пример: damage_effect.gd extends "res://core/effects/effect.gd"
      Причина: цикл загрузки при parse в --headless --script режиме
```

### Запрещено

| ❌ Не делай | Почему |
|---|---|
| `extends SomeClassName` (через class_name) | class_name может не зарезолвиться при парсинге → parse error. Используй `extends "res://path/script.gd"` |
| `ClassName.method()` (через class_name в коде) между core/* файлами | Тот же риск. Используй `const X = preload()` + `X.method()` |
| `EventBus.signal.emit(...)` в core/* файлах | core/* не знает про autoload instance. Используй `GameBus.emit_xxx()` static helpers в `core/utils/event_bus.gd` |
| `Logger.info(...)` | Переименовано. Используй `GameLog.info(...)` (class_name `Log` → `GameLog`) |
| `RngService.randf()` | Переименовано. Используй `Rng.randf()` (class_name `Rng`) |
| `SaveManager.save_resource(...)` | Переименовано. Используй `SaveSvc.save_resource(...)` |
| `ContentDB.get_by_id(...)` | Переименовано. Используй `ContentDB_static.get_by_id(...)` |
| `randf()`, `randi()`, `randf_range()` напрямую | Нарушает детерминизм. Используй `Rng.*` |
| `print()`, `printerr()`, `push_error()` в core/* | Используй `GameLog.*` |
| Magic numbers в логике (5, 10, 1.0, 0.1, 7, 4) | Все числа баланса в `core/balance.gd` |
| `var x: Resource = RefCountedClass.new()` | RefCounted не Resource. Используй `var x = RefCountedClass.new()` |
| `var x: int = null` (смешивание типов) | Используй Variant: `var x = null` |
| `c.current_hp` (как property) | Это метод: `c.health.current_hp` (поле в HealthComponent) |
| `c.defense` (как property) | Это метод: `c.defense()` (даёт модифицированное значение) |
| `.tres` файлы с `script_class` ссылками на не-зарегистрированные class_name | Приводит к ошибке load. Используй `script = ExtResource("path/to/script.gd")` и `id` поле |

### Обязательно

| ✅ Делай | Пример |
|---|---|
| Const-preload для cross-file ссылок | `const GridScript = preload("res://core/battle/grid.gd")` |
| `class_name` для типов, доступных через Editor Inspector | `class_name UnitDef extends Resource` |
| Типизированные переменные | `var hp: int = 100`, `var arr: Array[Resource] = []` |
| Docstring на каждом public методе | `## Краткое описание (1 строка).` |
| Single source of truth для баланса | Константы в `core/balance.gd`, используй `BalanceScript.STARTING_GOLD` |
| Расширяемость через композицию | Новый статус = новый `StatusDef` + `ApplyStatusEffect`, без правки `Combatant` |
| Event-driven через GameBus | `GameBus.emit_unit_died(self)` в core, `EventBus.unit_died.connect(...)` в scene |
| Round-trip строки | `int(some_string)` в `.to_dict()` сериализации (строки восстанавливаются как строки) |

## Структура проекта

```
C:\Users\user\Documents\GodotProjects\RogueAutoBattler\
├── project.godot              # autoload: EventBus (event_bus_autoload.gd)
├── ARCHITECTURE.md            # Полный дизайн-док (человеко-ориентированный)
├── AGENTS.md                  # Этот файл (AI-ориентированный)
├── README.md
├── icon.svg
│
├── core/                      # Чистая логика, без нод
│   ├── balance.gd             # class_name Balance. Все числа баланса.
│   │
│   ├── utils/                 # 5 утилит + 5 autoload-обёрток
│   │   ├── event_bus.gd       # class_name GameBus extends Node. Signals + static helpers.
│   │   ├── event_bus_autoload.gd  # autoload "EventBus", extends event_bus.gd
│   │   ├── logger.gd          # class_name GameLog
│   │   ├── rng_service.gd     # class_name Rng
│   │   ├── content_db.gd      # class_name ContentDB_static
│   │   └── save_manager.gd    # class_name SaveSvc
│   │
│   ├── data/                  # Resource-классы данных (UnitDef, AbilityDef, StatusDef, ...)
│   │
│   ├── effects/               # Effect (base) + 7 наследников
│   │   ├── effect.gd          # class_name Effect extends Resource. Базовый класс.
│   │   ├── damage_effect.gd   # extends "res://core/effects/effect.gd" (НЕ через class_name!)
│   │   ├── heal_effect.gd
│   │   ├── apply_status_effect.gd
│   │   ├── shield_effect.gd
│   │   ├── dispel_effect.gd
│   │   ├── move_effect.gd
│   │   └── summon_effect.gd
│   │
│   ├── abilities/             # TargetingResolver (8 типов), AbilityResolver
│   │
│   ├── battle/                # Grid, Combatant, components, BattleContext, BattleRunner
│   │   ├── grid.gd
│   │   ├── combatant.gd       # Thin wrapper: делегирует к HealthComponent, ManaComponent, ...
│   │   ├── health_component.gd
│   │   ├── mana_component.gd   # v3: mana + regen
│   │   ├── regen_component.gd  # v3: HP regen
│   │   ├── status_list.gd
│   │   ├── cooldown_list.gd
│   │   ├── attack_meter.gd
│   │   ├── battle_context.gd
│   │   ├── battle_runner.gd
│   │   └── battle_state.gd
│   │
│   ├── ai/                    # AiController (base), DefaultAi
│   │
│   ├── progression/           # RunState, MetaProfile, UnlockManager, RunController
│   │
│   ├── economy/               # Shop
│   │
│   └── save/                  # SaveService
│
├── content/                   # .tres — данные (4 юнита, 2 способности, 2 статуса, 1 враг)
│
├── scenes/                    # main, battle_scene, battle_view
│
├── assets/                    # Спрайты (пока пусто — процедурная отрисовка)
│
└── tests/
    └── run_tests.gd           # 58 тестов, SceneTree pattern
```

## Команды

### Запуск тестов (ОБЯЗАТЕЛЬНО после изменений)

```bash
cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler"
/tmp/godot47.exe --headless --path . --script tests/run_tests.gd
```

Ожидаемый результат: `=== Result: 98 passed, 0 failed ===`
Если упало — **не коммить, не помечай как готовое**. Чини сначала.

### Проверка парсинга в editor-mode

```bash
cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler"
/tmp/godot47.exe --headless --editor --quit
```

Проверяет, что class_name зарегистрированы и нет циклических зависимостей. Запускай после:
- Изменения `class_name X` в любом файле
- Изменения `extends X` через class_name
- Добавления нового autoload

### Запуск игры (визуальный)

```bash
# Скопировать Godot в /tmp если ещё не
cp "D:/Programms/Max/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64.exe" /tmp/godot47.exe
/tmp/godot47.exe --path "C:/Users/user/Documents/GodotProjects/RogueAutoBattler"
# В редакторе F5 для запуска main.tscn
```

## Соглашения по коду

### GDScript стиль

```gdscript
class_name MyClass extends "res://path/to/parent.gd"
## Краткое описание класса (1 строка).
##
## Подробности если нужны (до 5 строк).

# === Константы ===
const MY_CONST: int = 42  # комментарий обязателен для нетривиальных значений

# === Зависимости через preload ===
const OtherScript = preload("res://path/other.gd")
const BalanceScript = preload("res://core/balance.gd")

# === Поля с типизацией ===
var hp: int = 100                  # var: type = default
var abilities: Array[Resource] = [] # typed arrays
var ai_controller = null           # Variant если тип сложный
var _private_field: int = 0        # _ префикс для internal

# === Методы ===
## Короткое описание что делает.
## Подробности если есть.
## Возвращает что.
func some_method(arg: int) -> int:
    if arg < 0:
        GameLog.warn("module", "negative arg", {"arg": arg})
        return 0
    return arg * 2
```

### Именование

- `class_name` → `PascalCase` (UnitDef, HealthComponent)
- Файлы → `snake_case` (unit_def.gd, health_component.gd)
- Функции/переменные → `snake_case` (take_damage, current_hp)
- Private → `_` префикс (`_private_field`, `_init`)
- Константы → `UPPER_SNAKE_CASE` (`STARTING_GOLD`, `GRID_WIDTH`)
- Сигналы → прошедшее время (`unit_died`, `battle_started`)

### Структура файла

```gdscript
class_name X extends "res://path/y.gd"    # 1. declaration
##                                     # 2. docstring
const A = preload("...")                # 3. const
const B = 42                            # 4. literal const
var field: int = 0                      # 5. public fields
var _private: int = 0                   # 6. private fields
# === Section ===                       # 7. sections
func method_a() -> void:                # 8. public methods
func _helper() -> void:                 # 9. private methods
```

## Архитектурные паттерны

### 1. Композиция через компоненты

Combatant — это **thin wrapper** с 4 компонентами:
- `health: HealthComponent` — HP + shield
- `statuses: StatusList` — DOT/HOT/баффы/дебаффы
- `cooldowns: CooldownList` — кулдауны способностей
- `attack_meter: AttackMeter` — accumulator для автоатак

**Новый компонент** = новый файл + поле в Combatant + делегирующие методы.

### 2. Effects как композиция

`AbilityDef.effects: Array[Effect]` — каждый эффект это:
- `DamageEffect` (урон)
- `HealEffect` (хил)
- `ApplyStatusEffect` (DOT/бафф/дебафф)
- `ShieldEffect` (временный щит)
- `DispelEffect` (снятие статусов)
- `MoveEffect` (телепорт)
- `SummonEffect` (спавн юнита)

**Новый эффект** = `core/effects/my_effect.gd` extends `"res://core/effects/effect.gd"`.

### 3. Targeting types

8 типов: `SINGLE_ENEMY`, `SINGLE_ALLY`, `AOE_CIRCLE`, `AOE_LINE`, `AOE_CONE`, `SELF`, `RANDOM_ENEMY`, `ALL_ENEMIES`, `ALL_ALLIES`.
Константы в `core/data/targeting.gd`. **Не добавляй новые типы без рефакторинга TargetingResolver.**

### 4. Event-driven через GameBus

- core/* файлы вызывают `GameBus.emit_xxx(args)` (static helpers)
- scene/* файлы подписываются через autoload `EventBus.signal.connect(...)`
- **core/ НЕ подписывается на EventBus** — это ответственность scene/

### 5. Single source of truth для баланса

Все числа баланса в `core/balance.gd`:
- `STARTING_GOLD`, `STARTING_LIVES`, `STARTING_UNIT_IDS`
- `WIN_BONUS_GOLD`, `WIN_BONUS_PER_ROUND`
- `GRID_WIDTH`, `GRID_HEIGHT`
- `DEFAULT_TICK_DT`, `MIN_ATTACK_SPEED`
- `ARMOR_WEIGHT` (0.5) — flat armor слабее процентной защиты
- `ENEMY_COUNT_BY_ROUND` + `enemy_count_for_round(round_index)`
- `compute_attack(...)` — расширенная формула (crit, dodge, armor, magic_pen)
- `compute_damage(...)` — старая упрощённая формула (только defense)
- `apply_cdr(base, cdr)` — уменьшение кулдауна
- `apply_healing_received(base, mult)` — модификатор хила
- `apply_shield_strength(base, mult)` — модификатор щита
- `attack_interval(attack_speed)` — формула скорости атаки

**НЕ дублируй** эти числа в других местах.

### 6. Характеристики юнитов (v3)

13 характеристик, определённых в `UnitDef` и копируемых в `Combatant._init`:

| Группа | Характеристика | Где применяется |
|---|---|---|
| Базовые | `attack`, `defense`, `magic_power`, `magic_resist` | формулы урона |
| Базовые | `attack_speed`, `move_speed` | `attack_meter.is_ready`, `move_speed()` |
| Базовые | `attack_range`, `sight_range` | AI таргетинг |
| Базовые | `max_hp` | `health.configure` |
| Crit | `crit_chance`, `crit_damage` | `Balance.compute_attack` |
| Defensive | `dodge`, `armor`, `healing_received`, `shield_strength` | `Balance.compute_attack`, `heal()`, `add_shield()` |
| Offense | `lifesteal`, `thorns`, `magic_pen` | `basic_attack`, `take_damage`, `Balance.compute_attack` |
| Mana | `max_mana`, `mana_regen`, `cdr` | `mana.spend`, `put_on_cooldown` |
| Regen | `health_regen`, `tenacity` | `regen.tick`, `apply_status` |

**Combatant хранит их как поля** (не методы), потому что они не меняются в runtime.
**Методы** (`attack()`, `defense()`) применяют модификаторы от статусов на базовые значения.

## Чего НЕ делать (для AI)

- ❌ Не рефактори Combatant в god-object. Он thin wrapper, не трогай без нужды.
- ❌ Не добавляй новые Effect-классы без примера использования в `content/effects/instances/`.
- ❌ Не используй `randf()` / `randi()` напрямую — только через `Rng.*`.
- ❌ Не подписывайся на `EventBus` сигналы из core/* файлов.
- ❌ Не добавляй magic numbers. Если нужна константа — добавь в `core/balance.gd`.
- ❌ Не пиши код без теста. Перед новой фичей — напиши тест со скелетом.
- ❌ Не помечай задачу как "готово" пока `58 passed, 0 failed` не подтверждено.
- ❌ Не используй `class_name` в файлах, которые extends'ятся другими через class_name — используй `extends "res://path"` чтобы избежать циклов загрузки.

## Процесс для AI-агента

1. **Перед написанием кода**: прочитай `ARCHITECTURE.md` (общий дизайн) + соответствующий `core/<module>/` файл.
2. **Сначала тест**: добавь `_test_xxx()` в `tests/run_tests.gd` со скелетом. Запусти — должен упасть.
3. **Потом код**: реализуй минимум, чтобы тест прошёл.
4. **Запусти все тесты**: должен быть `58+X passed, 0 failed` где X — число новых тестов.
5. **Прогон editor-mode**: `/tmp/godot47.exe --headless --editor --quit` — никаких parse errors.
6. **Обнови `ARCHITECTURE.md`**: если добавил новый модуль/компонент/паттерн.

## Если что-то не работает

- Тесты падают с "Could not preload resource script" → class_name не зарегистрирован. Запусти editor-mode для индексации.
- Тесты падают с "Nonexistent function 'new' in base 'GDScript'" → const-preload = null. Проверь что путь правильный.
- Тесты падают с "Invalid operands 'Callable' and 'int'" → использовал метод как property. Добавь скобки `()`.
- Parse error в editor-mode → открой файл в Godot редакторе и посмотри номер строки.
- main.tscn падает с "No units on board" → `STARTING_UNIT_IDS` пустой или юниты не в `content/units/`.

## Контакт

Если LLM нужен контекст, которого нет здесь:
- `ARCHITECTURE.md` — полный дизайн-док (vision, roadmap, скоуп)
- `core/balance.gd` — все числа баланса
- `tests/run_tests.gd` — 58 примеров как тестировать
- Запусти `find . -name "*.gd" -not -path "./.godot/*" | xargs wc -l` — посмотреть размер codebase
