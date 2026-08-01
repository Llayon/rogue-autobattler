# Sprint 7.2: Equip System

> **For Hermes:** TDD. RED → GREEN → commit. S7.2 даёт игроку эипить предметы из инвентаря на юнитов, с реальным применением бонусов в бою.

## Goal

Игрок может:
1. Из инвентаря нажать item → 进入 item-pick mode
2. Из PREP scene нажать board unit → item эипится (1 slot per unit, заменяется)
3. Bonus stats (attack/defense/max_hp) применяются к Combatant при start_battle
4. Item остаётся в инвентаре (`equipped_unit_idx` помечает его)
5. Unequip по клику в inventory → снимается (но item остается, можно переэипить)

## Архитектурные решения

### D1 — RunState extension

```gdscript
@export var item_ids: Array[StringName] = []
# S7.2: equip slot для каждого предмета (-1 = в инвентаре, 0..N = board idx).
@export var item_equip_board_idx: Array[int] = []
```

`item_equip_board_idx.size() == item_ids.size()`. Для каждого предмета указывает на какой board slot он эипится, или -1 если в инвентаре.

### D2 — RunController API

```gdscript
## equip/unequip
func equip_item_at(item_idx, board_idx) -> bool
func unequip_item_at(item_idx) -> bool
## queries
func get_equipped_board_idx(item_idx: int) -> int
func get_items_equipped_to_board(board_idx: int) -> Array  # item indices
## combat apply: returns {atk, def, hp} for board unit
func get_unit_bonus_stats(board_idx: int) -> Dictionary
```

### D3 — Combatant extension

`Combatant._init` получает `bonus_attack`, `bonus_defense`, `bonus_max_hp` параметры.
При создании через `start_battle`, читает `get_unit_bonus_stats(i)` и применяет.

### D4 — UI: equip workflow

InventoryScene item-buttons имеют **2 mode**:
- Click в инвентаре standalone → `set_equip_pick_mode(item_idx)` → подсветить inventory, message "pick a unit"
- В PREP scene нажат board unit → если есть picked item, equip; если нет — unequip (если на этом board slot что-то эипится)
- Alternative: простой UI — каждый item кнопка предлагает **Equip** dropdown / sub-button → выбор board unit

Самый быстрый: equip-management как **отдельная сцена** `scenes/equipment/equipment_scene.gd`? Too much. Use inventory scene с inline equip mode.

Quick MVP UX:
- Inventory item button click → "pick to equip" mode (set _picked_item_idx in InventoryScene)
- BACK button → cancel
- PREP scene board button → if picked, equip to that board idx
- Если кликнуть board unit в PREP прямо (без picked) → unequip если что-то эипится, else nothing
- PREP scene имеет `_unit_buttons` массив как InventoryScene item

### D5 — Persistence

`item_equip_board_idx` в state сохраняется через native Resource serialization (как item_ids).

## Step-by-Step Plan

### Task 1 — RunController equip API
- `equip_item_at(item_idx, board_idx)` (with bounds check)
- `unequip_item_at(item_idx)` (-1)
- `get_equipped_board_idx(item_idx)`
- `get_items_equipped_to_board(board_idx)` returns Array of item indices
- `get_unit_bonus_stats(board_idx)` returns Dictionary {atk, def, hp}
- Init `item_equip_board_idx` in start_run / resume_run
- Tests: equip/unequip, dual equip (one unit, two items), bonus stats aggregation

### Task 2 — Combatant bonus params
- `_init` params: `bonus_attack`, `bonus_defense`, `bonus_max_hp` (default 0)
- Tests: hp_override + atk_override + def_override combined

### Task 3 — start_battle applies bonuses
- Compute bonuses per board idx, pass to CombatantScript.new
- Tests: end-to-end bonus propagation

### Task 4 — InventoryScene equip UX
- Inventory item button: click → `_picked_item_idx = idx`, set message "click unit to equip"
- BACK button resets picked
- Public method `try_equip_to_board(board_idx)` returns bool
- Tests: pick state, equip by calling try_equip_to_board

### Task 5 — PREP scene equip integration
- Add board button click handler that calls `inventory_scene.try_equip_to_board(idx)`
- Method unequips if something already on that slot
- Tests: board click triggers equip

### Task 6 — Persistence verification
- `item_equip_board_idx` survives save/load (covered by native serialization)
- Tests: save with 1 equipped item, load, verify still equipped

## Test progression

| Task | Suite addition |
|---|---|
| 1 | +6 tests |
| 2 | +2 tests |
| 3 | +1 test |
| 4 | +3 tests |
| 5 | +1 test |
| 6 | +1 test |
| **Total** | +14 tests |

## Риски

| Риск | Митигация |
|---|---|
| BattleScene `inventory_scene` not always created (e.g. tests) | _picked_item_idx defaults to -1 |
| Unequip when item disappears (after discard) | unequip_item_at checks bounds |
| item_equip_board_idx size mismatch | sync in equip_item_at, unequip just sets -1 |
| Combatant signature change breaks existing tests | New params with defaults |

## Acceptance

- [x] RunController equip API complete
- [x] Combatant accepts bonus params
- [x] start_battle applies bonuses
- [x] InventoryScene equip UX (pick → equip)
- [x] PREP scene equip integration
- [x] Persistence verified
- [x] 468+ tests, 0 fail
- [x] editor-mode, suite, lint green
