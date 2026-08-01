# Sprint 7.3: Item drops from combat

> **For Hermes:** TDD. RED → GREEN → commit. S7.3 даёт игроку chance-based item drop при победе в combat.

## Goal

After player wins a combat (any kind), there's an X% chance to drop 1 random ItemDef into inventory. Same `_on_battle_ended` path — atomic with REWARD.

## Архитектурные решения

### D1 — Single drop per combat

В `_on_battle_ended()` после `state.wins += 1`:
- Roll `Rng.randf() < MAP_COMBAT_DROP_CHANCE` (default 0.35 = 35%)
- If yes → `_pick_random_item_id()` + `grant_item()`
- Logging: "Combat dropped item {id}" or skip log

Use same helper `_pick_random_item_id()` from S7.1 (already in RunController).

### D2 — BALANCE constant

```gdscript
const MAP_COMBAT_DROP_CHANCE: float = 0.35  # 35% chance per combat victory
```

### D3 — Tests (deterministic via seed)

- Test 1: with Rng.seed_run(42), win 50 combats — at least 1 item dropped.
- Test 2: drop respects MAX_INVENTORY (no overflow).
- Test 3: drop respects seeded RNG so reproducible.

Tests need to simulate combat-win many times because RNG is stochastic. Approach:
1. start_run(seed)
2. Set seed
3. Loop: simulate `_on_battle_ended` triggered with `winner=0` 20 times
4. Count items in state.item_ids
5. Expect: count > 0 over 20 trials (probabilistic but bounded above zero)

Edge case: if picks at 100% rate, 20 items; if 0% rate, 0. With 35% → expected 7, std ~2. Test: count >= 1 AND count <= 20.

### D4 — Edge cases

- Player has MAX_INVENTORY: `grant_item` returns false, log warning. No crash.
- No items loaded: `_pick_random_item_id()` returns &"", no-op.
- Enemy win: no drop (only player wins trigger).
- Multiple combats: each has independent roll. Tracking which items dropped already — NOT tracked (each roll is independent random choice across all items).

## Step-by-Step Plan

### Task 1 — constant + method
- Add `MAP_COMBAT_DROP_CHANCE` to balance.
- Add `_grant_combat_drop()` private method.
- Wire into `_on_battle_ended()` after `state.wins += 1`.

### Task 2 — Tests
- `_test_run_controller_combat_victory_can_drop_item` (≥ 1 drop in 20 fights, seeded)
- `_test_combat_drop_respects_inventory_capacity` (full inv → silent fail)
- `_test_combat_drop_uses_random_item_pool` (item pool determinism via seed)

### Task 3 — Run

Tests → GREEN → commit.

## Test progression

| Task | Suite addition |
|---|---|
| 1 | +1 method (no test) |
| 2 | +3 tests |
| **Total** | +3 |

## Риски

| Риск | Митигация |
|---|---|
| Drop happens too often / too rare | Tune 0.35 (3 in 10 average) |
| Inventory full loses drops silently | Already a warning in grant_item — visible |
| Test variability | Use seed, large N (20), bounds check |
| Existing tests break due to extra drop | Player has 2 starting units with no items → drop chance still applies but inventory not full, so grant_item succeeds |

## Acceptance

- [x] Combat drop implemented + constant added
- [x] 3+ tests, all green, deterministic via seed
- [x] 0 fails in suite
- [x] editor-mode + suite + lint green
