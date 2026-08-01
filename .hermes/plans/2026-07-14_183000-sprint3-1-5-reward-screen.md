# Sprint 3.1.5: Reward Screen (Phase.REWARD) — Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Добавить промежуточный экран награды между боями — игрок выбирает 1 из 3 бесплатных юнитов перед следующим PREP-фазой.

**Architecture:** Расширяем существующий `Shop` режимом `free_pick` (цена = 0, выбор = ровно 1). Новый `Phase.REWARD` в `RunController`. UI подписывается на `phase_changed(REWARD)` и рисует 3 слота; по клику вызывает `choose_reward(slot)`.

**Tech Stack:** GDScript 2.0, Godot 4.7, TDD (RED→GREEN), single source of truth в `core/balance.gd`.

---

## Контекст

**Текущее состояние** (после S3.1 commit `93491d5`):
- `Phase.REWARD` enum уже есть в `run_controller.gd:11`, но никогда не выставляется
- `Shop` (`core/economy/shop.gd`) уже умеет: `refresh(pool)`, `offer_at(slot)`, `take_at(slot)`, `offered_ids()`
- `UnitDef` имеет `tier` (1-3) и `cost`
- Все юниты (12 шт) имеют `.tres` в `content/units/`
- 134/134 тестов зелёные

**Что добавляем:**
1. Фаза REWARD в `RunController` — между победным боем и PREP
2. Reward pool — выбор юнитов по round_index (tier-weighted)
3. `choose_reward(slot) -> bool` — игрок берёт одного, остальные отбрасываются
4. UI-сигналы (когда сделаем UI): reward slots публикуются через GameBus

**Что НЕ делаем в этом спринте:**
- UI сцена (только core-логика; UI подключим в S4.x когда дойдём)
- Анимация выбора
- "Skip without choice" — на 1-й версии игрок обязан выбрать (или можно добавить pass=skip позже)

---

## Архитектурные решения

### D1: Отдельный `RewardScreen` класс vs расширение `Shop`?

**Выбор:** отдельный `RewardScreen extends RefCounted` в `core/progression/reward_screen.gd`.

**Почему не Shop:**
- Shop — это "купить за gold", reward — "бесплатно, выбор 1"
- У них разный жизненный цикл: Shop живёт весь ран, reward создаётся на 1 раунд
- Tier-weighting другая логика (Shop берёт из `unlocked_units`, reward — из всех 12 по round)

### D2: Tier-фильтр для reward pool

**Формула:** tier_round = `clamp(round_index / 3, 1, 3)`. 60% — этот тир, 30% — тир-1, 10% — тир+1.

### D3: Детерминизм

Reward pool генерируется через `Rng.*` (уже seeded в `start_run`). Один и тот же seed = тот же reward offer.

### D4: Совместимость с S3.1 win check

После 10-й победы `_end_run(true)` срабатывает ДО перехода в REWARD. То есть REWARD показывается только для раундов 1-9.

---

## Step-by-Step Plan

### Task 1: Balance constants для reward

**Files:**
- Modify: `core/balance.gd` (добавить секцию "Reward")

**Step 1:** Добавить константы:

```gdscript
# === Reward screen (S3.1.5) ===
const REWARD_SLOTS: int = 3                # сколько юнитов в выборе
const REWARD_OFFER_PRICE: int = 0          # бесплатно (как в TFT, Slay the Spire)
const REWARD_TIER_BASE_WEIGHT: float = 0.6 # 60% — основной тир
const REWARD_TIER_MINUS_WEIGHT: float = 0.3 # 30% — тир-1
const REWARD_TIER_PLUS_WEIGHT: float = 0.1 # 10% — тир+1
```

**Step 2:** Запустить тесты — должны остаться 134/134 (никаких поломок, просто константы).

**Step 3:** Commit: `chore(s3.1.5): add reward screen balance constants`

---

### Task 2: `core/data/units_meta.gd` — реестр всех юнитов (RED)

**Files:**
- Create: `core/data/units_meta.gd`
- Test: `tests/run_tests.gd` (добавить `_test_units_meta_all_units`)

**Почему:** reward screen должен иметь доступ ко **всем** 12 юнитам, не только `unlocked_units`. `ContentDB_static` сейчас грузит .tres динамически — нужна статическая функция-реестр.

**Step 1:** Создать `core/data/units_meta.gd`:

```gdscript
class_name UnitsMeta extends RefCounted
## Статический реестр всех UnitDef в content/units/.
## Используется для reward screen, чтобы предложить юнитов которых у игрока ещё нет.

const UNIT_IDS: Array[StringName] = [
    &"warrior", &"archer", &"mage", &"cleric",
    &"guardian", &"assassin", &"druid", &"berserker",
    &"paladin", &"necromancer", &"knight", &"elementalist",
]


## Возвращает все id юнитов (включая заблокированные).
static func all_ids() -> Array[StringName]:
    return UNIT_IDS.duplicate()


## Возвращает id юнитов определённого tier (1-3).
static func ids_by_tier(tier: int) -> Array[StringName]:
    var result: Array[StringName] = []
    for id in UNIT_IDS:
        var def: Resource = ContentDB_static.get_by_id(id)
        if def != null and def.tier == tier:
            result.append(id)
    return result
```

**Step 2:** Добавить тест `_test_units_meta_all_units` в `tests/run_tests.gd`:
- 12 unit IDs
- ids_by_tier(1) содержит warrior, archer, mage, cleric (как минимум)
- ids_by_tier(3) содержит paladin/necromancer/knight/elementalist (как минимум)

**Step 3:** Регистрация в `_initialize()`.

**Step 4:** Запустить — должны пройти.

**Step 5:** Commit: `feat(s3.1.5): add UnitsMeta static registry`

---

### Task 3: `core/progression/reward_screen.gd` — генерация pool (RED → GREEN)

**Files:**
- Create: `core/progression/reward_screen.gd`
- Test: `tests/run_tests.gd` (добавить `_test_reward_screen_pool`)

**Step 1:** Тест сначала (RED):

```gdscript
func _test_reward_screen_pool() -> void:
    print("[test] S3.1.5: RewardScreen pool generation")
    Rng.seed_run(12345)
    var rs: Object = RewardScreenScript.new()
    var pool: Array = rs.generate_offer(3)  # round 3
    _assert(pool.size() == BalanceScript.REWARD_SLOTS, "offer = 3 слота (got %d)" % pool.size())
    # Round 3 → tier 1, с 30% chance tier-1=0 → no tier-0, всё tier 1
    for id in pool:
        var def: Resource = ContentDB_static.get_by_id(id)
        _assert(def != null, "offered id валиден: %s" % id)
    # Детерминизм
    Rng.seed_run(12345)
    var rs2: Object = RewardScreenScript.new()
    var pool2: Array = rs2.generate_offer(3)
    _assert(pool == pool2, "тот же seed = тот же pool")
```

**Step 2:** Создать `core/progression/reward_screen.gd`:

```gdscript
class_name RewardScreen extends RefCounted
## Генерирует offer для reward screen между раундами.
##
## Offer = N случайных юнитов, tier-weighted по round_index.
## Не учитывает unlocked_units — reward может предложить нового юнита.
##
## v1: без анимаций, без UI — только core-логика.

var _offered_ids: Array[StringName] = []
var _round_index: int = 0


## Вычисляет tier для reward на этом раунде.
static func target_tier_for_round(round_index: int) -> int:
    return clampi(round_index / 3, 1, 3)


## Генерирует offer из REWARD_SLOTS юнитов.
## Tier-weighted: 60% target, 30% target-1 (если >0), 10% target+1 (если <4).
## Записывает результат в self._offered_ids и возвращает копию.
func generate_offer(round_index: int) -> Array[StringName]:
    _round_index = round_index
    _offered_ids.clear()
    var target_tier: int = target_tier_for_round(round_index)
    var pool: Array[StringName] = []
    while pool.size() < BalanceScript.REWARD_SLOTS:
        var tier: int = _pick_tier(target_tier)
        var tier_pool: Array = UnitsMeta.ids_by_tier(tier)
        if tier_pool.is_empty():
            continue
        var pick: StringName = tier_pool[Rng.randi_range(0, tier_pool.size() - 1)]
        if pick not in pool:
            pool.append(pick)
    _offered_ids = pool.duplicate()
    return _offered_ids.duplicate()


## Возвращает текущий offer (read-only).
func offered_ids() -> Array[StringName]:
    return _offered_ids.duplicate()


## Выбирает tier с вероятностями из Balance.
func _pick_tier(target: int) -> int:
    var r: float = Rng.randf()
    if r < BalanceScript.REWARD_TIER_BASE_WEIGHT:
        return target
    elif r < BalanceScript.REWARD_TIER_BASE_WEIGHT + BalanceScript.REWARD_TIER_MINUS_WEIGHT:
        return maxi(1, target - 1)
    else:
        return mini(3, target + 1)
```

**Step 3:** Preload в `run_tests.gd`:
```gdscript
const RewardScreenScript = preload("res://core/progression/reward_screen.gd")
```

**Step 4:** Прогнать — RED → GREEN.

**Step 5:** Commit: `feat(s3.1.5): add RewardScreen with tier-weighted offer`

---

### Task 4: `RunController` — REWARD phase integration (RED → GREEN)

**Files:**
- Modify: `core/progression/run_controller.gd` (добавить reward field + choose_reward)
- Test: `tests/run_tests.gd` (добавить `_test_run_controller_reward_phase`)

**Step 1:** Тест (RED):

```gdscript
func _test_run_controller_reward_phase() -> void:
    print("[test] S3.1.5: RunController переходит в REWARD после победы")
    var ctrl: Node = RunControllerScript.new()
    get_root().add_child.call_deferred(ctrl)
    await process_frame
    ctrl.start_run(42)
    # Сымитируем 1-ю победу: round_index=1, wins=0; после _on_battle_ended → REWARD.
    ctrl.state.round_index = 1
    ctrl.state.wins = 0
    ctrl.start_battle()
    ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
    ctrl.runner.state.winner_team = 0
    ctrl.tick_battle(0.1)
    # Проверяем: phase = REWARD.
    _assert(ctrl.phase == RunControllerScript.Phase.REWARD, "phase = REWARD после 1-й победы (got %d)" % ctrl.phase)
    _assert(ctrl.reward.offered_ids().size() == BalanceScript.REWARD_SLOTS, "reward offer = 3 слота")
    # Игрок берёт слот 0.
    var taken: Resource = ctrl.choose_reward(0)
    _assert(taken != null, "choose_reward(0) вернул UnitDef")
    _assert(ctrl.phase == RunControllerScript.Phase.PREP, "phase = PREP после выбора")
    _assert(ctrl.state.bench_unit_ids.has(taken.id), "юнит добавлен в bench")
    _cleanup_ctrl(ctrl)
```

**Step 2:** В `run_controller.gd` добавить:

```gdscript
var reward: RewardScreen = RewardScreen.new()  # добавить в шапку рядом с var shop


# В _on_battle_ended, ветка winner == 0, после state.round_index += 1 и ДО win check:
func _on_battle_ended() -> void:
    var winner: int = runner.state.winner_team
    if winner == 0:
        state.wins += 1
        state.gold += BalanceScript.WIN_BONUS_GOLD + state.round_index
        GameBus.emit_gold_changed(state.gold)
        state.round_index += 1
        # S3.1: победа на MAX_ROUND завершает ран (без reward).
        if state.round_index > BalanceScript.MAX_ROUND:
            _end_run(true)
            return
        # S3.1.5: переходим в REWARD (кроме round 1, где reward не показываем — стартовый набор).
        if state.round_index > 1:
            _enter_reward()
        else:
            _set_phase(Phase.PREP)
            _refresh_shop()
            GameBus.emit_round_started(state.round_index)


func _enter_reward() -> void:
    reward.generate_offer(state.round_index)
    _set_phase(Phase.REWARD)
    GameBus.emit_reward_offered(reward.offered_ids())


## Игрок выбирает юнита из reward. Возвращает UnitDef или null.
func choose_reward(slot: int) -> Resource:
    if phase != Phase.REWARD:
        return null
    var def: Resource = reward.offer_at(slot)
    if def == null:
        return null
    state.bench_unit_ids.append(def.id)
    GameBus.emit_reward_chosen(def.id, slot)
    GameLog.info("run", "Reward chosen", {"id": def.id, "round": state.round_index})
    _set_phase(Phase.PREP)
    _refresh_shop()
    GameBus.emit_round_started(state.round_index)
    return def
```

**Step 3:** В `reward_screen.gd` добавить `offer_at`:

```gdscript
## Возвращает UnitDef по индексу слота, или null.
func offer_at(slot: int) -> Resource:
    if slot < 0 or slot >= _offered_ids.size():
        return null
    return ContentDB_static.get_by_id(_offered_ids[slot])
```

**Step 4:** Добавить сигналы в `core/utils/event_bus.gd`:

```gdscript
signal reward_offered(unit_ids: Array[StringName])
signal reward_chosen(unit_id: StringName, slot: int)

# static helpers
static func emit_reward_offered(ids: Array[StringName]) -> void:
    emit_signal("reward_offered", ids)

static func emit_reward_chosen(id: StringName, slot: int) -> void:
    emit_signal("reward_chosen", id, slot)
```

**Step 5:** Прогнать — должны быть 135/135 (134 + 1 новый).

**Step 6:** Commit: `feat(s3.1.5): RunController REWARD phase + choose_reward`

---

### Task 5: Edge cases — skip reward, end run without reward, детерминизм unlock (RED → GREEN)

**Files:**
- Modify: `core/progression/run_controller.gd` (добавить `skip_reward`)
- Test: `tests/run_tests.gd` (2 теста)

**Step 1:** Тест 1 — skip reward:
```gdscript
func _test_run_controller_skip_reward() -> void:
    print("[test] S3.1.5: skip_reward() переходит в PREP без юнита")
    var ctrl: Node = RunControllerScript.new()
    get_root().add_child.call_deferred(ctrl)
    await process_frame
    ctrl.start_run(42)
    ctrl.state.round_index = 2
    ctrl.state.wins = 1
    ctrl.start_battle()
    ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
    ctrl.runner.state.winner_team = 0
    ctrl.tick_battle(0.1)
    _assert(ctrl.phase == RunControllerScript.Phase.REWARD, "phase = REWARD")
    var bench_before: int = ctrl.state.bench_unit_ids.size()
    var ok: bool = ctrl.skip_reward()
    _assert(ok == true, "skip_reward = true")
    _assert(ctrl.phase == RunControllerScript.Phase.PREP, "phase = PREP после skip")
    _assert(ctrl.state.bench_unit_ids.size() == bench_before, "bench не изменился")
    _cleanup_ctrl(ctrl)
```

**Step 2:** Тест 2 — детерминизм reward:
```gdscript
func _test_reward_screen_determinism() -> void:
    print("[test] S3.1.5: тот же seed = тот же reward offer")
    Rng.seed_run(777)
    var rs1: Object = RewardScreenScript.new()
    var pool1: Array = rs1.generate_offer(5)
    Rng.seed_run(777)
    var rs2: Object = RewardScreenScript.new()
    var pool2: Array = rs2.generate_offer(5)
    _assert(pool1 == pool2, "детерминизм: pool1 == pool2 (got %s vs %s)" % [str(pool1), str(pool2)])
```

**Step 3:** В `run_controller.gd`:

```gdscript
## Игрок пропускает reward. Возвращает true если успешно.
func skip_reward() -> bool:
    if phase != Phase.REWARD:
        return false
    GameLog.info("run", "Reward skipped", {"round": state.round_index})
    _set_phase(Phase.PREP)
    _refresh_shop()
    GameBus.emit_round_started(state.round_index)
    return true
```

**Step 4:** Прогнать — 137/137 (134 + 3 из tasks 3+4+5).

**Step 5:** Commit: `feat(s3.1.5): skip_reward + reward determinism`

---

### Task 6: Edge case — REWARD не показывается на 1-й победе

**Files:**
- Modify: `core/progression/run_controller.gd`
- Test: добавить `_test_run_controller_no_reward_on_first_round`

**Step 1:** Тест:
```gdscript
func _test_run_controller_no_reward_on_first_round() -> void:
    print("[test] S3.1.5: после 1-й победы (round 1) НЕТ reward")
    var ctrl: Node = RunControllerScript.new()
    get_root().add_child.call_deferred(ctrl)
    await process_frame
    ctrl.start_run(42)
    # Round 1 → wins 0 → after win: round_index=2, no reward, → PREP
    ctrl.state.round_index = 1
    ctrl.state.wins = 0
    ctrl.start_battle()
    ctrl.runner.state.phase = BattleStateScriptForCtrl.Phase.ENDED
    ctrl.runner.state.winner_team = 0
    ctrl.tick_battle(0.1)
    _assert(ctrl.state.round_index == 2, "round_index = 2")
    _assert(ctrl.phase == RunControllerScript.Phase.PREP, "phase = PREP (no REWARD на round 1→2)")
    _cleanup_ctrl(ctrl)
```

(Это уже неявно покрыто Task 4 — но добавим отдельный тест для ясности.)

**Step 2:** Логика уже добавлена в Task 4 (`if state.round_index > 1: _enter_reward()`).

**Step 3:** Прогнать — 138/138.

**Step 4:** Commit: `test(s3.1.5): explicit test no-reward on first win`

---

### Task 7: GameBus signals (EventBus autoload)

**Files:**
- Modify: `core/utils/event_bus.gd`
- Verify: прогнать тесты (не должны падать)

**Step 1:** Сигналы уже добавлены в Task 4. Проверить что `event_bus_autoload.gd` extends `event_bus.gd` (он есть в AGENTS.md).

**Step 2:** Smoke-тест: запустить существующие сцены, проверить что нет warning'ов.

**Step 3:** Если всё чисто — финальный commit:
```bash
git commit -m "feat(s3.1.5): REWARD phase complete (138 tests, phase machine + determinism)"
```

---

## Файлы которые меняются

| Файл | Тип | Строк (примерно) |
|---|---|---|
| `core/balance.gd` | modify | +8 |
| `core/data/units_meta.gd` | new | ~25 |
| `core/progression/reward_screen.gd` | new | ~60 |
| `core/progression/run_controller.gd` | modify | +40 |
| `core/utils/event_bus.gd` | modify | +10 |
| `tests/run_tests.gd` | modify | +120 (4 новых теста) |

**Итого:** ~260 строк, 1 новый класс, 2 модифицированных, 4 новых теста.

---

## Тесты / Валидация

### Прогон после каждой задачи
```bash
cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler"
/tmp/godot47.exe --headless --script tests/run_tests.gd
```

**Ожидаемая динамика:**
- Task 1: 134/134 (константы, не ломаем)
- Task 2: 135/135 (1 новый)
- Task 3: 136/136 (1 новый)
- Task 4: 137/137 (1 новый)
- Task 5: 139/139 (2 новых)
- Task 6: 140/140 (1 новый)

### Editor-mode check (после Task 2 и Task 4)
```bash
/tmp/godot47.exe --headless --editor --quit
```
Проверяет class_name registry — должны пройти без ошибок.

### Manual smoke (опционально, после всех тасков)
```bash
/tmp/godot47.exe --path "C:/Users/user/Documents/GodotProjects/RogueAutoBattler"
```
Открыть в редакторе, запустить main.tscn, выиграть 1 бой, проверить что появляется reward screen (сейчас только в логах, UI — в S4.x).

---

## Риски и tradeoffs

| Риск | Митигация |
|---|---|
| R1: REWARD всегда показывается — игрок раздражается | Task 5 даёт skip_reward. Можно потом UI-кнопку "Skip" |
| R2: Reward предлагает tier 1 на 9 раунде — скучно | Tier-weighting в Task 3: 10% шанс на tier+1 |
| R3: Детерминизм ломается если reward считается до seed_run | generate_offer использует Rng.*, но seed уже выставлен в start_run. Тест Task 3 явно это проверяет |
| R4: EventBus.signal не существует (для reward_offered/chosen) | Task 4 явно добавляет в event_bus.gd |
| R5: Skip reward без UI — никто не знает что можно пропустить | Это сознательное решение — UI в S4.x, core-логика готова |
| R6: Потеря обратной совместимости с сохранениями | `RunState` не меняется, новые поля только в `RewardScreen` (transient) |

---

## Open questions (для UX-решения в S4.x)

1. **Можно ли продать reward-юнита обратно?** Сейчас `bench` не имеет UI. Позже.
2. **Refresh reward за gold?** Как reroll в TFT. Позже.
3. **Hero-specific reward (как в Slay the Spire)?** Пока нет, все 12 юнитов доступны.
4. **Reward для врагов?** Сейчас reward только для игрока.

Эти вопросы не блокируют S3.1.5 — отложены на S4.

---

## Handoff

После завершения плана:
- 6 коммитов (по одному на task)
- 140/140 тестов зелёные
- Core-логика reward готова
- UI подключение — следующий спринт (S4.x battle UI)
