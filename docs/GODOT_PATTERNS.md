# Godot-Specific Patterns & Guards

> Этот документ описывает архитектурные принципы **специфичные для Godot 4.7 + GDScript**,
> а не адаптацию Bevy-паттернов. Несколько перенесённых принципов из Bevy "Absolute Zenith"
> остаются валидными (determinism, decoupling, type-driven design), но многие Godot-native
> концепции требуют своих собственных гвардейцев.

## Ключевые отличия Godot от Bevy ECS

| Bevy ECS | Godot 4 |
|---|---|
| `Entity` + `Component` | `Node` (tree-based) + `RefCounted` (transient) |
| `System` (fn(Entity, Components)) | `Node._process(delta)` / `Node._ready()` |
| `Resource` (global state) | autoload (Node-based) + `Resource` (data) |
| `SystemSet` (orchestration) | Group в editor + parent/child tree |
| `Query<T>` | Typed arrays (`Array[Combatant]`) + filters |
| `Commands` (deferred mutations) | `call_deferred()` + `Node.queue_free()` |
| `Observers` (reactive) | `Signal` (built-in event system) |
| `States` (FSM) | `enum` + manual transitions в `RunController` |
| `Schedule` (Update / FixedUpdate) | `_process(delta)` + `_physics_process(delta)` |
| `Component::on_add` hook | `Node._enter_tree()` + `Node._ready()` |
| `Plugin` (модульность) | `extends Node` autoload + scene script |
| `Run conditions` | `if get_tree() != null and state == X` |

**Главное отличие**: Bevy — **data-driven ECS**, Godot — **tree-based сцена**. В Bevy
логика отделена от lifecycle (системы stateless). В Godot lifecycle привязан к Node
tree (`_ready`, `_process`, `_exit_tree`), что даёт другие гарантии и другие проблемы.

---

## Принципы для Godot (не copy-paste из Bevy)

### GP-1: Scene-тесты обязательны для scene/* файлов

**Проблема:** `headless --script` НЕ вызывает `_draw()` или `_process()` scene/* файлов.
Unit-тесты на core/* не ловят визуальные баги (как `c.current_hp` → `c.health.current_hp`
после refactor).

**Правило:** Для каждого `scenes/*/*.gd` файла должен быть **минимум 1 smoke-тест** в
`tests/run_tests.gd` который:
- Инстанцирует scene через `_instantiate_scene(path)` или `extends_class.new()`
- Проверяет что `extends Control` / `extends Node` правильный базовый тип
- Проверяет наличие публичных методов которые дёргаются в `_process`/`_draw`
- Проверяет что `add_child` не падает

**Реализация:** S4.1 — `tools/lint_anti_patterns.py` пока не enforced, но
`tests/run_tests.gd` имеет секцию "S4.1 scene smoke tests".

### GP-2: Pair-pattern для autoload — `class_name` + `extends Node` wrapper

**Проблема:** В Bevy `Resource` — глобальный singleton. В Godot autoload — это Node,
который требует instance. Но core/* не должен зависеть от `Node`-instance (нарушает
headless testability).

**Правило:** Каждый autoload паттерн = **pair из двух файлов**:

```gdscript
# core/utils/event_bus.gd (НЕ autoload)
class_name GameBus extends Node
signal unit_died(...)
static func emit_unit_died(...) -> void:
    var inst = _instance()
    if inst != null:
        inst.unit_died.emit(...)
```

```gdscript
# core/utils/event_bus_autoload.gd (autoload instance)
extends "res://core/utils/event_bus.gd"
# Ничего не нужно — наследует всё от GameBus.
```

**Правило:** Использовать `GameBus.emit_unit_died(...)` в core/* (статический helper),
использовать `EventBus.unit_died.connect(...)` в scene/* (autoload instance).

**Реализация:** В нашем проекте — ✅ `EventBus`, `RngService`, `SaveManager`, `Logger`,
`ContentDB` все используют pair-pattern. `lint_anti_patterns.py:event-bus-direct-emit`
ловит ошибки когда кто-то пытается звать `EventBus.signal.emit()` из core.

### GP-3: `extends "res://path"` для cross-file inheritance

**Проблема:** В Bevy — обычный `impl Trait for Struct`. В Godot `extends` через `class_name`
**ломается в headless** (parse error если class_name ещё не зарегистрирован). Это
документировано в AGENTS.md, но lint может поймать ошибки.

**Правило:**
- Файл с `class_name X` **никогда** не extends другой через `class_name`
- Cross-file inheritance ТОЛЬКО через строковый путь: `extends "res://core/path/Y.gd"`
- Local same-file extends — можно через `class_name`

**Пример (правильно):**
```gdscript
# core/effects/damage_effect.gd
class_name DamageEffect extends "res://core/effects/effect.gd"  # НЕ class_name!

# core/effects/cleave_effect.gd
class_name CleaveEffect extends "res://core/effects/effect.gd"  # string path OK
```

**Пример (НЕПРАВИЛЬНО):**
```gdscript
# ОШИБКА: parse error в headless
class_name CleaveEffect extends Effect
```

**Реализация:** `lint_anti_patterns.py` — добавить rule `cross-file-extends-must-be-string`.

### GP-4: `preload()` для cross-file references внутри core

**Проблема:** `Combatant` хочет ссылаться на `HealthComponent` (другой core/* файл).
Использовать `HealthComponent.new()` через class_name работает, но **ломается в headless**
(class_name не зарегистрирован). AGENTS.md это документирует, но не enforced.

**Правило:** Внутри core/* файлов использовать:
```gdscript
const HealthComponentScript = preload("res://core/battle/health_component.gd")
var health = HealthComponentScript.new()
```

**Исключение:** `Rng`, `GameBus`, `GameLog` — autoload-registered class_name, можно
`Rng.randf()` напрямую.

**Реализация:** Code review (manual пока).

### GP-5: Typed arrays, не Variant

**Проблема:** Bevy имеет type-safe query `Query<&mut T>`. В Godot массивы Variant
по умолчанию, что даёт runtime errors.

**Правило:**
- `Array[Combatant]`, `Array[StringName]`, `Array[int]` — всегда typed
- `Array` (untyped) — только для generic containers с разными типами
- `@export var arr: Array[Resource] = []` — для inspector exposure

**Реализация:** В нашем проекте — ✅ `Array[StringName]`, `Array[int]`, `Array[Resource]`.

### GP-6: Сигналы — не для cross-thread, только для UI/coupling

**Проблема:** Bevy `Events` — channel-based, может cross thread. Godot signals —
синхронные, всегда main thread. Если emit из worker thread — undefined behavior.

**Правило:** Сигналы звать **только из main thread**. Если worker thread (например
`Thread.new().start()`) нужно emit signal — использовать `call_deferred("emit_signal", ...)`.

**Реализация:** Пока нет в нашем проекте (нет threading). Когда добавим — lint rule.

### GP-7: RefCounted для core, Resource для data, Node только для scenes

**Проблема:** Bevy `Component` — данные, `Resource` — глобальное состояние. В Godot
три уровня:
- `RefCounted` — transient runtime objects (Combatant, BattleContext, Effect)
- `Resource` — persisted data (UnitDef, StatusDef, MetaProfile, AbilityDef)
- `Node` — scene tree only (BattleScene, BattleView, Main)

**Правило:**
- `core/*.gd` = `extends RefCounted` (logic) или `extends Resource` (data)
- `core/*.gd` НИКОГДА не `extends Node` (это для scenes)
- `scenes/*.gd` = `extends Control`/`extends Node2D`/etc. (UI logic)

**Реализация:** AGENTS.md правило "Decision tree: class_name vs preload" + lint rule
`no-node-in-core`.

### GP-8: Lifecycle separation — `_ready` vs `_init`

**Проблема:** Bevy не имеет lifecycle. Godot имеет **три** уровня:
- `_init()` — конструктор (как `new()` в Bevy, но в GDScript — после class init)
- `_ready()` — после добавления в scene tree
- `_enter_tree()` / `_exit_tree()` — node добавляется/удаляется

**Правило для core/* (RefCounted):**
- Использовать `_init(def)` для setup (наш Combatant: `_init(def, hp_mul, atk_mul, def_mul)`)
- НЕ использовать `_ready` — RefCounted не имеет scene tree
- `_enter_tree` / `_exit_tree` — никогда в core

**Правило для scenes/* (Node):**
- `_ready()` — для UI setup (connect signals, get child nodes)
- `_process(delta)` — для UI updates каждый кадр
- `_unhandled_input(event)` — для keyboard/mouse
- `_enter_tree` / `_exit_tree` — для cleanup

**Реализация:** Code review (AGENTS.md документирует).

### GP-9: `queue_free()` для runtime cleanup, не `free()`

**Проблема:** Bevy имеет `Despawn`. Godot имеет `queue_free()` (deferred, safe) и
`free()` (immediate, dangerous — может crash если есть signals pending).

**Правило:** В core/* — `queue_free()` ТОЛЬКО для Node. Для RefCounted — просто обнулить
ссылку (auto-GC). В scene/* — `queue_free()` после `await timer.timeout`.

**Реализация:** Code review.

### GP-10: Save/Load через ResourceSaver/ResourceLoader, не custom

**Проблема:** Bevy имеет Bevy Assets с reflection. Godot имеет built-in
`ResourceSaver.save()` / `ResourceLoader.load()` с versioning.

**Правило:**
- `Resource` классы (`MetaProfile`, `RunState`) — `.tres` files, save через `ResourceSaver`
- Версионирование через `SAVE_VERSION: int` в каждом Resource
- Migration chain в `SaveSvc._migrate(from_version)`

**Реализация:** У нас есть ✅ `SaveService.save_meta/profile`, `SAVE_VERSION = 1` в
`MetaProfile` и `RunState`, миграция в `SaveSvc._migrate`.

---

## Что из Bevy **НЕ переносимо** в Godot (даже как inspiration)

### Bevy #6 — Все есть Plugin
В Bevy каждая фича = Plugin (модульная init). В Godot фичи — это комбинация
core/* класс + scene/* Node + autoload (если нужен). **Plugin-паттерн НЕ переносится** —
у Godot другая модель модулей (autoload, scene inheritance).

### Bevy #7 — Observers для reactive UI
В Bevy `Observer<T>` автоматически реагирует на component add/remove. В Godot —
`Signal` connected вручную через `_ready()`. Это **противоположная** модель:
Bevy reactive (push), Godot imperative (pull).

**Аналог:** Использовать `Signal.connect()` + `_on_*()` handlers, как у нас в
`BattleScene._ready()`.

### Bevy #8 — `States` для FSM
В Bevy `State<S>` — type-safe глобальный FSM. В Godot — `enum` + manual transition
в controller (как `RunController.Phase`). Это **работает**, но не имеет built-in guards.

**Аналог:** `RunController.Phase` enum (PREP/BATTLE/REWARD/GAMEOVER) с explicit
`phase_changed.emit(phase)` signal. Это уже сделано ✅.

### Bevy #15 — Query Filters
В Bevy `Query<&mut T, With<X>>` — filter на уровне системы. В Godot — typed arrays
`Array[T]` и `for x in arr where x.has_method(...)`.

**Аналог:** Использовать typed Array и filter в `for` loop. Уже сделано ✅ в
`EncounterMap` через `Array[EncounterNode]` typed.

### Bevy #17 — Safe Behavior Switcher
В Bevy `switch_behavior::<T>()` API. В Godot — manual `.add_child()` / `.remove_child()`
для Node, или добавление/удаление компонента в ECS-стиле.

**Аналог:** Если нужны "behavior states" в Godot — использовать `add_child(state_node)` /
`queue_free(state_node)`. У нас сейчас не используется.

### Bevy #18 — Asset Separation
В Bevy AssetPlugin отдельно от game logic. В Godot — `.tres` resources загружаются
через `ContentDB_static.get_by_id()`. У нас есть ✅.

### Bevy #19 — Decoupling
В Bevy `info!`/`warn!`/`error!` макросы. В Godot — `GameLog.info()` / `warn()` / `error()`.
У нас есть ✅, lint rule `no-direct-prints-in-core`.

### Bevy #24 — AsyncComputeTaskPool
В Bevy async через tasks. В Godot — `WorkerThreadPool` (но другая семантика) или
`Thread.new().start()` (manual). У нас нет async пока.

### Bevy #25 — Plugins 2.0
В Bevy `impl Command for MyCommand` для публичного API. В Godot — class methods
на `class_name`. У нас ✅.

### Bevy #26 — Named Commands
В Bevy — каждая команда имеет имя для debugging. В Godot — каждая функция имеет
имя по умолчанию. Не применимо.

### Bevy #27 — ЗАПРЕТ анонимных `.queue(|world|...)`
В Bevy `.queue(closure)` анонимный — плохо для профайлинга. В Godot — нет прямого
аналога (есть `call_deferred()` который всегда принимает method name).

---

## Что **уникально для Godot** (нет в Bevy)

### GP-U1: `.tres` resource files для контента
Godot позволяет редактировать данные в editor (UnitDef, StatusDef, AbilityDef —
`.tres` файлы с Inspector). Bevy требует Rust-код для каждого изменения.

**Принцип:** Content — `.tres`. Logic — `.gd`. Это разделение даёт hot-reload данных
без recompile.

### GP-U2: `_process(delta)` vs `_physics_process(delta)`
В Godot два цикла обновления:
- `_process(delta)` — variable FPS, для UI/input/animation
- `_physics_process(delta)` — fixed 60Hz, для физики и simulation

**Принцип:** Battle simulation — `_physics_process` (deterministic 60Hz). UI
animation — `_process`. Это **Godot-specific** best practice.

### GP-U3: Сигналы через `_ready` connect, не Bevy-style observers
В Godot каждый Node в `_ready()` делает `signal.connect(target.method)`. Bevy
observers declarative. У нас ✅ в `BattleScene._ready()` (hand-made connects).

### GP-U4: `set_anchors_preset(PRESET_*)` для UI responsive layout
Godot unique — UI растягивается через anchors (не layout вручную). Bevy UI
полностью programmatic.

**Принцип:** В scene/* файлах использовать `set_anchors_preset(Control.PRESET_FULL_RECT)`
и т.п. — НЕ абсолютные позиции. У нас ✅ в HUD bar (`PRESET_TOP_WIDE`).

### GP-U5: `EditorPlugin` для editor-only tools
Godot имеет `_tool` annotation для скриптов которые выполняются в editor (не
runtime). Bevy не имеет этого.

**Принцип:** Editor tools в `addons/` или `@tool` scripts. Не смешивать с runtime.

### GP-U6: `class_name` регистрация через `--editor --quit`
В Godot 4 `class_name` регистрируется ТОЛЬКО после `godot --editor --quit`. Без
этого `X.new()` через class_name падает в headless script. **Это уникально для Godot** —
Bevy не имеет двухфазной регистрации.

**Принцип:** После добавления нового `class_name` — ОБЯЗАТЕЛЬНО запустить
`/tmp/godot47.exe --headless --editor --quit` перед тестами. Документировано в
AGENTS.md "Команды" секция.

### GP-U7: HUD должен быть `Control` (не `Node`)
Godot 4.5+: `Node._draw()` НЕ существует. `_draw()` есть только на `CanvasItem`
(Control, Node2D, etc). Bevy не имеет этого разделения.

**Принцип:** UI в `scenes/*` ТОЛЬКО через `Control`. Это объясняет почему в `tools/lint_anti_patterns.py`:
правило `combatant-callable-as-field` для scenes/battle/battle_view.gd — потому что
он extends Control и должен иметь `_draw()`.

### GP-U8: `Resource.duplicate()` для cloning
Godot имеет built-in `Resource.duplicate()` (deep copy). Bevy — `#[derive(Clone)]`.

**Принцип:** Для `Resource` data (UnitDef, StatusDef) — `duplicate()` для создания
копий (например enemy_hp_multiplier). У нас ✅ в `RunController._spawn_enemy_wave()`.

### GP-U9: `EditorInterface` для runtime editor queries
Godot unique — можно из plugin читать scene state. Bevy — нет editor.

---

## Применимость Bevy гвардейцев к Godot (recap)

| # | Bevy guard | Godot переносимость | Аналог |
|---|---|---|---|
| #1 | Чистый main.rs | ✅ применимо | `scenes/main.gd` короткий |
| #2 | Группировка плагинов | ⚠️ частично | autoload `[]` array |
| #3 | DefaultPlugins | ✅ применимо | `project.godot` settings |
| #4 | Panic hook | ⚠️ N/A в GDScript | (нет panic в GD) |
| #5 | Conditional debug | ✅ применимо | `@tool` annotation |
| #6 | Все есть Plugin | ❌ НЕ применимо | другая модель модулей |
| #7 | Observers | ❌ НЕ применимо | Godot использует Signal |
| #8 | GameState | ✅ применимо (через enum) | `RunController.Phase` |
| #9 | Boolean state flags | ⚠️ частично | `visual_state["is_dying"]` (TODO: ZST) |
| #10 | Запрет World mut | ⚠️ частично | не трогать SceneTree из core |
| #11 | Marker Components (ZST) | ⚠️ частично | через `class_name Dying: pass` |
| #12 | Atomic через Bundles | ✅ применимо | `Bundle` нет, но pattern сохранён |
| #13 | System Sets | ⚠️ частично | scene tree grouping |
| #14 | Run Conditions | ✅ применимо | `if state == PREP` в core |
| #15 | Query Filters | ✅ применимо | typed Array |
| #16 | Asset Separation | ✅ применимо | ContentDB + Resource |
| #17 | Safe Behavior Switcher | ❌ НЕ применимо | нет аналога |
| #18 | Asset Creation | ❌ N/A | нет Mesh/Material в GD |
| #19 | Decoupling | ✅ применимо | `GameLog` + lint rule |
| #20 | No Hidden Globals | ✅ применимо | static class_name methods |
| #21 | Type-Driven Newtypes | ✅ применимо | typed enums/classes |
| #22 | Zero unwrap | ✅ применимо | `_assert` + lint |
| #23 | File Line Limit | ✅ применимо (новый lint rule) | предлагается |
| #24 | Clippy | ⚠️ частично | `lint_anti_patterns.py` (12 rules) |
| #25 | Clippy Style | ✅ применимо | editor formatter |
| #26 | Commit Standard | ✅ применимо | conventional commits hook |
| #27 | No Anonymous Queues | ❌ N/A в GD | (нет closure queue) |
| #28 | Reactive Markers | ✅ применимо | `Dying` ZST marker (TODO) |
| #29 | Simulation/Presentation split | ✅ применимо | `_physics_process` vs `_process` |

**Итого:**
- ✅ Полностью переносимо: **11** (#1, #3, #5, #8, #14, #15, #16, #19, #20, #21, #22, #25, #26)
- ⚠️ Частично / адаптация: **9** (#2, #4, #9, #10, #11, #12, #13, #23, #24, #28)
- ❌ Не применимо: **7** (#6, #7, #17, #18, #27, + ещё 2)
- ⏳ TODO в нашем проекте: **2** (#11 ZST migration, #23 file line limit)

---

## Что добавить в `tools/lint_anti_patterns.py` (Godot-specific rules)

| Rule ID | Что проверяет | Severity |
|---|---|---|
| `no-node-in-core` | core/*.gd не должен extends Node/Node2D/Control | error |
| `cross-file-extends-must-be-string` | `extends X` где X — class_name из другого файла | error |
| `file-line-count` | файл > 300 строк | warning |
| `typed-array-required` | `Array` без типа внутри core/* | warning |
| `no-queue-free-from-core` | `queue_free()` только в scene/* | error |
| `no-free-immediate` | `obj.free()` в scene/* (нужен queue_free) | error |
| `no-call-deferred-string` | `call_deferred("method", ...)` — нужен method reference | info |

---

## Резюме

Bevy "Absolute Zenith" был **архитектурным вдохновением**, но **не source of truth**.
Многие гвардейцы не переносятся напрямую, потому что Godot — другая парадигма
(tree-based scene vs data-driven ECS).

**Наш проект должен иметь свои Godot-native гвардейцы**, а не пытаться быть Bevy-копией.

**Что делаем:**
1. Этот документ — reference для будущих спринтов
2. S5.1.x: добавить Godot-specific lint rules (`no-node-in-core`, `cross-file-extends-must-be-string`)
3. S5.2+: мигрировать `visual_state` flag → ZST marker (#11)
4. Code review checklist: "Does this Godot-specific pattern make sense?"

## Источники

- **Bevy Absolute Zenith**: 29 guards from "Savage Fantasy" project
- **Godot 4 Documentation**: Scene tree, signals, autoloads
- **Internal AGENTS.md**: Проектные правила
- **`tools/lint_anti_patterns.py`**: 12 rules currently enforced
