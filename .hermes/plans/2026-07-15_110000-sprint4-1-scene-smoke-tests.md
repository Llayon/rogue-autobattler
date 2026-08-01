# Sprint 4.1: End-to-end smoke tests для scene/* файлов

> **For Hermes:** TDD на каждый тест. Урок из memory: scene/* файлы (особенно
> `_draw()` методы) могут сломаться незаметно от unit-тестов. Headless runner
> не вызывает `_draw()` сам, поэтому визуальные баги (как `c.current_hp` → `c.health.current_hp`)
> проскакивают. Этот спринт — страховка перед UI-работой (S4.2, S4.3).

**Goal:** Smoke tests, которые проверяют что scene/* файлы (a) парсятся, (b) инстанцируются,
(c) правильно подписываются на EventBus, (d) имеют корректные ссылки на core/* классы.

**Architecture:**
- Все тесты в `tests/run_tests.gd` — расширяем существующий pattern
- Используем `SceneTree.instantiate_scene(path)` для загрузки сцен (как у Game делал бы)
- Проверяем что scene scripts extends правильный базовый класс (Control, Node)
- Проверяем что сигналы корректно подключены (без реального рендера)

**Tech Stack:** GDScript 2.0, Godot 4.7, SceneTree-based tests.

---

## Контекст (что есть в scenes/)

| Файл | Базовый класс | Что делает | Покрыт тестами? |
|---|---|---|---|
| `scenes/main.gd` | Node | Грузит BattleScene | ❌ |
| `scenes/main.tscn` | (root node Main) | Контейнер для battle scene | ❌ |
| `scenes/battle/battle_scene.gd` | Control | Управляет RunController + BattleView + HUD label | ❌ |
| `scenes/battle/battle_view.gd` | Control | Процедурный `_draw()` сетка + юниты | ❌ |
| `scenes/battle/battle_scene.tscn` | (root node BattleScene) | Контейнер | ❌ |

**Реальные баги которые могут быть пропущены:**
- `extends Control` потерян → crash на `queue_redraw()` в `_ready()` (Godot 4.5+ требует Control для `_draw`)
- EventBus autoload не зарегистрирован → runtime null pointer
- BattleView._draw() обращается к несуществующему полю Combatant (урок S2)

---

## Архитектурные решения

### D1: Что тестировать в headless?

**Выбор:** Smoke tests которые проверяют:
1. Файл парсится (нет syntax error)
2. Класс extends правильный базовый тип
3. Конкретные методы/поля существуют (через `.has_method()`, `.get()`)
4. После `add_child` нет crash (try-add-and-see)

**Почему:**
- Реальный `_draw()` не вызывается в headless — это OK, тестируем contract, не pixels
- `instantiate_scene(path)` создаёт Control в headless, можно дёргать публичные методы

### D2: Не тестируем UI pixels

**Выбор:** Smoke tests НЕ проверяют:
- Точные координаты отрисовки
- Цвета/размеры
- Font rendering

**Почему:**
- Это integration territory, требует display server (не headless)
- Такие тесты flaky и медленные
- Лучше: end-to-end через render screenshot вручную (или в CI с xvfb)

### D3: Изоляция EventBus в тестах

**Выбор:** Каждый scene test создаёт свой изолированный EventBus если autoload отсутствует.

**Почему:**
- Сейчас в `_initialize()` test runner нет autoload bootstrap (см. AGENTS.md)
- `_find_event_bus()` уже есть в `battle_scene.gd` — он возвращает null если нет
- Тест просто проверяет что при отсутствии bus сцена не падает

---

## Step-by-Step Plan

### Task 1: SceneScript прелоады + scene test helpers

**Files:**
- Modify: `tests/run_tests.gd`

**Step 1:** Добавить preload константы:
```gdscript
const MainSceneScript = preload("res://scenes/main.gd")
const BattleSceneScript = preload("res://scenes/battle/battle_scene.gd")
const BattleViewScript = preload("res://scenes/battle/battle_view.gd")
```

**Step 2:** Helper для инстанцирования сцены в headless:
```gdscript
func _instantiate_scene(packed_path: String) -> Node:
    var packed: PackedScene = load(packed_path) as PackedScene
    if packed == null:
        return null
    return packed.instantiate()
```

---

### Task 2: Scene smoke tests

**Files:**
- Modify: `tests/run_tests.gd`

**Step 1:** Тест — main.gd extends Node, парсится:
```gdscript
func _test_main_scene_parses() -> void:
    print("[test] S4.1: main.gd extends Node и парсится")
    var script: GDScript = MainSceneScript as GDScript
    _assert(script != null, "main.gd загружается как GDScript")
    _assert(script.get_base_script() != null or script.get_instance_base_type() == "Node",
        "main.gd extends Node (got base type)")
    var inst: Node = MainSceneScript.new()
    _assert(inst != null, "main.gd.new() инстанцируется")
    _assert(inst is Node, "instance это Node")
    inst.free()
```

**Step 2:** Тест — battle_scene.gd extends Control:
```gdscript
func _test_battle_scene_extends_control() -> void:
    print("[test] S4.1: battle_scene.gd extends Control")
    var inst: Node = BattleSceneScript.new()
    _assert(inst is Control, "battle_scene это Control (для _draw/queue_redraw)")
    _assert(inst.has_method("_ready"), "_ready() определён")
    inst.free()
```

**Step 3:** Тест — battle_scene.gd подписывается на EventBus без crash:
```gdscript
func _test_battle_scene_eventbus_subscribe_no_crash() -> void:
    print("[test] S4.1: BattleScene add_child без EventBus не падает")
    var scene: Control = BattleSceneScript.new()
    get_root().add_child.call_deferred(scene)
    await process_frame
    _assert(is_instance_valid(scene), "scene жив после add_child")
    _assert(scene.run_controller != null, "run_controller создан в _ready()")
    _assert(scene.battle_view != null, "battle_view создан в _ready()")
    _assert(scene.status_label != null, "status_label создан в _ready()")
    scene.queue_free()
    await process_frame
```

**Step 4:** Тест — BattleView.set_context не падает без grid:
```gdscript
func _test_battle_view_set_context_safe() -> void:
    print("[test] S4.1: BattleView.set_context() + queue_redraw() без crash")
    var view: Control = BattleViewScript.new()
    _assert(view is Control, "BattleView extends Control")
    _assert(view.has_method("set_context"), "set_context() существует")
    _assert(view.has_method("_draw"), "_draw() существует (визуализатор)")
    view.set_context(null)  # null-safe не должно падать
    _assert(view._ctx == null, "ctx = null после set_context(null)")
    view.free()
```

**Step 5:** Тест — BattleScene с реальным BattleContext (smoke end-to-end):
```gdscript
func _test_battle_view_with_real_context() -> void:
    print("[test] S4.1: BattleView.set_context(real) + _draw() smoke (не падает)")
    var ctx_script = preload("res://core/battle/battle_context.gd")
    var grid_script = preload("res://core/battle/grid.gd")
    var ctx = ctx_script.new()
    var g = grid_script.new()
    g.resize(7, 4)
    ctx.grid = g
    var view: Control = BattleViewScript.new()
    view.set_context(ctx)
    view.queue_redraw()
    # В headless _draw() не вызывается автоматически — но set_context не должен упасть.
    _assert(view._ctx == ctx, "ctx сохранён в view")
    view.free()
```

**Step 6:** Зарегистрировать в `_initialize()`:
```gdscript
# S4.1: scene smoke tests
_test_main_scene_parses()
_test_battle_scene_extends_control()
_test_battle_scene_eventbus_subscribe_no_crash()
_test_battle_view_set_context_safe()
_test_battle_view_with_real_context()
```

**Step 7:** Прогнать — должно быть 188+ passed.

**Step 8:** Commit: `test(s4.1): scene smoke tests для main, battle_scene, battle_view`

---

### Task 3: Verify через visual smoke (запустить main.tscn в headless)

**Files:** ничего.

**Step 1:** `godot47 --headless --path . --quit-after 5` — что main.tscn грузится без crash.
```bash
/tmp/godot47.exe --headless --path . --quit-after 30
```

**Step 2:** Проверить что нет critical errors в выводе.

**Step 3:** Финальный commit (если есть правки).

---

## Файлы изменяются

| Файл | Тип | Строк |
|---|---|---|
| `tests/run_tests.gd` | modify | +100 (5 тестов + helpers) |

**Итого:** ~100 строк, 0 новых классов.

---

## Тесты / Валидация

### Прогон после Task 2
```bash
cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler"
/tmp/godot47.exe --headless --script tests/run_tests.gd
```

**Ожидаемая динамика:**
- Task 2: 188/188 (+5 новых тестов)

### Editor-mode check
```bash
/tmp/godot47.exe --headless --editor --quit
```

### Visual smoke
```bash
/tmp/godot47.exe --headless --path . --quit-after 30
```

---

## Риски

| Риск | Митигация |
|---|---|
| R1: `instantiate_scene` падает если .tscn битый | Тест сначала парсит, потом инстанцирует — два уровня проверки |
| R2: BattleScene._ready() дёргает `start_run(42)` — может писать в user:// | Это OK, но profile файл может появиться на диске. Cleanup не критичен |
| R3: EventBus autoload отсутствует в тестах → `_find_event_bus()` returns null | BattleScene уже обрабатывает это (условие `if _bus != null`) |
| R4: queue_redraw() в headless no-op | Это OK, не падает |

---

## Handoff

После S4.1:
- 188/188 тестов зелёные
- 1 коммит (или 2 если визуальный smoke найдёт проблему)
- Scene/* покрыт smoke-тестами
- Безопасная база для S4.2 (Battle UI) и S4.3 (Visual feedback)
