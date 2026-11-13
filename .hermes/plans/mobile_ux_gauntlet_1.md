# Mobile UX Gauntlet 1 — Phase 0 Baseline & Audit

**Baseline SHA:** `d6ea2bfde2ad37c5a8291492fd3c1f2d92a94914` (remote `master`, verified)
**Branch:** `feature/mobile-ux-gauntlet-1`
**Worktree:** `C:\Users\user\AppData\Local\Temp\ri-mobileux` (clean, 0 changes)
**Godot:** 4.7 · **Platform:** Web / GitHub Pages

## Baseline verification

| Check | Result |
|---|---|
| Remote `master` SHA | `d6ea2bfde2ad37c5a8291492fd3c1f2d92a94914` ✓ matches the task baseline |
| Worktree created from `canonical/master` | ✓ `d6ea2bf` |
| Working tree | ✓ clean (0 changed files) |
| Existing published regression | 122/122 suites · 9231 assertions · A–H PASS · release 36/36 · F6 PASS |

## The architecture as it is

```
project.godot
  window/size/viewport_width  = 1280
  window/size/viewport_height = 720
  window/stretch/mode          = "canvas_items"
  window/stretch/aspect        = "expand"
```

Every UI scene is built in **code** (no `.tscn` UI), with **fixed base-space
sizes**:

| Scene | Element | Base size | Font |
|---|---|---|---|
| `main_menu.gd` | buttons | 380×56 | 16 |
| `prep_scene.gd` | panel | 960×440 | 20 (title) |
| `prep_scene.gd` | Ready button | 200×50 | 18 |
| `prep_scene.gd` | unit buttons | (per unit) | 14 |
| `shop_scene.gd` | panel | 820×480 | 22 (title) |
| `shop_scene.gd` | BUY button | 120×50 | 14 |
| `shop_scene.gd` | Leave Shop | 160×50 | 18 |
| `inventory_scene.gd` | panel | (fixed) | 14–18 |
| `reward_modal.gd` | panel | 720×360 | 22 (title) |
| `reward_modal.gd` | choice button | 180×200 | 14 |
| `reward_modal.gd` | Skip button | 160×40 | 14 |
| `encounter_map_view.gd` | node button | `NODE_SIZE` (54×46) | 18 |

## The root cause (measured, not assumed)

With `canvas_items + expand` the **viewport keeps the base width (1280)** and
its height follows the window's aspect. The whole viewport is then scaled by
`canvas.width / 1280` into the canvas.

At 390×844:

```
the viewport in the base space : 1280 x 2770
the scale                      : 390 / 1280 = 0.305
the canvas                     : 390 x 844
```

So **every** element shrinks by 3.28×:

| Element | Base | At 390 px wide |
|---|---|---|
| the item's font (14) | 14 px | **4.3 CSS px** |
| the title's font (22) | 22 px | **6.7 CSS px** |
| the BUY button (120×50) | 120×50 | **37×15 CSS px** |
| the map node (54×46) | 54×46 | **16×14 CSS px** |

**Measured on the real deployed frame** (`mobile-04-the-shop.png`,
390×844, the published build): the item's text renders **10 CSS px** tall and
the title **6 CSS px**. That is unreadable without a browser zoom, and the
44×44 CSS px touch target is missed by every button.

`canvas_items + expand` solved the clipping but produced this: the interface
is technically present and practically unusable.

## The problem table

| # | Problem | Severity | Evidence |
|---|---|---|---|
| 1 | The whole UI is scaled down to ~30 % on a phone — the text is 4–10 CSS px | **HIGH** | measured on the live frame |
| 2 | The touch targets are 15–37 CSS px, far below the 44×44 guideline | **HIGH** | 120×50 → 37×15 |
| 3 | The inventory is reachable only by the `I` key — no on-screen control | **HIGH** | `battle_scene.gd:326` |
| 4 | The battle speed is reachable only by the `1`/`2`/`4` keys | **HIGH** | `battle_scene.gd:314-319` |
| 5 | The game-over restart is reachable only by the `R` key | **HIGH** | `battle_scene.gd:323-325` |
| 6 | Buying a unit is reachable only by the `B` key | **MEDIUM** | `battle_scene.gd:320-322` |
| 7 | The battle start is reachable only by `SPACE` (a Ready button exists but is tiny) | **MEDIUM** | `prep_scene.gd:106`, `battle_scene.gd:311` |
| 8 | The reward's Skip is labelled "Skip (SPACE)" — the keyboard is the documented path | **MEDIUM** | `reward_modal.gd:87` |
| 9 | The overlays are `MOUSE_FILTER_STOP`, but the layers below stay `visible` and keep their own hit targets | **MEDIUM** | `battle_scene.gd:389,414,437,453,471` |
| 10 | The panels are fixed-size with no ScrollContainer — a long list is unreachable | **MEDIUM** | `shop_scene.gd:41`, `inventory_scene.gd` |
| 11 | The map's nodes are 16×14 CSS px and the hit test is the node's own rect | **MEDIUM** | `encounter_map_view.gd:130` |
| 12 | The desktop's `Ready (SPACE)` / `Skip (SPACE)` labels promise a keyboard | **LOW** | cosmetic once touch exists |

## The existing input map (the audit)

| Key | Where | The action |
|---|---|---|
| `SPACE` | `battle_scene` | `start_battle()` (PREP only) |
| `SPACE` | `prep_scene` | `_on_ready_pressed()` |
| `SPACE` | `shop_scene` | close the shop |
| `SPACE` | `reward_modal` | skip the reward |
| `1`/`2`/`4` | `battle_scene` | `speed = 1.0 / 2.0 / 4.0` |
| `B` | `battle_scene` | `buy_unit(0)` (PREP only) |
| `R` | `battle_scene` | `start_run(...)` (GAMEOVER only) |
| `I` | `battle_scene` | toggle the inventory |
| `I`/`ESC` | `inventory_scene` | close the inventory |

The phases are mutually exclusive (`_battle_entry_ready()` refuses the battle
when `just_visited_merchant` is set), so the four `SPACE` handlers do not
collide today — but they are one new touch control away from colliding.

## The strategy

`canvas_items + expand` scales **everything**, including the UI. The game area
may scale; the interface must not.

**The rule:** keep the base viewport for the game's own drawing, but let the
**UI layer** live in the canvas's own space (the real CSS pixels) on a phone,
and in the base space on the desktop.

Concretely, one shared helper decides the mode and hands every scene the same
numbers:

```
the mode     : DESKTOP | MOBILE      (from the canvas's real size)
the scale    : the UI's factor vs the base
the minimum  : the touch target's floor in CSS px (44)
the font     : the base font / the scale, with a floor of 14 CSS px
```

Each scene then sizes its panel from the **available** space and scales its
fonts, instead of hard-coding base-space sizes. The panels keep their base
look on the desktop (a scale of 1 → no change), and the phone gets readable
text and 44 px targets.

No new UI framework: a single `ResponsiveUILayout` helper plus a per-scene
call.

## The constraints that shape the work

- The desktop must not regress: at 1280×720 the scale is 1 → the existing
  sizes stay exactly as they are.
- The portrait orientation must be supported.
- No arbitrary per-iPhone scale table: one rule, applied everywhere.
- The base viewport is not changed (the analysis above shows what it would
  cost).
- The domain layer is not touched: the touch controls call the **same**
  `run_controller` operations as the keys.


---

# ИТОГ (Phase 0-8)

**FINAL HEAD:** `f34069f`
**BRANCH:** `feature/mobile-ux-gauntlet-1`
**BASELINE:** `canonical/master` = `d6ea2bfde2ad37c5a8291492fd3c1f2d92a94914`

## Что сделано

Единый helper `core/ui/responsive_ui_layout.gd`: физический размер P выражается
в base-space как `P / engine_scale`. На десктопе `engine_scale == 1` → все
размеры тождественны → десктопная регрессия невозможна по построению.

Адаптированы 8 сцен. Добавлены touch-контролы (Inventory / Speed / Buy /
Restart), вызывающие те же доменные операции, что и клавиши.

## Находки критиков (2 независимых ревью) — все HIGH/MEDIUM закрыты

| # | Находка | Исправление |
|---|---|---|
| H1 | Reward: 3 кнопки по 180 px = 588 px при панели 358 px | вертикальный стек |
| H2 | Тач-бар: 4 x 110 + 36 = 476 px при экране 390 px | кнопки делят ширину |
| H3 | Строка статуса: `size.y` = 0 в `_ready()` → y = −32 | якорь к низу |
| H4 | Доска PREP: 5 x 120 = 648 px при панели 358 px | сетка 2 колонки |
| H5 | **Регресс draw-order:** статус ушёл под непрозрачный BattleView | UI-слой `z_index = 10` |
| H6 | Инвентарь под тач-баром (z = 100) | панель поднята на 80 px |
| M1 | Шрифт unit-кнопок не компенсирован (4.3 CSS px) | `_font_px(14)` |
| M2 | Заголовки PREP/reward шире экрана | перенос + autowrap |
| M3 | Пагинация: путь искал кнопки прямо в VBox | путь через BottomRow |
| M4 | Пересборка оставляла старый панель (`queue_free` отложен) | `remove_child` + `queue_free` |
| M5 | Тест M проверял только загрузку скрипта | проверяет `mouse_filter` |

## Верификация

- `tests/run_domain/touch_controls_test.gd`: 115 assertions, GREEN
- 123/123 suites · 9346 assertions · 0 fail
- A–H PASS · release controls 36/36 · F6 PASS · ledger VALID · lint 0 errors
- WebGL: 1280x720 / 360x640 / 390x844 / 430x932 / 844x390 — 24/24
- Touch-only journey: 6/6 (без клавиатуры)
