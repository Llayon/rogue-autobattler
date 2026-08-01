# Sprint 5.3: RunController ↔ EncounterMap wiring

> **For Hermes:** Execute task-by-task. Strict RED → GREEN → commit. S5.3 is the last step of S5 (encounter map is wired into the actual run). No new UI files — `BattleScene` consumes the existing S5.2 `EncounterMapScene`.

**Goal:** Подключить S5.1 `EncounterMap` к `RunController`: после `_on_battle_ended()` ран переходит в фазу `MAP`, игрок выбирает следующий узел, контроллер диспатчит combat (`start_battle()`) или service-эффект (`HEAL`/`TREASURE`/`MERCHANT`/`REST`/`SHRINE`).

**Architecture:** `RunController.Phase` расширен до `MAP = 4` и `SERVICE = 5`. Между раундом и `MAP` нет промежуточной фазы — `_on_battle_ended()` после win идёт в `MAP` (кроме round 1, где сейчас идёт сразу `PREP`, чтобы старт рана был немедленным). После выбора combat-узла — `start_battle()`; после service — эффект → обратно в `MAP` (если `state.round_index <= MAX_ROUND`) или `GAMEOVER`.

**Tech Stack:** GDScript 2.0, Godot 4.7, TDD. Никаких новых сцен; никаких изменений в `EncounterMap` / `EncounterNode` / `EncounterType`.

---

## Контекст

| Компонент | Сейчас |
|---|---|
| `EncounterMap` (core/encounter/) | ✅ `generate(seed)`, `start_run()`, `choose_next()`, `get_current_node_id()`, `get_available_next_ids()`, `is_combat()` |
| `EncounterNode.is_combat()` | ✅ combat = COMBAT/ELITE/BOSS; service = HEAL/TREASURE/MERCHANT/REST/SHRINE |
| `EncounterMapView` + `EncounterMapScene` | ✅ S5.2 — `node_selected(node_id)` signal, `set_encounter_map()`, preview работает standalone |
| `RunController` | `Phase { PREP, BATTLE, REWARD, GAMEOVER }`, `_on_battle_ended` ведёт в REWARD/PREP/end |
| `Shop` | ✅ `refresh(pool)` + `offer_at(slot)`; уже используется в PREP |
| `UnlockManager.grant_random_unit(profile, round_index)` | ✅ готов для TREASURE |
| `BattleScene` (scenes/battle/) | подписан на `_bus.phase_changed`, сейчас обрабатывает только PREP/BATTLE/REWARD/GAMEOVER |
| Baseline | 441 assertions / 0 failed; lint 0 errors; working tree clean |

## Архитектурные решения

### D1 — `Phase.MAP = 4` (новый) и `Phase.SERVICE = 5` (опционально)

**Выбор:** Combat dispatch не нуждается в отдельной SERVICE-фазе — service-эффект синхронен и возвращает `MAP` сразу. Но отдельная `SERVICE` фаза нужна, если эффект длительный (анимация). На этом спринте — service-эффект синхронен, переход напрямую MAP↔PREP→BATTLE.

**Почему:** минимум изменений. Если потом захотим анимацию — добавим SERVICE-фазу и буферизованный effect step.

### D2 — Round 1 пропускает MAP

**Выбор:** на первом раунде `_on_battle_ended()` после первой победы сразу идёт в `PREP` (как сейчас). На раундах 2..MAX_ROUND-1 — в `MAP`.

**Почему:** стартовый набор юнитов уже на доске, MAP даёт пустой выбор. Кроме того, это сохраняет существующие тесты `_test_run_controller_no_reward_on_first_win` и др., которые закладываются на поведение round 1 → PREP.

### D3 — Service-эффекты как pure функции

**Выбор:** `_apply_service_effect(node)` switch по `node.type` (HEAL/TREASURE/MERCHANT/REST/SHRINE). Combat branch делегирует в `start_battle()`.

**Почему:** Без отдельного `EncounterEffect` Resource — эффекты это 5 простых функций с конкретными числами в `Balance`. Если появятся новые варианты — вынесем в отдельный класс.

### D4 — HEAL: heal HP-ratio + +1 life (cap)

**Выбор:** heal всех юнитов игрока по `Balance.MAP_HEAL_HP_RATIO * max_hp`, и `lives = min(lives+1, Balance.STARTING_LIVES)`.

**Почему:** HEAL — это "rest stop". Должна вернуть жизни и подлечить юнитов, но не быть overpowered (только ratio + 1 жизнь).

### D5 — TREASURE: gold + random unit (через UnlockManager)

**Выбор:** `state.gold += Balance.MAP_TREASURE_GOLD`, плюс `UnlockManager.grant_random_unit(profile, round_index)` для meta unlock.

**Почему:** TREASURE даёт немедленный gold + нового юнита в коллекцию (мета-прогрессия). Не даёт юнита на доску — это остаётся через shop.

### D6 — MERCHANT: открыть Shop в существующем `_refresh_shop()`

**Выбор:** MERCHANT-узел → `shop.refresh(profile.unlocked_units)`. UI покупает через `run_controller.buy_unit(slot)`. Скидка `MAP_MERCHANT_DISCOUNT` не применяется в v1 (число существует для будущих итераций).

**Почему:** минимальное изменение — Shop уже работает в PREP, MERCHANT просто переходит в PREP-стиль флоу без shop refresh penalty. v2 добавит скидку.

### D7 — REST: heal + free upgrade

**Выбор:** heal всех юнитов по `MAP_REST_HP_RATIO * max_hp`, плюс `+1 attack` всем юнитам игрока (mutable mod).

**Почему:** REST — "campfire". Heal + buff. Простая реализация: +1 attack permanent на ран.

### D8 — SHRINE: random buff (1 из 4)

**Выбор:** random choice из {`gold+5`, `lives+1`, `all_units +max_hp+5`, `all_units +attack+1`}. Использует `Rng.randi_range()` (детерминированно).

**Почему:** SHRINE — "random event". v1 даёт один buff; v2 может дать выбор игроку.

### D9 — После service-эффекта — снова MAP или GAMEOVER

**Выбор:** `round_index < MAX_ROUND` → `MAP`. `round_index == MAX_ROUND` и текущий узел — boss → `GAMEOVER`. (Это уже происходит внутри `start_battle()` через `state.round_index > MAX_ROUND` check после win, но с MAP flow надо обработать случай "выбрали BOSS → `start_battle()` → победа → `round_index > MAX_ROUND` → `_end_run(true)`".)

**Почему:** Уже существующая логика в `_on_battle_ended` обработает финальный бой. После проигрыша — `lives--` → если 0 → GAMEOVER. После победы над boss — `_end_run(true)` → GAMEOVER.

### D10 — BattleScene показывает map в фазе MAP

**Выбор:** `BattleScene._ready()` создаёт `EncounterMapScene`, кладёт поверх `battle_view`. На `phase_changed(MAP)` — вызывает `set_encounter_map(ctrl.encounter_map)` и поднимает наверх. На других фазах — прячет.

**Почему:** Минимум изменений в scene, scene-scoped state, view переиспользуется из S5.2.

---

## Step-by-Step Plan

### Task 1 — Phase enum + RunState.current_encounter_id (RED → GREEN)

**Files:** `core/progression/run_controller.gd`, `core/progression/run_state.gd`, `core/balance.gd`, `tests/run_tests.gd`

1. **RED:** `_test_run_controller_phase_map_exists` — `RunController.Phase.MAP == 4` and `Phase.SERVICE == 5`.
2. **RED:** `_test_run_state_current_encounter_id` — `RunState.new().current_encounter_id == -1`, `encounter_visited_ids.is_empty()`.
3. **GREEN:** добавить `MAP = 4`, `SERVICE = 5` в Phase. Добавить 2 поля в `RunState` + bump `SAVE_VERSION = 2` + `_migrate_from_v1` в `SaveService` (или просто initialize defaults через `from_dict()`).
4. **GREEN:** добавить balance constants (см. D4-D8):
   ```
   MAP_HEAL_HP_RATIO: float = 0.4
   MAP_TREASURE_GOLD: int = 5
   MAP_MERCHANT_DISCOUNT: float = 0.5  # reserved for v2
   MAP_REST_HP_RATIO: float = 0.5
   MAP_REST_ATTACK_BONUS: int = 1
   MAP_SHRINE_GOLD_BONUS: int = 5
   MAP_SHRINE_HP_BONUS: int = 5
   MAP_SHRINE_ATTACK_BONUS: int = 1
   ```
5. **Verify:** full suite зелёный.
6. **Commit:** `feat(s5.3): MAP phase + service reward constants + RunState encounter tracking`

### Task 2 — Combat dispatch (RED → GREEN)

**Files:** `core/progression/run_controller.gd`, `tests/run_tests.gd`

1. **RED:** `_test_run_controller_combat_node_starts_battle` — после `_enter_map()` + `choose_next(combat_node_id)`, фаза = `BATTLE`, `runner != null`.
2. **GREEN:** `_on_node_selected(node_id)` dispatch в RunController:
   - если `phase != Phase.MAP` → return
   - `chosen = encounter_map.choose_next(node_id)` (если false → return)
   - если `chosen.is_combat()` → `start_battle()`
   - иначе → `_apply_service_effect(chosen)`
   - сигнал `node_dispatched(node_id, kind)` для UI
3. **Verify:** новый тест зелёный, существующие не сломались.
4. **Commit:** `feat(s5.3): dispatch combat nodes to BattleRunner`

### Task 3 — Service effects: HEAL, TREASURE, MERCHANT (RED → GREEN)

**Files:** `core/progression/run_controller.gd`, `tests/run_tests.gd`

1. **RED:** 3 теста:
   - HEAL: heal all player units by 40% + lives +1 (cap)
   - TREASURE: gold += MAP_TREASURE_GOLD + meta unlock нового юнита
   - MERCHANT: после effect phase=PREP, shop обновлён (offered_ids != [])
2. **GREEN:** `_apply_service_effect(node)` switch с HEAL/TREASURE/MERCHANT ветками.
3. **Verify:** 3 новых теста зелёные.
4. **Commit:** `feat(s5.3): service effects HEAL/TREASURE/MERCHANT`

### Task 4 — Service effects: REST, SHRINE (RED → GREEN)

**Files:** `core/progression/run_controller.gd`, `tests/run_tests.gd`

1. **RED:** 2 теста:
   - REST: heal all units by 50% + bench_unit_ids получают +1 attack
   - SHRINE: один из 4 buffs применён (gold_changed / lives_changed / hp_changed / attack_changed)
2. **GREEN:** REST и SHRINE ветки в switch.
3. **Verify:** 2 новых теста зелёные.
4. **Commit:** `feat(s5.3): service effects REST/SHRINE`

### Task 5 — Phase flow: `_on_battle_ended` → MAP (RED → GREEN)

**Files:** `core/progression/run_controller.gd`, `tests/run_tests.gd`

1. **RED:** `_test_run_controller_phase_flow_to_map` — после win в round 2 → phase = MAP, `encounter_map != null`, `get_current_node_id() != -1`.
2. **RED:** `_test_run_controller_phase_flow_round1_to_prep` — после win в round 1 → phase = PREP (без MAP), `encounter_map == null` или current = layer1 node.
3. **GREEN:** модифицировать `_on_battle_ended()`:
   - победа + `round_index == 2` → `_enter_map()`
   - победа + `round_index > 2 && < MAX_ROUND+1` → `_enter_map()`
   - победа + `round_index == 1` → `_set_phase(Phase.PREP)` (как сейчас)
4. **`_enter_map()`:** создать `EncounterMap` (lazy), `generate(state.seed)`, `start_run()`, `_set_phase(Phase.MAP)`.
5. **Verify:** оба теста зелёные + все предыдущие (REWARD tests должны по-прежнему работать — REWARD теперь ПЕРЕД MAP).
6. **Commit:** `feat(s5.3): phase flow win → MAP with lazy EncounterMap generation`

> **Важно:** REWARD фаза по-прежнему между win и MAP. Round 1 → win → PREP (no reward, no map). Round 2 → win → REWARD → choose_reward → MAP → combat → REWARD → MAP → ... → boss → win → GAMEOVER.

### Task 6 — EventBus signals (RED → GREEN)

**Files:** `core/utils/event_bus.gd`, `core/progression/run_controller.gd`, `tests/run_tests.gd`

1. **RED:** `_test_eventbus_node_dispatched_signal_emits` — `GameBus.emit_node_dispatched(...)` emits signal with (node_id, kind).
2. **GREEN:** добавить сигнал `node_dispatched(node_id: int, kind: int)` + static helper `emit_node_dispatched(node_id, kind)`. RunController.emit_node_dispatched() в `_on_node_selected()`.
3. **Verify:** 1 новый тест зелёный.
4. **Commit:** `feat(s5.3): emit node_dispatched signal from RunController`

### Task 7 — BattleScene wiring (RED → GREEN)

**Files:** `scenes/battle/battle_scene.gd`, `tests/run_tests.gd`

1. **RED:** `_test_battle_scene_shows_encounter_map_on_map_phase` — scene создаёт encounter_map, при `phase = MAP` показывает `encounter_map_scene` (visible), при других фазах скрывает.
2. **GREEN:** `BattleScene._ready()`:
   - импортирует `EncounterMapSceneScript`
   - создаёт `encounter_map_scene` instance, `add_child()`, `hide()` initial
   - подписывается на `run_controller.phase_changed` — в зависимости от фазы show/hide + set_encounter_map
3. **Verify:** тест зелёный + scene parses.
4. **Commit:** `feat(s5.3): BattleScene shows encounter map on MAP phase`

### Task 8 — Finalization (verify)

1. `/tmp/godot47.exe --headless --editor --quit` — class registry + parse.
2. `/tmp/godot47.exe --headless --path . --script tests/run_tests.gd` — full suite.
3. `python tools/lint_anti_patterns.py` — lint.
4. Capture one frame of main scene via headless render (только если time permits).
5. Commit only if cleanup (`.uid` files или unused locals) — else skip.
6. Optional: `docs(s5.3): update roadmap — S5.4 should consume `RunController.encounter_map` + add encounter effects polish` если есть полезные уроки.

---

## Файлы изменяются

| Файл | Тип | LOC |
|---|---|---|
| `core/progression/run_controller.gd` | modify | +~140 (Phase.MAP/SERVICE, `_enter_map()`, `_on_node_selected()`, `_apply_service_effect()`) |
| `core/progression/run_state.gd` | modify | +5 (current_encounter_id, encounter_visited_ids, SAVE_VERSION=2) |
| `core/balance.gd` | modify | +8 (MAP_HEAL/TREASURE/MERCHANT/REST/SHRINE constants) |
| `core/utils/event_bus.gd` | modify | +5 (node_dispatched signal + helper) |
| `core/save/save_service.gd` | modify | +~10 (`_migrate_to_v2` если from_dict пустой) |
| `scenes/battle/battle_scene.gd` | modify | +~25 (encounter_map_scene instance + phase wiring) |
| `tests/run_tests.gd` | modify | +~120 (8-10 новых тестов, ~50 assertions) |

**Итого:** ~310 строк новых, 6 файлов модифицированы, 0 новых сцен.

## Тесты / Валидация

| Task | До | После |
|---|---|---|
| 1 (Phase+State+Balance) | 441 | 449 (+8) |
| 2 (Combat dispatch) | 449 | 455 (+6) |
| 3 (HEAL/TREASURE/MERCHANT) | 455 | 470 (+15) |
| 4 (REST/SHRINE) | 470 | 485 (+15) |
| 5 (Phase flow) | 485 | 495 (+10) |
| 6 (EventBus signal) | 495 | 500 (+5) |
| 7 (BattleScene wiring) | 500 | 510 (+10) |
| 8 (finalize) | 510 | 510 (verify only) |

## Риски

| Риск | Митигация |
|---|---|
| REWARD phase становится "зажатой" между win и MAP — старые reward тесты могут сломаться | Запускать full suite после каждого Task; reward тесты продолжают проверять `choose_reward/skip_reward`, не должны ломаться. |
| Tab corruption в patch tool на multi-line additions | Писать additions через `execute_code` (Python) если patch tool выдаёт broken diff |
| Round 1 flow меняется — `_test_run_controller_no_reward_on_first_win` может ломаться | Round 1 в Task 5 идёт в PREP без MAP (как сейчас) — тест должен проходить |
| Service effects могут дать больше золота/HP чем ожидалось | Все числа в Balance — легко крутить |
| Scene preload для `EncounterMapScene` может циркулярно зависнуть от RunController | EncounterMapSceneScript — script-only reference, как BattleViewScript |

## Acceptance Criteria

- [ ] `RunController.Phase.MAP` существует (= 4).
- [ ] После победы на round 2..MAX_ROUND-1 → `phase = MAP`, `encounter_map != null`.
- [ ] После победы на round 1 → `phase = PREP` (как было).
- [ ] `_on_node_selected(combat_node_id)` → `phase = BATTLE` через 1 frame.
- [ ] `_on_node_selected(HEAL_node_id)` → heals units + lives+1.
- [ ] `_on_node_selected(TREASURE_node_id)` → gold += 5 + новый юнит в profile.unlocked.
- [ ] `_on_node_selected(MERCHANT_node_id)` → phase = PREP, shop refreshed.
- [ ] `_on_node_selected(REST_node_id)` → heal + attack bonus.
- [ ] `_on_node_selected(SHRINE_node_id)` → один из 4 buffs применён.
- [ ] `GameBus.node_dispatched(node_id, kind)` эмитится при каждом choose_next.
- [ ] `BattleScene` показывает encounter map при phase=MAP, скрывает иначе.
- [ ] Editor-mode, full suite, lint зелёные.
- [ ] Working tree clean после finalization.

## Notes для реализатора

- **Service effect → MAP:** после применения эффекта сразу `_enter_map()` если `round_index <= MAX_ROUND`; иначе `_end_run(true)`. Для round N где current_encounter_id — boss (depth 10), после эффекта не должно быть MAP (т.к. boss уже побеждён); но в нашем flow service-эффект на boss невозможен (boss всегда COMBAT type по S5.1).
- **MERCHANT не отдельная фаза:** MERCHANT переходит в PREP и обновляет shop; UI остаётся прежним (покупка через `buy_unit`).
- **SHRINE buff choices:** храни в `Balance.MAP_SHRINE_*` constants, легко крутить.
- **Patch tool:** при записи больших additions используй Python `readlines()/writelines()` (см. memory: "patch tool fragility").
- **Тесты:** используй шаблон из существующих — `_assert(cond, "message %d" % var)`.