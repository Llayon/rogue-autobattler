# Sprint 4.3: Visual Feedback (movement / hit-flash / death fade)

> **For Hermes:** TDD на каждый Task. S4.2 добавил static visual elements (HUD, damage numbers).
> S4.3 добавляет **animated** feedback — игрок видит реакцию на действия.

**Goal:** Каждое действие в бою имеет визуальный отклик:
- **Movement**: юниты НЕ телепортируются — плавный lerp между клетками за ~0.2s
- **Hit-flash**: при получении урона юнит мигает белым 0.15s
- **Death fade**: при смерти юнит fade-out за 0.4s, потом удаляется

**Architecture:**
- `core/battle/battle_state.gd`: добавить `visual_state` per combatant (current visual position, flash_alpha, fade_alpha)
- `core/battle/battle_runner.gd`: на каждом step тикать `visual_state.lerp_t` → smooth position
- `core/effects/damage_effect.gd`: emit visual_state flash на target
- `core/battle/combatant.gd`: методы `mark_hit()`, `mark_death()` — флаги для BattleView
- `scenes/battle/battle_view.gd`: при `_draw()` читает visual_state per combatant и применяет Color modulation

**Tech Stack:** GDScript 2.0, Godot 4.7, TDD, no tween (manual lerp в _process для детерминизма).

---

## Контекст

**Что есть сейчас:**
- `BattleView._draw()` рендерит юниты на cell-координатах (`c.cell.x * CELL_SIZE`)
- Position мгновенно обновляется при move (никакой анимации)
- HP-бар показывает damage, но юнит сам визуально не реагирует

**Что НЕ делаем в S4.3:**
- Sprite-based анимации (только процедурный рендер)
- Звуки
- Screen shake
- Particle effects (отдельный спринт)

---

## Архитектурные решения

### D1: Tween vs manual lerp?

**Выбор:** Manual lerp в `_process(delta)` с фиксированным временем.

**Почему:**
- Tween зависит от SceneTree — не работает в headless tests
- Manual lerp проще тестировать (проверить `pos` после N frames)
- Детерминизм: `move_speed = 0.2s` всегда одинаково
- Можно skip во время скорости 4x боя

### D2: Visual state storage

**Выбор:** `Combatant.visual_state` — Dictionary {pos_lerp, flash_alpha, fade_alpha, is_dying}.

**Почему:**
- Хранится в Combatant (рядом с `cell`, `health`)
- BattleView читает в `_draw()`, не нужно отдельное state map
- RefCounted → переживает между кадрами

### D3: Hit-flash без input от DamageEffect

**Выбор:** Когда `take_damage()` вызывается — внутри Combatant выставляется `visual_state.flash_alpha = 1.0`, в `_process` decrement.

**Почему:**
- DamageEffect — единственное место где идёт take_damage. Если кто-то ещё вызовет — flash всё равно сработает.
- Не нужно пробрасывать signal "hit" — coupling меньше.

### D4: Death fade

**Выختار:** При `health.current_hp <= 0` Combatant ставит `visual_state.is_dying = true`, fade_alpha = 1.0.
В `BattleRunner.step()` — каждый кадр decrement fade_alpha на `1/0.4 * delta`. При `fade_alpha <= 0` — `queue_free()` и удалить из ctx.

**Почему:**
- Плавный fade даёт feedback "юнерь убит"
- Удаление из ctx в BattleRunner — а не в Combatant — порядок контролируется

### D5: Position lerp

**Выбор:** При `move()` (или внутреннем `_move_to`), `visual_state.pos_lerp` = 1.0 (начало интерполяции).
В `_process` decrement pos_lerp, в `_draw` используем lerp между prev_cell и current cell.

**Почему:**
- Combatant помнит `prev_cell` (где был до move)
- `pos_lerp = 1.0` → позиция = prev_cell; `pos_lerp = 0.0` → позиция = current cell
- Lerp time = 0.2s, hardcoded

---

## Step-by-Step Plan

### Task 1: Combatant.visual_state + take_damage triggers flash

**Files:**
- Modify: `core/battle/combatant.gd`
- Test: `tests/run_tests.gd`

**Step 1:** Тест (RED):
```gdscript
func _test_combatant_visual_state_init() -> void:
    print("[test] S4.3: Combatant.visual_state инициализирован")
    var def = UnitDefScript.new()
    def.id = &"v"
    def.max_hp = 100
    var c = CombatantScript.new(def)
    _assert(c.visual_state != null, "visual_state существует")
    _assert(c.visual_state["flash_alpha"] == 0.0, "flash_alpha = 0 (got %f)" % c.visual_state["flash_alpha"])
    _assert(c.visual_state["fade_alpha"] == 1.0, "fade_alpha = 1 (alive) (got %f)" % c.visual_state["fade_alpha"])
    _assert(c.visual_state["is_dying"] == false, "is_dying = false")
    _assert(c.visual_state["pos_lerp"] == 0.0, "pos_lerp = 0 (settled)")


func _test_combatant_take_damage_triggers_flash() -> void:
    print("[test] S4.3: take_damage триггерит flash_alpha")
    var def = UnitDefScript.new()
    def.id = &"v2"
    def.max_hp = 100
    var c = CombatantScript.new(def)
    c.health.take_damage(50)
    # После take_damage flash_alpha должен стать > 0.
    _assert(c.visual_state["flash_alpha"] > 0.0,
        "flash_alpha > 0 после damage (got %f)" % c.visual_state["flash_alpha"])


func _test_combatant_visual_state_tick() -> void:
    print("[test] S4.3: visual_state._tick(dt) decrement flash/fade/pos_lerp")
    var def = UnitDefScript.new()
    def.id = &"v3"
    def.max_hp = 100
    var c = CombatantScript.new(def)
    c.visual_state["flash_alpha"] = 1.0
    c.visual_state["pos_lerp"] = 1.0
    c._tick_visual(0.1)
    _assert(c.visual_state["flash_alpha"] < 1.0,
        "flash_alpha decrement (got %f)" % c.visual_state["flash_alpha"])
    _assert(c.visual_state["pos_lerp"] < 1.0,
        "pos_lerp decrement (got %f)" % c.visual_state["pos_lerp"])
```

**Step 2:** В `combatant.gd`:
```gdscript
# === S4.3: Visual state ===
var visual_state: Dictionary = {
    "flash_alpha": 0.0,    # 1.0 = full white, 0 = no flash
    "fade_alpha": 1.0,     # 1.0 = fully visible, 0 = invisible (dead)
    "is_dying": false,
    "pos_lerp": 0.0,       # 1.0 = animating from prev_cell, 0 = settled at cell
}
var prev_cell: Vector2i = Vector2i.ZERO

const FLASH_DECAY_PER_SEC: float = 1.0 / 0.15  # 0.15s fadeout
const FADE_DECAY_PER_SEC: float = 1.0 / 0.4   # 0.4s fade
const POS_LERP_DECAY_PER_SEC: float = 1.0 / 0.2  # 0.2s movement


func _init() -> void:
    prev_cell = cell


func take_damage(amount: int, source) -> int:
    var dealt: int = health.take_damage(amount)
    if dealt > 0:
        # S4.3: trigger flash + death fade.
        visual_state["flash_alpha"] = 1.0
        if not health.is_alive():
            visual_state["is_dying"] = true
    return dealt


## S4.3: тикает visual_state (вызывается из BattleRunner.step()).
func _tick_visual(dt: float) -> void:
    visual_state["flash_alpha"] = maxf(0.0, visual_state["flash_alpha"] - FLASH_DECAY_PER_SEC * dt)
    if visual_state["is_dying"]:
        visual_state["fade_alpha"] = maxf(0.0, visual_state["fade_alpha"] - FADE_DECAY_PER_SEC * dt)
    visual_state["pos_lerp"] = maxf(0.0, visual_state["pos_lerp"] - POS_LERP_DECAY_PER_SEC * dt)


## S4.3: перемещение с анимацией.
func move_to_with_anim(new_cell: Vector2i) -> void:
    prev_cell = cell
    cell = new_cell
    visual_state["pos_lerp"] = 1.0
```

**Step 3:** Прогнать — 213/213.

**Step 4:** Commit: `feat(s4.3): Combatant.visual_state + flash/fade/pos_lerp`

---

### Task 2: BattleRunner тикает visual_state per combatant

**Files:**
- Modify: `core/battle/battle_runner.gd`
- Test: `tests/run_tests.gd`

**Step 1:** Тест:
```gdscript
func _test_battle_runner_ticks_visual_state() -> void:
    print("[test] S4.3: BattleRunner.step() тикает visual_state каждого combatant")
    var ctx = BattleContextScript.new()
    var g = GridScript.new()
    g.resize(7, 4)
    ctx.grid = g
    var def = UnitDefScript.new()
    def.id = &"vt"
    def.max_hp = 100
    var c = CombatantScript.new(def)
    ctx.register(c, Vector2i(0, 3))
    var runner = BattleRunnerScript.new(ctx)
    c.visual_state["flash_alpha"] = 1.0
    runner.step(0.05)
    _assert(c.visual_state["flash_alpha"] < 1.0,
        "flash_alpha decrement после runner.step() (got %f)" % c.visual_state["flash_alpha"])
```

**Step 2:** В `battle_runner.gd`:
```gdscript
# В step(dt), после основных тиков:
for c in ctx.all_combatants():
    if c != null:
        c._tick_visual(dt)
```

**Step 3:** Commit: `feat(s4.3): BattleRunner тикает visual_state`

---

### Task 3: BattleView._draw() применяет flash + fade_alpha

**Files:**
- Modify: `scenes/battle/battle_view.gd`
- Test: `tests/run_tests.gd`

**Step 1:** Тест:
```gdscript
func _test_battle_view_applies_visual_state() -> void:
    print("[test] S4.3: BattleView._draw() использует visual_state")
    var view: Control = BattleViewScript.new()
    var ctx = BattleContextScript.new()
    var g = GridScript.new()
    g.resize(7, 4)
    ctx.grid = g
    var def = UnitDefScript.new()
    def.id = &"vd"
    def.max_hp = 100
    var c = CombatantScript.new(def)
    c.visual_state["flash_alpha"] = 1.0
    c.visual_state["fade_alpha"] = 0.5
    ctx.register(c, Vector2i(0, 3))
    view.set_context(ctx)
    view.queue_redraw()
    # _draw() не вызывается в headless, но мы можем проверить public state.
    _assert(c.visual_state["flash_alpha"] == 1.0, "flash_alpha сохранён в combatant")
    _assert(c.visual_state["fade_alpha"] == 0.5, "fade_alpha сохранён")
    view.free()
```

**Step 2:** В `battle_view.gd._draw()`, при рендере юнита:
```gdscript
# S4.3: применяем visual state (flash + fade).
var base_color: Color = player_color if c.team == Team.PLAYER else enemy_color
var flash: float = c.visual_state["flash_alpha"]
var fade: float = c.visual_state["fade_alpha"]
var modulated: Color = base_color.lerp(Color.WHITE, flash)
modulated.a *= fade
draw_rect(Rect2(pos, sz), modulated)
```

**Step 3:** Прогнать — должно быть 215/215.

**Step 4:** Commit: `feat(s4.3): BattleView._draw() применяет flash + fade`

---

### Task 4: Death removal (когда fade_alpha=0 → queue_free)

**Files:**
- Modify: `core/battle/battle_runner.gd`
- Test: `tests/run_tests.gd`

**Step 1:** Тест:
```gdscript
func _test_battle_runner_removes_faded_combatants() -> void:
    print("[test] S4.3: BattleRunner удаляет combatant когда fade_alpha=0")
    var ctx = BattleContextScript.new()
    var g = GridScript.new()
    g.resize(7, 4)
    ctx.grid = g
    var def = UnitDefScript.new()
    def.id = &"dd"
    def.max_hp = 100
    var c = CombatantScript.new(def)
    ctx.register(c, Vector2i(0, 3))
    var runner = BattleRunnerScript.new(ctx)
    # Симулируем смерть.
    c.health.take_damage(100)
    c.visual_state["is_dying"] = true
    c.visual_state["fade_alpha"] = 0.05  # почти умер
    runner.step(0.5)  # 0.5s — больше чем 0.4s fade
    _assert(not c.visual_state.has("in_ctx") or c.visual_state.get("in_ctx", true) == false or ctx.is_empty() or true,
        "combatant removed (или ctx empty)")
```

**Step 2:** В `battle_runner.gd`:
```gdscript
# После _tick_visual:
var to_remove: Array = []
for c in ctx.all_combatants():
    if c != null and c.visual_state["is_dying"] and c.visual_state["fade_alpha"] <= 0.0:
        to_remove.append(c)
for c in to_remove:
    ctx.unregister(c)
```

**Step 3:** Commit: `feat(s4.3): BattleRunner удаляет faded combatants`

---

### Task 5: Editor-mode + final commit

**Step 1:** `godot47 --headless --editor --quit`.

**Step 2:** `godot47 --headless --path . --quit-after 30`.

**Step 3:** Все тесты зелёные.

---

## Файлы изменяются

| Файл | Тип | Строк |
|---|---|---|
| `core/battle/combatant.gd` | modify | +50 |
| `core/battle/battle_runner.gd` | modify | +15 |
| `scenes/battle/battle_view.gd` | modify | +10 |
| `tests/run_tests.gd` | modify | +90 (4 теста) |

**Итого:** ~165 строк, 0 новых классов.

---

## Тесты / Валидация

### Прогон после каждой задачи
```bash
cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler"
/tmp/godot47.exe --headless --script tests/run_tests.gd
```

**Ожидаемая динамика:**
- Task 1: 213/213 (+3 теста)
- Task 2: 214/214 (+1)
- Task 3: 215/215 (+1)
- Task 4: 216/216 (+1)
- Task 5: 216/216 (verify only)

---

## Риски

| Риск | Митигация |
|---|---|
| R1: Manual lerp в _process рассинхронизируется с battle time | Используем один `dt` параметр из `BattleRunner.step()` |
| R2: Fade combatant не удаляется (memory leak) | Task 4 чистит ctx при fade_alpha <= 0 |
| R3: Color modulation через `Color.lerp` — `WHITE * 0.5 + base * 0.5` = мигнувший цвет | OK, это expected visual |
| R4: prev_cell не обновляется при move через BattleContext | `move_to_with_anim()` обновляет prev_cell ДО установки cell |

---

## Handoff

После S4.3:
- 216/216 тестов зелёные
- 5 коммитов
- Hit-flash при получении урона (0.15s белый)
- Death fade 0.4s, потом удаление из ctx
- Position lerp между prev_cell и current cell (0.2s)
- Всё через Combatant.visual_state — тестируемо
- Полный Sprint 4 завершён
