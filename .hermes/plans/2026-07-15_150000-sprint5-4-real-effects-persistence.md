# Sprint 5.4: настоящие service-эффекты + persistence EncounterMap

> **For Hermes:** TDD на каждый Task. RED → GREEN → commit. S5.4 закрывает placeholder'ы в S5.3 и доводит service-узлы до working state.

**Goal:** Сделать service-эффекты настоящими (HP-restore работает, REST/SHRINE buff'ы применяются) и persistence EncounterMap (save/load восстанавливает позицию на карте).

**Architecture:**
- `RunUnitState` — новый Resource, отслеживает HP каждого юнита игрока между боями. Сейчас HP живёт только в `Combatant.health` пока `BattleContext` жив — после `start_battle()` Combatant пересоздаётся и HP теряется. Перенесём "baseline HP" в `state.unit_states: Array[RunUnitState]` параллельно с `state.player_unit_ids`.
- `Combatant._init(...)` принимает `hp_override: int = -1` чтобы применить текущий HP из RunState.
- `run_controller._apply_*_effect()` записывает изменения в `state.unit_states` **до** `save_now()`.
- `_on_battle_ended()` (loss path) уменьшает HP проигравших юнитов в `state.unit_states`.
- `resume_run()` восстанавливает `state.current_encounter_id` → генерирует карту по seed → `encounter_map.start_run()` → `_goto_node(current_encounter_id)` (новый private метод карты) либо использует текущий `get_current_node_id()` если карта уже deterministic.

**Tech Stack:** Godot 4.7, GDScript 2.0, TDD, no new scenes.

---

## Контекст

| Компонент | Сейчас |
|---|---|
| `RunController._get_player_unit_hp()` | Возвращает 0 (заглушка). Комментарий: "в v1 HP не персистится" |
| `RunController._set_player_unit_hp()` | `pass` (no-op) |
| HEAL / REST / SHRINE | `mini(max_hp, hp_now + heal)` где hp_now=0 → новый HP = `heal` |
| REST attack bonus | `state.meta_modifiers["rest_attack_bonus"]` пишется, но не применяется в Combatant |
| SHRINE attack bonus | То же самое |
| Save atomicity | `save_now()` вызывается ДО apply_service_effect — на диске сохраняется pre-effect state |
| resume_run | `state.current_encounter_id` сериализуется, но карта не регенерируется |

Baseline: 465 passed / 0 failed. Lint clean. Editor-mode clean.

---

## Архитектурные решения

### D1 — Per-unit HP через `RunUnitState`

**Выбор:** Создаём `RunUnitState extends RefCounted` с полями `unit_id: StringName`, `current_hp: int`, `max_hp: int`, `bonus_attack: int = 0`. Хранится в `state.unit_states: Array[RunUnitState]` (параллельно `player_unit_ids`). HP живёт между боями через этот state.

**Почему:** Минимальное изменение в Combatant — нужно добавить `hp_override` параметр в `_init`. Хранение HP в Resource (как RunState) даёт автоматическую сериализацию через SaveService.

**Альтернативы:**
- Persistent HP на `Combatant` — не работает, Combatant создаётся заново каждый battle.
- HP на самом `UnitDef` — нарушает immutability Resource и cross-run semantics.

### D2 — Combatant получает `hp_override`

**Выбор:** `func _init(def: Resource, hp_mul: float = 1.0, atk_mul: float = 1.0, def_mul: float = 1.0, hp_override: int = -1)`.

**Почему:** Когда start_battle() создаёт Combatant, мы передаём `state.unit_states[i].current_hp` если он есть. Если hp_override == -1 — стандартный max_hp (для совместимости со старыми тестами).

### D3 — Service-эффекты применяют к state.unit_states, потом start_battle читает

**Выбор:** HEAL/REST/SHRINE **сначала** обновляют `state.unit_states`, **потом** `save_now()`.

**Почему:** Атомарность. Save содержит post-effect state.

### D4 — REST/SHRINE attack bonus применяется в `Combatant._init(atk_mul=...)`

**Выбор:** При создании Combatant в `start_battle()`, передаём `atk_mul = 1.0 + total_attack_bonus / 100.0` где bonus = `meta_modifiers["rest_attack_bonus"] + meta_modifiers["shrine_attack_bonus"]`.

**Почему:** Чистый механизм — existing `attack_base = int(round(float(def.attack) * atk_mul))` уже работает с multiplier.

### D5 — `resume_run()` восстанавливает encounter_map

**Выбор:** `resume_run()` после `state = loaded` проверяет `state.current_encounter_id`. Если != -1, генерирует encounter_map по `state.seed` и прыгает на `current_encounter_id` через новый private method `EncounterMap.goto_node(id)`.

**Почему:** Детерминированная карта по seed — можно восстановить без сериализации. `goto_node()` мутирует current_node_id напрямую (без choose_next, чтобы не проверять visited).

### D6 — Dead юниты не воскресают

**Выбор:** Если `state.unit_states[i].current_hp == 0`, юнит не появляется на доске в следующем battle. Логика в `start_battle()` фильтрует такие id'ы.

**Почему:** Это нормальное roguelike поведение — проигранные юниты остаются мёртвыми.

---

## Step-by-Step Plan

### Task 1 — RunUnitState class + state.unit_states field

**Files:**
- Create: `core/progression/run_unit_state.gd`
- Modify: `core/progression/run_state.gd` (add `unit_states: Array[RunUnitState]`)
- Modify: `tests/run_tests.gd` (test that default RunState has empty `unit_states`)
- Modify: `core/progression/run_controller.gd` (initialize `unit_states` from `player_unit_ids` in `start_run`)

1. **RED:** test `state.unit_states.is_empty() == true` для new RunState. Запустить → RED (field doesn't exist).
2. **GREEN:** создать `RunUnitState extends RefCounted` с `unit_id: StringName`, `current_hp: int = -1`, `max_hp: int = -1`, `bonus_attack: int = 0`. В `RunState` добавить `@export var unit_states: Array[RunUnitState] = []` + bump `SAVE_VERSION = 3`. В `RunController.start_run()` создать initial `unit_states` для каждого `player_unit_ids`.
3. Verify.
4. **Commit:** `feat(s5.4): RunUnitState class tracks per-unit HP between battles`

### Task 2 — HEAL/REST/SHRINE настоящие HP эффекты

**Files:**
- Modify: `core/progression/run_controller.gd` (replace `_get_player_unit_hp` / `_set_player_unit_hp` stubs)
- Modify: `core/progression/run_controller.gd` (extend `start_battle()` to pass `hp_override` to CombatantScript.new())
- Modify: `core/battle/combatant.gd` (add `hp_override` parameter to `_init`)
- Modify: `tests/run_tests.gd` (test HEAL actually restores HP across battles)

1. **RED:** test sequence: start_run → start_battle → take lethal damage → end_battle (defeat) → MAP → HEAL → next battle → check `state.unit_states[i].current_hp` повышен. Запустить → RED (HEAL возвращает current_hp = 0).
2. **GREEN:** implement `_get_player_unit_hp(id)` через `state.unit_states`; `_set_player_unit_hp(id, hp)` обновляет state. Combatant._init принимает `hp_override` и использует его для `health.configure(hp_override)` если > 0. start_battle() собирает hp из state.
3. Verify.
4. **Commit:** `feat(s5.4): HEAL/REST/SHRINE apply real HP delta via unit_states`

### Task 3 — REST/SHRINE attack bonus applies to Combatant

**Files:**
- Modify: `core/progression/run_controller.gd` (compute total_attack_bonus in `start_battle()`)
- Modify: `core/battle/combatant.gd` (already supports atk_mul, just verify it works correctly)
- Modify: `tests/run_tests.gd` (test REST increases attack of next battle's player unit)

1. **RED:** test: start_run → start_battle → win → MAP → REST → start_battle (next) → check player unit's `attack_base` = base_attack + 1.
2. **GREEN:** in `start_battle()`, calculate `total_attack_bonus = state.meta_modifiers.get("rest_attack_bonus", 0) + state.meta_modifiers.get("shrine_attack_bonus", 0)`. Pass `atk_mul = 1.0 + total_attack_bonus / 100.0` to `CombatantScript.new()`. Reset bonuses after they're applied? No — bonuses persist for the run.
3. Verify.
4. **Commit:** `feat(s5.4): REST/SHRINE attack bonus applies to Combatant via atk_mul`

### Task 4 — Atomic save (after effect, not before)

**Files:**
- Modify: `core/progression/run_controller.gd` (move `save_now()` to AFTER service effect in `_on_node_selected`)
- Modify: `tests/run_tests.gd` (test that save file contains post-effect state)

1. **RED:** test: load save after REST service → load RunState → check `meta_modifiers.rest_attack_bonus == 1`.
2. **GREEN:** remove `save_now()` from `_on_node_selected()` (line 323). Add `save_now()` at the end of `_apply_service_effect()` (after the match). Save applies regardless of `stay_in_current_phase` (MERCHANT also persists shop state).
3. Verify.
4. **Commit:** `refactor(s5.4): atomic save runs after service effect, not before`

### Task 5 — resume_run() restores EncounterMap

**Files:**
- Modify: `core/encounter/encounter_map.gd` (add `goto_node(id)` private method)
- Modify: `core/progression/run_controller.gd` (in `resume_run()`, regenerate map and goto state.current_encounter_id)
- Modify: `tests/run_tests.gd` (test resume_run from MAP phase restores encounter position)

1. **RED:** test: start_run → enter_map → choose node_id 5 → save → new RunController → resume_run(seed) → check encounter_map.current_node_id == 5.
2. **GREEN:** `EncounterMap.goto_node(id)` → set `_current_node_id = id`, mark visited. `RunController.resume_run()` regenerates map by seed, calls `goto_node(state.current_encounter_id)`, sets `phase = Phase.MAP`.
3. Verify.
4. **Commit:** `feat(s5.4): resume_run restores EncounterMap to saved encounter position`

### Task 6 — Finalize

1. `/tmp/godot47.exe --headless --editor --quit`
2. `/tmp/godot47.exe --headless --path . --script tests/run_tests.gd` — expect 0 failed
3. `python tools/lint_anti_patterns.py` — expect 0 errors
4. Add any orphan `.uid` files
5. Final commit if cleanup needed

---

## Файлы изменяются

| Файл | Изменение | LOC |
|---|---|---|
| `core/progression/run_unit_state.gd` | новый | +40 |
| `core/progression/run_state.gd` | `unit_states` field, `SAVE_VERSION=3` | +6 |
| `core/progression/run_controller.gd` | stubs removal, save atomicity, encounter restore, attack bonus | +60 |
| `core/battle/combatant.gd` | `hp_override` param | +3 |
| `core/encounter/encounter_map.gd` | `goto_node(id)` | +10 |
| `tests/run_tests.gd` | 6-8 new tests | +120 |

Итого: ~240 строк.

## Тесты / Валидация

| Task | До | После |
|---|---|---|
| 1 (RunUnitState) | 465 | 467 (+2) |
| 2 (real HP effects) | 467 | 478 (+11) |
| 3 (attack bonus) | 478 | 487 (+9) |
| 4 (atomic save) | 487 | 493 (+6) |
| 5 (resume encounter) | 493 | 500 (+7) |
| 6 (finalize) | 500 | 500 (verify only) |

## Риски

| Риск | Митигация |
|---|---|
| Combatant `_init` parameter change ломает существующие callers (AI, abilities) | Параметр с `=-1` default — обратная совместимость |
| `state.unit_states` migration от v2 → v3 save files | `from_dict` инициализирует пустой массив для v2 сейвов; первая боевая инициализирует per id |
| Per-unit HP persistence теряется при `start_run()` если profiles разные | Чистим `state.unit_states` в start_run — каждое start_run = чистый seed |
| `goto_node(id)` нарушает DAG инварианты | Только для восстановления состояния, не для player choice |
| Patch tool corruption (S5.3 lesson) | Использовать `execute_code` для больших additions |

## Acceptance Criteria

- [ ] `state.unit_states` инициализируется в `start_run()` для каждого `player_unit_ids`
- [ ] HEAL после проигрыша реально повышает HP (тест: defeat → HEAL → next battle shows higher HP)
- [ ] REST/SHRINE атака-bonus применяется в `start_battle()` (тест: REST → next battle Combatant.attack_base > base)
- [ ] Save после service-эффекта содержит post-effect state (тест: load save, check `meta_modifiers`)
- [ ] `resume_run(seed)` восстанавливает `encounter_map.current_node_id` равный сохранённому
- [ ] `_test_resume_run_restores_encounter_position` passes
- [ ] Editor-mode + suite + lint все зелёные
- [ ] Working tree clean

## Notes для реализатора

- **Tab corruption:** patch tool всё ещё flaky на tabbed blocks. Использовать `execute_code` для больших insertions (> 3 строк).
- **Combatant._init:** добавить параметр с default `=-1`, не ломать существующих callers.
- **EncounterMap.goto_node:** это private для восстановления, не публичный API. Должен быть `_goto_node()` с подчёркиванием.
- **state.unit_states initialize:** вызывается в `start_run()` ПОСЛЕ очистки player_unit_ids. Для каждого id создаётся `{unit_id, current_hp=-1, max_hp=def.max_hp}`. `current_hp=-1` sentinel = "use max".
- **RunController._apply_*_effect()** сейчас НЕ вызывает save_now(). Атомарность — apply → save. Так Service эффекты видны после reload.
