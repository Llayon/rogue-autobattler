# Sprint 3.2: Meta Progression Unlocks

> **For Hermes:** TDD (RED → GREEN → commit) на каждый Task. S3.2 опирается на существующий
> foundation: `MetaProfile`, `UnlockManager`, `SaveService`, `award_souls` уже зовётся
> в `_end_run()`. Не хватает только триггера unlock'а + сигнала для UI.

**Goal:** За каждую победу в ране игрок разблокирует 1 нового юнита (случайно из `UnitsMeta`).
Это **persistent meta progression** между ранами — `MetaProfile` сохраняется в `user://saves/meta.tres`.

**Architecture:**
- `Balance`: константы `META_UNLOCKS_PER_WIN`, `META_SOULS_PER_ROUND`
- `UnlockManager.grant_random_unit(profile, round_index)` — выбирает из `UnitsMeta.all_ids()`
  того, кого ещё нет в `profile.unlocked_units`. Tier-weighted по `round_index` (как в reward).
- `RunController._end_run(won=true)` → вызывает unlock + шлёт `GameBus.emit_unit_unlocked(...)`
- `EventBus.signal unit_unlocked(id)` — для будущего UI

**Tech Stack:** GDScript 2.0, Godot 4.7, TDD, single source of truth в `core/balance.gd`.

---

## Контекст (что уже есть)

| Компонент | Статус |
|---|---|
| `MetaProfile` | ✅ есть — `unlocked_units`, `unlocked_enemies`, `soul_currency`, `total_runs/wins`, `best_round` |
| `UnlockManager` | ✅ есть — `grant_unit`, `grant_enemy`, `award_souls`, `is_unit_unlocked` |
| `SaveService.save_meta(profile)` | ✅ есть — вызывается в `_end_run()` |
| `SaveService.load_meta()` | ✅ есть — вызывается в `_ready()` |
| `UnitsMeta.all_ids()` | ✅ есть с S3.1.5 — 15 unit IDs |
| `Rng.randf`, `Rng.randi_range` | ✅ seeded — детерминизм сохранится |
| `award_souls` в `_end_run` | ✅ есть — за каждый раунд |

**Что НЕ хватает:**
1. Триггер `grant_unit` после победы (сейчас `_end_run(true)` не даёт unlock)
2. Логика "случайный юнит, которого ещё нет"
3. Signal для UI: `unit_unlocked(unit_id)` в GameBus

**Что НЕ делаем в S3.2:**
- UI для уведомления "вы разблокировали X" (отдельный спринт S4.x)
- Unlock врагов (другая механика — спавн-пул)
- "Выбор из 3" вместо случайного (другая механика — пикап reward)
- Shop.refresh уже использует `profile.unlocked_units` — это будет работать само

---

## Архитектурные решения

### D1: Сколько юнитов давать за победу?

**Выбор:** 1 юнит за победу (`META_UNLOCKS_PER_WIN = 1`).

**Почему:**
- 1/день прогрессии = стимул без перебора (на 10 побед = 10 юнитов в коллекции)
- Больше = слишком быстро исчерпается пул (15 юнитов всего)
- Меньше = слишком медленно для Steam игроков

### D2: Tier-weighting?

**Выбор:** Как в `RewardScreen` — 60% target tier, 30% tier-1, 10% tier+1, по `round_index`.

**Почему:**
- Consistency с reward screen (игрок ожидает такую же логику)
- Поздние победы → чаще tier-3 юниты
- Это **мета-уанлок** — после ран-победы игрок получает более сильного юнита

### D3: Детерминизм

**Выбор:** Reuse тот же `Rng` — `state.seed` рана = `Rng.seed_run()` уже вызван в `start_run()`.
Unlock использует **следующие** случайные числа — нет отдельного seed.

**Почему:**
- Тот же seed рана → тот же unlock sequence
- Меньше state для тестов
- Replay-friendly (будущее)

### D4: Edge case — все юниты unlocked

**Выбор:** `grant_random_unit` возвращает `&""` (empty StringName). Никаких ошибок, signal не шлётся.

**Почему:**
- Не ломаем логику `_end_run`
- Можно показать в UI "all units unlocked!" (позже)
- Сохраняем простоту

---

## Step-by-Step Plan

### Task 1: Balance constants для meta unlocks

**Files:** Modify `core/balance.gd` (добавить секцию "Meta progression (S3.2)")

**Step 1:** Добавить константы:
```gdscript
# === Meta progression (S3.2) ===
## Сколько юнитов разблокировать за каждую победу.
## v1: 1. Если игрок выиграл 10 побед подряд → 10 новых юнитов.
const META_UNLOCKS_PER_WIN: int = 1
## Сколько souls даётся за каждый пройденный раунд (поверх unlock).
## Сейчас это hardcoded в UnlockManager.award_souls(state.round_index),
## но через константу проще балансить.
const META_SOULS_PER_ROUND: int = 1
## Max souls в MetaProfile (anti-cheat / anti-overflow).
const META_SOULS_CAP: int = 99999
```

**Step 2:** Запустить тесты — должны остаться 155/155 (никаких поломок).

**Step 3:** Commit: `chore(s3.2): add meta progression balance constants`

---

### Task 2: `UnlockManager.grant_random_unit(profile, round_index)` — RED → GREEN

**Files:**
- Modify: `core/progression/unlock_manager.gd`
- Test: `tests/run_tests.gd` (добавить `_test_meta_unlock_grant_random`)

**Step 1:** Тест сначала (RED):
```gdscript
func _test_meta_unlock_grant_random() -> void:
    print("[test] S3.2: UnlockManager.grant_random_unit()")
    var profile: MetaProfile = MetaProfileScript.new()
    # Свежий профиль: warrior+archer+goblin. grant_random должен дать нового.
    var unlocked: StringName = UnlockManager.grant_random_unit(profile, 5)
    _assert(unlocked != &"", "выдал непустой id")
    _assert(not UnlockManager.is_unit_unlocked(_make_default_profile(), unlocked),
        "выданный юнит не был в стартовом наборе")
    _assert(UnlockManager.is_unit_unlocked(profile, unlocked),
        "выданный юнит теперь в profile.unlocked_units")

func _test_meta_unlock_grant_random_determinism() -> void:
    print("[test] S3.2: grant_random_unit детерминизм (тот же seed = тот же unlock)")
    Rng.seed_run(555)
    var p1: MetaProfile = MetaProfileScript.new()
    var id1: StringName = UnlockManager.grant_random_unit(p1, 4)
    Rng.seed_run(555)
    var p2: MetaProfile = MetaProfileScript.new()
    var id2: StringName = UnlockManager.grant_random_unit(p2, 4)
    _assert(id1 == id2, "тот же seed → тот же unlock (got %s vs %s)" % [str(id1), str(id2)])

func _test_meta_unlock_grant_random_all_unlocked() -> void:
    print("[test] S3.2: grant_random_unit когда все unlocked → empty")
    var profile: MetaProfile = MetaProfileScript.new()
    for id in UnitsMetaScript.all_ids():
        UnlockManager.grant_unit(profile, id)
    var unlocked: StringName = UnlockManager.grant_random_unit(profile, 5)
    _assert(unlocked == &"", "все unlocked → return empty (got %s)" % str(unlocked))

func _test_meta_unlock_tier_weighted_round() -> void:
    print("[test] S3.2: tier-weighted по round_index")
    # round 1-3 → tier 1 (warrior/archer/cleric обычно уже unlocked)
    # round 9 → tier 3 — шанс paladin/necromancer/knight/elementalist
    Rng.seed_run(111)
    var p_round9: MetaProfile = MetaProfileScript.new()
    var id: StringName = UnlockManager.grant_random_unit(p_round9, 9)
    var def: Resource = ContentDB_static.get_by_id(id)
    _assert(def != null, "tier-3 юнит существует: %s" % id)
    _assert(def.tier >= 2, "round 9 → tier >= 2 (got %d for %s)" % [def.tier, id])
```

**Step 2:** Реализация в `unlock_manager.gd`:
```gdscript
## S3.2: выдаёт случайного юнита из тех, кого ещё нет в profile.unlocked_units.
## Tier-weighted по round_index: 60% target, 30% target-1, 10% target+1.
## Возвращает id нового юнита, или &"" если все уже unlocked.
## Детерминировано через Rng (тот же seed = тот же unlock).
static func grant_random_unit(profile: MetaProfile, round_index: int) -> StringName:
    if profile == null:
        return &""
    var target_tier: int = clampi(round_index / 3, 1, 3)
    var candidates: Array[StringName] = []
    # Try 50 attempts: pick tier, pick unit, skip if already unlocked.
    for _i in 50:
        var tier: int = _pick_unlock_tier(target_tier)
        var tier_pool: Array[StringName] = _unlocked_candidates_by_tier(profile, tier)
        if tier_pool.is_empty():
            continue
        var pick: StringName = tier_pool[Rng.randi_range(0, tier_pool.size() - 1)]
        if pick not in profile.unlocked_units:
            profile.unlocked_units.append(pick)
            GameLog.info("unlock", "Meta unit granted", {"id": pick, "round": round_index, "tier": tier})
            return pick
    # Fallback: 50 attempts exhausted — все unlocked в этом tier, ищем по всем tiers.
    for tier in [1, 2, 3]:
        var pool: Array[StringName] = _unlocked_candidates_by_tier(profile, tier)
        if not pool.is_empty():
            var fallback_pick: StringName = pool[Rng.randi_range(0, pool.size() - 1)]
            profile.unlocked_units.append(fallback_pick)
            GameLog.info("unlock", "Meta unit granted (fallback)", {"id": fallback_pick, "round": round_index, "tier": tier})
            return fallback_pick
    # Ничего не нашли — все unlocked.
    GameLog.debug("unlock", "No units to unlock", {"round": round_index})
    return &""


## Возвращает юнитов tier=tier из UnitsMeta, которых ещё нет в profile.
static func _unlocked_candidates_by_tier(profile: MetaProfile, tier: int) -> Array[StringName]:
    var all_tier: Array[StringName] = UnitsMeta.ids_by_tier(tier)
    var result: Array[StringName] = []
    for id in all_tier:
        if id not in profile.unlocked_units:
            result.append(id)
    return result


## Tier-вeс для unlock: 60% target, 30% target-1, 10% target+1.
static func _pick_unlock_tier(target: int) -> int:
    var r: float = Rng.randf()
    if r < 0.6:
        return target
    elif r < 0.9:
        return maxi(1, target - 1)
    else:
        return mini(3, target + 1)
```

**Step 3:** Run tests — должны пройти.

**Step 4:** Commit: `feat(s3.2): UnlockManager.grant_random_unit tier-weighted`

---

### Task 3: RunController._end_run(true) → unlock + GameBus signal

**Files:**
- Modify: `core/progression/run_controller.gd`
- Modify: `core/utils/event_bus.gd`
- Test: `tests/run_tests.gd`

**Step 1:** Добавить signal в `event_bus.gd`:
```gdscript
signal unit_unlocked(unit_id: StringName)  # S3.2: meta progression

static func emit_unit_unlocked(unit_id: StringName) -> void:
    var inst: Node = _instance()
    if inst != null:
        inst.unit_unlocked.emit(unit_id)
```

**Step 2:** Тест (RED):
```gdscript
func _test_run_controller_meta_unlock_on_win() -> void:
    print("[test] S3.2: RunController выдаёт unlock после победы на MAX_ROUND")
    var ctrl: Node = RunControllerScript.new()
    get_root().add_child.call_deferred(ctrl)
    await process_frame
    # Свежий профиль без extra unlocks.
    ctrl.profile = MetaProfileScript.new()
    var unlocked_before: int = ctrl.profile.unlocked_units.size()
    ctrl.start_run(42)
    # Сразу завершаем ран победой (round_index = MAX_ROUND).
    ctrl.state.round_index = BalanceScript.MAX_ROUND
    ctrl.state.wins = BalanceScript.MAX_ROUND - 1
    ctrl._end_run(true)
    _assert(ctrl.profile.unlocked_units.size() >= unlocked_before + 1,
        "после _end_run(true) profile получил +1 unlock (was %d, now %d)" %
        [unlocked_before, ctrl.profile.unlocked_units.size()])
    _cleanup_ctrl(ctrl)
```

**Step 3:** В `run_controller.gd._end_run`:
```gdscript
func _end_run(won: bool) -> void:
    _set_phase(Phase.GAMEOVER)
    profile.total_runs += 1
    if won:
        profile.total_wins += 1
        # S3.2: за каждую победу — unlock юнита.
        for _i in BalanceScript.META_UNLOCKS_PER_WIN:
            var new_id: StringName = UnlockManager.grant_random_unit(profile, state.round_index)
            if new_id != &"":
                GameBus.emit_unit_unlocked(new_id)
    profile.best_round = maxi(profile.best_round, state.round_index)
    UnlockManager.award_souls(profile, state.round_index)
    SaveService.save_meta(profile)
    SaveService.save_run(state)
    run_ended.emit(won)
    GameLog.info("run", "Run ended", {"round": state.round_index, "won": won})
```

**Step 4:** Run tests — 158/158 (155 + 3 новых).

**Step 5:** Commit: `feat(s3.2): RunController grants meta unlock on win`

---

### Task 4: Edge cases — defeat run, save round-trip

**Files:**
- Test: `tests/run_tests.gd`

**Step 1:** Тест — defeat НЕ даёт unlock:
```gdscript
func _test_run_controller_no_unlock_on_defeat() -> void:
    print("[test] S3.2: defeat на ран не даёт unlock")
    var ctrl: Node = RunControllerScript.new()
    get_root().add_child.call_deferred(ctrl)
    await process_frame
    ctrl.profile = MetaProfileScript.new()
    var unlocked_before: int = ctrl.profile.unlocked_units.size()
    ctrl.start_run(99)
    ctrl._end_run(false)  # проигрыш
    _assert(ctrl.profile.unlocked_units.size() == unlocked_before,
        "defeat → 0 новых unlock (was %d, now %d)" %
        [unlocked_before, ctrl.profile.unlocked_units.size()])
    _cleanup_ctrl(ctrl)
```

**Step 2:** Тест — save round-trip:
```gdscript
func _test_meta_save_roundtrip() -> void:
    print("[test] S3.2: MetaProfile save → load сохраняет unlocked_units")
    var p: MetaProfile = MetaProfileScript.new()
    UnlockManager.grant_unit(p, &"mage")
    UnlockManager.grant_unit(p, &"paladin")
    var ok: bool = SaveService.save_meta(p)
    _assert(ok, "save_meta returned true")
    var loaded: MetaProfile = SaveService.load_meta()
    _assert(loaded != null, "load_meta не null")
    _assert(loaded.unlocked_units.has(&"mage"), "mage в unlocked после load")
    _assert(loaded.unlocked_units.has(&"paladin"), "paladin в unlocked после load")
```

**Step 3:** Прогнать — 160/160.

**Step 4:** Commit: `test(s3.2): meta unlock edge cases + save roundtrip`

---

### Task 5: Editor-mode check + final commit

**Files:** ничего, только verification.

**Step 1:** `godot47 --headless --editor --quit` — class_name registry check.

**Step 2:** `godot47 --headless --path . --script tests/run_tests.gd` — 160/160 expected.

**Step 3:** Если всё зелёное — финальный commit:
```bash
git commit -m "feat(s3.2): meta progression unlocks (1 win = 1 unit, tier-weighted)"
```

---

## Файлы изменяются

| Файл | Тип | Строк |
|---|---|---|
| `core/balance.gd` | modify | +10 |
| `core/progression/unlock_manager.gd` | modify | +60 |
| `core/progression/run_controller.gd` | modify | +10 |
| `core/utils/event_bus.gd` | modify | +5 |
| `tests/run_tests.gd` | modify | +90 (5 тестов) |

**Итого:** ~175 строк, 0 новых классов, 4 модифицированных файла.

---

## Тесты / Валидация

### Прогон после каждой задачи
```bash
cd "C:/Users/user/Documents/GodotProjects/RogueAutoBattler"
/tmp/godot47.exe --headless --script tests/run_tests.gd
```

**Ожидаемая динамика:**
- Task 1: 155/155 (константы)
- Task 2: 158/158 (3 новых)
- Task 3: 159/159 (1 новый)
- Task 4: 161/161 (2 новых)

### Editor-mode check (после Task 3)
```bash
/tmp/godot47.exe --headless --editor --quit
```

---

## Риски

| Риск | Митигация |
|---|---|
| R1: Tier-вeс тот же что в reward screen — игрок предскажет unlocks | Это **фича** — консистентность. Если хотите surprise — отдельная механика позже |
| R2: 1/победу — слишком быстро/медленно | Баланс-константа `META_UNLOCKS_PER_WIN`, легко менять |
| R3: Souls уже считаются в `award_souls(state.round_index)` — дубль? | Нет — souls это мета-валюта, unlocks это коллекция. Разные системы |
| R4: Save в `user://saves/meta.tres` перезаписывается между тестами | Используем `--headless` — user dir изолирован per run. Если будут конфликты — переименуем |

---

## Handoff

После S3.2:
- 161/161 тестов зелёные
- 5 коммитов (по одному на task)
- Meta progression работает: победа → unlock → save → load в следующем ране виден в shop
- UI уведомление "X разблокирован!" — S4.x (battle UI sprint)
