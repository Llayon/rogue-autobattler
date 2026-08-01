# Sprint 5.2: Encounter Map UI — Implementation Plan

> **For Hermes:** Execute task-by-task with strict RED → GREEN → commit. S5.2 is presentation and local selection only; `RunController` integration remains S5.3.

**Goal:** Добавить запускаемую Godot-сцену карты энкаунтеров: DAG из S5.1 визуализируется снизу вверх, доступные узлы кликабельны, выбор узла обновляет preview и эмитит типизированный сигнал.

**Architecture:** `EncounterMapView` — presentation-only `Control`: принимает `EncounterMap`, вычисляет responsive layout, рисует рёбра и создаёт `Button` на каждый узел. `EncounterMapScene` — тонкий preview/controller: генерирует карту по seed и применяет `choose_next()` после сигнала view. Core-классы S5.1 не меняются; S5.3 позже передаст реальную карту из `RunController`.

**Tech Stack:** Godot 4.7, GDScript 2.0, procedural `Control` UI, headless smoke tests, TDD.

---

## Контекст

| Компонент | Сейчас |
|---|---|
| `core/encounter/encounter_map.gd` | ✅ Генерирует детерминированный DAG, `get_all_nodes()`, `get_available_next_ids()`, `choose_next()` |
| `EncounterNode` | ✅ `id`, `type`, `depth`, parents/children, `visited` |
| `EncounterType` | ✅ display names и short labels |
| Encounter UI | ❌ отсутствует |
| `RunController` integration | ⏳ S5.3, не входит в этот спринт |
| Baseline | 243 assertions / 0 failed; lint 0 errors |

## Архитектурные решения

### D1 — View не меняет core state

**Выбор:** `EncounterMapView` проверяет доступность и эмитит `node_selected(node_id)`, но не вызывает `map.choose_next()`.

**Почему:** Presentation не должна владеть progression state. Это позволит S5.3 подключить `RunController`, а preview-сцена останется самостоятельным адаптером.

### D2 — Buttons поверх procedural edge drawing

**Выбор:** Рёбра рисуются в `_draw()`, узлы — настоящие `Button` children.

**Почему:** `Button` даёт keyboard focus, disabled state, tooltip и стандартный input без ручного hit-testing. Layout остаётся data-driven.

### D3 — Вертикальная карта снизу вверх

**Выбор:** depth 1 у нижнего края, boss depth 10 сверху; узлы одного слоя равномерно распределены по ширине.

**Почему:** Это соответствует визуальному языку Slay the Spire и помещает 10 слоёв в 1152×648 без обязательного scroll.

### D4 — Preview scene является исполняемым артефактом

**Выбор:** `EncounterMapScene` сама генерирует карту по exported seed, если реальная модель не передана.

**Почему:** S5.2 можно проверить и открыть отдельно до интеграции S5.3.

---

## Task 1 — Scene/view contract

**Files:**
- Create: `scenes/encounter/encounter_map_view.gd`
- Create: `scenes/encounter/encounter_map_scene.tscn`
- Test: `tests/run_tests.gd`

1. RED: runtime-load tests для отсутствующих script/scene; ожидается FAIL по отсутствующим ресурсам.
2. GREEN: создать `Control` script с `signal node_selected(node_id: int)`, `set_map()`, `get_map()` и `.tscn` root `Control`.
3. Verify: новые smoke assertions зелёные, full suite без regressions.
4. Commit: `feat(s5.2): add Encounter Map UI scene contract`.

## Task 2 — Responsive DAG layout and rendering state

**Files:**
- Modify: `scenes/encounter/encounter_map_view.gd`
- Modify: `tests/run_tests.gd`

1. RED: тест создаёт S5.1 map, вызывает `set_map()`, ожидает:
   - button count = map size;
   - position count = map size;
   - depth 10 визуально выше depth 1;
   - edge count > 0;
   - available ids enabled, locked ids disabled.
2. GREEN:
   - `_rebuild()` создаёт типизированные node buttons;
   - `_layout_nodes()` распределяет слои responsive;
   - `_draw()` рисует background, рёбра, header/legend;
   - цвета отражают locked / available / visited / current.
3. Verify full suite.
4. Commit: `feat(s5.2): render Encounter Map DAG with responsive node layout`.

## Task 3 — Selection signal and preview progression

**Files:**
- Create: `scenes/encounter/encounter_map_scene.gd`
- Modify: `scenes/encounter/encounter_map_scene.tscn`
- Modify: `scenes/encounter/encounter_map_view.gd`
- Modify: `tests/run_tests.gd`

1. RED:
   - invalid/locked id does not emit;
   - available id emits exactly once;
   - preview scene receives selection, calls `choose_next()`, refreshes view and status label.
2. GREEN:
   - `_on_node_pressed(node_id)` validates against `get_available_next_ids()`;
   - wrapper scene generates by `preview_seed`, connects signal, advances map and updates status.
3. Verify scene can be added to SceneTree headlessly without errors.
4. Commit: `feat(s5.2): handle available Encounter Map node selection`.

## Task 4 — Final validation and docs alignment

**Files:**
- Modify if needed: `docs/ARCHITECTURE_GUARDS.md`, `docs/GODOT_PATTERNS.md` only to resolve the duplicate S5.2 roadmap label; architecture line-count guard moves to a non-conflicting follow-up.
- Generated: `.uid` files from editor import, committed with sibling scripts.

Run:

```bash
/tmp/godot47.exe --headless --editor --quit
/tmp/godot47.exe --headless --path . --script tests/run_tests.gd
python tools/lint_anti_patterns.py
/tmp/godot47.exe --headless --path . --scene res://scenes/encounter/encounter_map_scene.tscn --quit-after 3
```

Then capture one rendered frame to PNG and inspect it for overlap/clipping before final report.

Commit only if cleanup/docs files remain: `docs(s5.2): align Encounter Map UI roadmap`.

---

## Ожидаемые изменения

| Файл | Изменение |
|---|---|
| `scenes/encounter/encounter_map_view.gd` | новый presentation Control (~180–230 LOC) |
| `scenes/encounter/encounter_map_scene.gd` | новый preview/controller (~40–60 LOC) |
| `scenes/encounter/encounter_map_scene.tscn` | новая запускаемая scene |
| `tests/run_tests.gd` | 5–7 test functions, ~25–35 assertions |
| docs roadmap | убрать коллизию двух разных S5.2 |

## Риски

| Риск | Митигация |
|---|---|
| 10 слоёв перекрываются на маленьком окне | clamp spacing + minimum node size; screenshot verification at project viewport |
| View случайно начнёт владеть progression | signal-only contract; mutation только в wrapper/S5.3 controller |
| Disabled Button всё равно вызывается напрямую в тесте | `_on_node_pressed()` повторно валидирует id, не полагается только на UI disabled |
| Headless не вызывает `_draw()` | тестировать layout/button state напрямую + отдельный rendered-frame capture |
| `tests/run_tests.gd` tab corruption | править через Python `readlines()/writelines()`, сверять S5.2 test names и assertion delta |

## Acceptance Criteria

- [ ] Отдельная scene загружается и работает без `RunController`.
- [ ] Все S5.1 nodes и edges представлены в UI.
- [ ] Только available nodes активны.
- [ ] Выбор available node эмитит signal и preview продвигается по DAG.
- [ ] Current/visited/available/locked визуально различимы.
- [ ] Editor-mode, full suite, lint и runtime smoke зелёные.
- [ ] Реальный PNG не имеет очевидных overlap/clipping дефектов.
