# Battle ECS Migration and Golden Scenarios Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Зафиксировать фактическое поведение текущего legacy-боя, затем постепенно добавить детерминированный ECS только для боевой симуляции, data-driven Effect Engine и событийный Presentation Adapter без переписывания Run Domain и без преждевременного удаления старого движка.

**Architecture:** `RunController` и доменные сущности рана остаются обычной объектной архитектурой. После characterization и Save Schema v4 доменные `RunUnit`/`RunItem` получают стабильные instance IDs; только затем `BattleSetup` преобразует их в изолированный `BattleWorld`. ECS использует явные Dictionary-хранилища внутри `BattleWorld`, command/event queues для state-changing операций и typed logical events для presentation. Legacy backend будет адаптирован к общему контракту, но ECS обязуется только явно утверждённые игровые инварианты, а не полное совпадение внутренних legacy traces.

**Tech Stack:** Godot 4.7, GDScript 2.0, `RefCounted` для чистой логики, `Resource` для контента и сохраняемых данных, headless Godot-тесты, Python anti-pattern/content lint, GitHub Actions, JSON golden fixtures.

---

## 0. Зафиксированный аудит текущего репозитория

Аудит выполнен по реальному checkout `C:\Users\user\Documents\GodotProjects\RogueAutoBattler`. В плане ниже необходимо повторно получить численные baseline-результаты командами, а не доверять устаревшим badge/документации.

### Что можно переиспользовать

- `core/balance.gd` — единая точка формул и баланс-констант; на этапах миграции формулы не менять.
- `core/data/UnitDef`, `AbilityDef`, `StatusDef`, `ReactionDef`, `Effect` и существующие `.tres` — основа data-driven контента.
- `core/battle/Grid` — правила сетки и Manhattan distance; новые системы могут использовать те же значения конфигурации через `BattleSetup`.
- `HealthComponent`, `ManaComponent`, `CooldownList`, `AttackMeter`, `RegenComponent` — кандидаты на перенос логики в ECS-компоненты после characterization tests.
- `AbilityResolver`, `TargetingResolver`, существующие эффекты `DamageEffect`, `HealEffect`, `ApplyStatusEffect`, `MoveEffect`, `SummonEffect`, AOE/chain-эффекты — источник поведения для первого Effect Engine.
- `Rng` — существующий seeded API для legacy и Run Domain; новый simulation backend должен иметь собственный seed-scoped RNG или явно инжектируемый источник, чтобы не зависеть от глобального состояния.
- `RunController`, `RunState`, `RunUnitState`, `SaveService`, `EventBus` — доменная интеграция и UI lifecycle; их нельзя связывать с внутренними ECS-компонентами.
- `tests/run_tests.gd` — существующий regression gate, но его нужно оставить как compatibility suite и постепенно вынести новые наборы в отдельные файлы.

### Что нужно адаптировать

- `BattleRunner` сейчас принимает float `dt`, сам запускает статусы/ресурсы/AI и удаляет мёртвых; логика и порядок должны быть описаны в golden trace и затем обёрнуты контрактом `BattleSimulation`.
- `BattleContext` владеет `Grid` и массивом `Combatant`; его правила регистрации, движения и target selection нужно перенести в `BattleWorld`, сохранив deterministic ordering.
- `Combatant` уже композиционный, но смешивает immutable definition, mutable battle state и visual state. Visual fields (`flash_alpha`, `fade_alpha`, `pos_lerp`, `is_dying`) должны остаться только в legacy/presentation compatibility path и не попасть в новый ECS.
- `StatusList` хранит статусы как массив `Dictionary`, один экземпляр на `status_id`, с простым refresh/stack behavior. Его поведение необходимо сначала покрыть golden/tests, затем заменить индексируемым `StatusContainerComponent` с `StatusInstance`.
- `ReactionSystemPure` индексирует реакции по `combatant.def_id`, а `DamageEffect` обращается к autoload через SceneTree. Новый trigger dispatcher должен индексировать owner/event subscriptions и работать без сцены.
- `RunState` использует `player_unit_ids`, `bench_unit_ids` и `item_equip_board_idx`; это сохраняет состояние по типовым ID/позиционным индексам, поэтому сначала нужен instance identity migration, затем изменение RunController.
- Existing `UnitDef` содержит базовые поля и abilities, но не tags/passives/reactions/AI profile. Расширять schema нужно после минимального ECS вертикального среза, не до него.

### Что нужно заменить в будущем

- Только боевой backend: `BattleRunner`/`BattleContext` путь заменяется на ECS backend после паритетного вертикального среза.
- Реактивное изменение HP/statuses через прямые вызовы и GameBus side effects заменяется command/event pipeline.
- Position-indexed item ownership заменяется `RunItem.owner_unit_id`.
- UI, зависящий от `Combatant` и `visual_state`, заменяется `BattlePresenter`, который потребляет логические события.
- Legacy code удаляется только после доказанного паритета, интеграционного теста и переключения backend по умолчанию.

### Самые рискованные зависимости

1. Порядок и повторяемость `Rng` при нескольких источниках случайности: атаки, dodge/crit, status resistance, reactions, shop/rewards.
2. Побочные эффекты `Combatant.take_damage()` (death, thorns) и `DamageEffect` (shield block, GameBus events), которые сейчас могут вызывать цепочки рекурсивно.
3. Текущее удаление dead/faded combatants: визуальный lifecycle смешан с логической смертью.
4. `RunController.start_battle()` содержит прямые special cases по `unit_id` (`paladin`, `guardian`, `orc_warrior`, `knight`), что нарушает data-driven цель.
5. `.tres` loadability в Web: не возвращать `script_class`, не создавать hand-rolled `.import`, не ломать no-threads preset.
6. Godot headless class cache и cross-file `extends`: соблюдать `AGENTS.md` — preload/string extends вместо нестабильных class_name references.

### Существующие защитные тесты

- RNG reproducibility и strict determinism для encounter/reward.
- Health/shield/heal, status ticking, cooldown, attack meter, mana/regen.
- Basic attack, armor/crit/dodge/magic penetration/lifesteal/thorns/tenacity.
- Ability resolver и several effect types.
- BattleRunner ending/winner behavior.
- RunController start/save/resume/HP persistence/board-bench/inventory/equipment.
- Scene smoke tests, Web-oriented resource loading fixes, UI lifecycle.

Эти тесты не доказывают ещё: стабильный порядок логических событий, полный event trace, одинаковые instance IDs, независимые одинаковые юниты, simultaneous death ordering, chain limits, scene-free simulation и parity нового backend.

### Текущие несоответствия, которые нужно явно задокументировать

- `tests/run_tests.gd` — один большой SceneTree harness, несмотря на документацию про несколько `tests/test_*.gd` файлов.
- `.github/workflows/test.yml` фактически содержит только `echo hello`; он не запускает ни lint, ни Godot tests.
- `web-build.yml` уже экспортирует `Web (no threads)` с `mkdir -p build` и `pipefail`, но тесты не являются обязательным gate перед export.
- README содержит дублированное описание и placeholder GitHub Pages URL; ARCHITECTURE.md отстаёт от фактических S5–S7 систем и описывает часть отложенного функционала как отсутствующую.

### Amendments approved before implementation

1. После Phase 0 characterization и nondeterminism investigation следует отдельная **Phase 1 — Run identity and Save Schema v4**. Она предшествует `BattleSetup`: `RunUnit.instance_id` и `RunItem.instance_id` являются стабильными `String` или `int`, никогда не вычисляются из индекса/позиции. В этой фазе обязательны serializer/deserializer, schema version, v3→v4 migrator, старые save fixtures, validation, atomic write и rollback/failure tests.
2. Тесты разделены на два независимых набора: `tests/legacy_characterization/` фиксирует наблюдаемое legacy behavior, включая известные особенности и ошибки; `tests/battle_simulation_contract/` фиксирует нормативные инварианты общего `BattleSimulation` API. ECS/legacy parity сравнивает только явно перечисленные invariants: winner semantics, tick semantics, HP/shield rules, attack/ability counts where defined, death eligibility/order where defined, status rules и deterministic seed behavior. Полный SHA-256 внутренних legacy/ECS event sequences не является обязательным BattleSimulation contract.
3. Первый ECS storage — только явные Dictionary-поля `health`, `positions`, `teams`, `stats`, `gauges`, `loadouts`, `statuses`, `reactions`, `tags`, `ai`. `ComponentMask`, универсальный `ComponentStore`, PackedArrays, archetype/chunk storage и object pooling откладываются до профилирования.
4. Правило system coupling уточнено: state-changing операции проходят через command/event queue; чистые query/resolver/helper объекты можно вызывать напрямую; система не изменяет компонент, которым владеет другая state-changing фаза.
5. Типы идентификаторов: `String` или `int` для уникальных instance IDs; `StringName` для повторяющихся definition IDs, tags, status IDs и event types.
6. До ECS фиксируется RNG contract: один simulation-scoped RNG owner, явные deterministic channels либо документированный единый поток, отсутствие глобального RNG внутри simulation и debug trace каждого random channel/result.
7. `BattleEvent` не использует неструктурированный `Dictionary payload` для основных данных. Damage/status/ability/movement используют typed fields или typed payload classes; Dictionary разрешён только для диагностических/расширяемых вторичных данных.
8. Первый vertical slice ограничен Warrior, Archer, Goblin, Orc; Damage, Heal, ApplyStatus, RemoveStatus, Move, PerformAttack; Poison, Stun, Shield, Regeneration, AttackUp, Thorns; Counterattack.

### Phase 0 execution boundary

Текущий work order ограничен Phase 0: baseline, minimal legacy characterization tests, nondeterminism localization/documentation и CI gate. Нельзя создавать `BattleSetup`, `BattleUnitSetup`, `RunUnit.instance_id`, `RunItem.instance_id`, Save Schema v4 или любой ECS production code до отдельного подтверждения после Phase 0.


### P0-T1: Capture executable baseline before any battle change

**Objective:** Получить воспроизводимый baseline текущего checkout и зафиксировать только фактические результаты.

**Files:**
- Create: `docs/BATTLE_MIGRATION_AUDIT.md`
- Read-only: `AGENTS.md`, `project.godot`, `README.md`, `ARCHITECTURE.md`, `docs/ARCHITECTURE_GUARDS.md`, `core/battle/*`, `core/progression/*`, `core/effects/*`, `core/reactions/*`, `.github/workflows/*`

**Steps:**

1. Из чистого checkout выполнить:

   ```bash
   /tmp/godot47.exe --headless --path . --script tests/run_tests.gd 2>&1 | tee /tmp/rogue-baseline-tests.log
   python tools/lint_anti_patterns.py 2>&1 | tee /tmp/rogue-baseline-lint.log
   git status --short
   ```

2. В `docs/BATTLE_MIGRATION_AUDIT.md` записать реальные exit codes, test assertion count, lint errors/warnings, stderr errors и список dirty files. Не записывать придуманные numbers.
3. Отдельно отметить, какие baseline failures являются существующими проблемами, а какие появились из harness/environment.

**Verification:** повторный запуск полного baseline дважды даёт одинаковый результат; если нет — перейти к Task 6, не писать golden fixtures.

**Commit:** `docs(battle): record legacy battle migration audit`

---

### P0-T2: Define minimal legacy characterization fixture schema

**Objective:** Создать test-only контракт, описывающий setup, expected result и канонический event trace без изменения production battle rules.

**Files:**
- Create: `tests/legacy_characterization/legacy_characterization_scenario.gd`
- Create: `tests/legacy_characterization/legacy_characterization_result.gd`
- Create: `tests/legacy_characterization/legacy_characterization_runner.gd`
- Create: `tests/legacy_characterization/legacy_characterization_scenarios.gd`
- Create: `tests/legacy_characterization/fixtures/README.md`
- Modify: `tests/run_tests.gd` only to invoke the characterization suite

**Contract:**

```gdscript
class_name LegacyCharacterizationScenario extends RefCounted

var id: StringName
var seed: int
var max_ticks: int
var setup_units: Array
var configure_battle: Callable
```

`LegacyCharacterizationResult` должен содержать только сериализуемые values:

```text
scenario_id
seed
winner_team
ticks
remaining_hp: [{instance_label, hp, shield, alive}]
attack_count
ability_count
death_count
logical_event_hash
logical_events
known_legacy_quirks
```

`GoldenRunner` должен запускать legacy `BattleContext` + `BattleRunner` с фиксированным `0.05` tick, пока бой не закончится или не достигнет `max_ticks`; `max_ticks` должен быть защитой от зависшего боя, а не способом скрыть timeout.

**Canonicalization rules:**

- Unit order — setup order, затем numeric entity/registry order; никогда не полагаться на iteration order `Dictionary`.
- Event record — array fields в заранее заданном порядке, без `Object.to_string()`/instance memory address.
- Text encoding — UTF-8; hash — стабильный SHA-256 canonical event bytes для characterization regression only. Этот hash не становится обязательным BattleSimulation contract для нового ECS.
- Include seed, tick, event kind, source label, target label, amount/status/ability ID, resulting HP where relevant.
- Do not include UI/visual state, frame time, Tween, alpha or object addresses.

**TDD:** сначала добавить один RED test для schema serialization и canonical hash; затем минимальную реализацию и GREEN test.

**Verification:**

```bash
/tmp/godot47.exe --headless --path . --script tests/run_tests.gd
```

Expected at this point: existing suite unchanged; new schema test passes only after its minimal implementation.

**Commit:** `test(battle): define deterministic golden scenario contract`

---

### P0-T3: Add telemetry-only hooks to the legacy path

**Objective:** Получать обязательные counters/events для golden tests, не меняя формулы, AI decisions или порядок gameplay operations.

**Files:**
- Modify: `core/utils/event_bus.gd`
- Modify: `core/battle/combatant.gd`
- Modify: `core/abilities/ability_resolver.gd`
- Modify: `tests/legacy_characterization/legacy_characterization_runner.gd`
- Test: `tests/legacy_characterization/legacy_characterization_test.gd` or corresponding call from `tests/run_tests.gd`

**Design:**

- Добавить только logical `basic_attack_started`/`basic_attack_resolved` observation и deterministic fields, если их нет в существующем bus.
- Hooks должны быть no-op при отсутствии observer/autoload и не вызывать UI.
- `Combatant.basic_attack()` остаётся источником truth для attack count; `AbilityResolver.cast()` — для ability count; existing `unit_died`, damage/status events используются для остального trace.
- Не использовать visual state и не считать DOT как basic attack.
- Не делать `GameBus` новым контрактом ECS: эти hooks — временная legacy instrumentation seam и будут удалены/не использованы новым backend.

**TDD:** RED test должен отличать basic attack от DOT и ability damage; затем добавить hooks; затем прогнать targeted test и full suite.

**Risk:** изменение только наблюдаемости всё равно затрагивает legacy code. Зафиксировать в audit, что behavior changes prohibited and verify before/after result parity on existing suite.

**Commit:** `test(battle): instrument legacy logical battle events`

---

### P0-T4: Implement minimal characterization scenarios

**Objective:** Зафиксировать минимальный legacy battle trace с seed, winner, ticks, HP, attacks, abilities, deaths и hash.

**Files:**
- Modify: `tests/legacy_characterization/legacy_characterization_scenarios.gd`
- Create: fixtures under `tests/legacy_characterization/fixtures/`

**Scenario setup:**

- Create isolated `UnitDef` objects through the existing test helper style, not production `.tres` mutation.
- Player unit label `player_0`, enemy label `enemy_0`.
- Explicit positions `(3, 3)` and `(3, 0)`; explicit attack/HP/speed; explicit seed.
- No ability/status/reaction for the baseline scenario.

**Steps:** RED scenario assertion with placeholder expected values forbidden; run capture mode once, inspect actual output, then add reviewed fixture. GREEN must compare exact result and hash.

**Commit:** `test(battle): capture legacy characterization scenarios`

---

### P0-T5: Add the remaining characterization scenarios independently

**Objective:** Зафиксировать обязательные legacy cases, каждый отдельным fixture и test name.

**Files:**
- Modify: `tests/legacy_characterization/legacy_characterization_scenarios.gd`
- Create: one JSON fixture per scenario under `tests/legacy_characterization/fixtures/`

**Scenarios and required assertions:**

1. `two-allies-vs-two-enemies.json` — setup order and target tie-breaking.
2. `basic-attack-kill.json` — exact lethal attack event and one death.
3. `periodic-damage-kill.json` — DOT event ordering, no attack count inflation.
4. `stun-skips-action.json` — stunned unit has no attack/cast while status blocks actions.
5. `healing.json` — effective heal and max HP cap.
6. `shield-or-block.json` — shield absorption/block reaction, distinguish incoming raw vs HP damage.
7. `counterattack.json` — reaction event ordering and chain origin.
8. `multiple-deaths-same-tick.json` — deterministic death order based on explicit setup/entity order.
9. `two-identical-units.json` — two `warrior` definitions have independent health/status/attack meter references; labels must not be `def_id`.
10. `multi-effect-ability.json` — one cast with at least two effects, preserving effect order.
11. `same-seed-repeat.json` — run identical scenario twice in the same process after reseeding and compare complete `GoldenResult`.

**Scenario authoring rules:**

- Reuse existing behavior and balance formulas; no balance changes to make fixtures convenient.
- Each scenario states its expected `max_ticks`; timeout is a failure with diagnostic trace.
- Every fixture stores actual captured expected values only after a human-readable diff review.
- A fixture update tool, if needed, must be explicit (`--update-goldens`), never implicit in CI.

**TDD per scenario:** RED test → run targeted failure → implement only scenario builder/fixture → targeted GREEN → complete legacy suite.

**Commit grouping:** one commit per coherent scenario pair is acceptable, but tests and fixtures must travel together. Do not commit all fixtures before the runner can validate them.

---

### P0-T6: Localize and document legacy nondeterminism

**Objective:** If any golden scenario differs between repeated runs, identify the exact source before proceeding.

**Files:**
- Modify: `docs/BATTLE_MIGRATION_AUDIT.md`
- Modify only if a test-proven observability fix is required: `core/utils/rng_service.gd`, `core/battle/*`, `core/effects/*`, `core/reactions/*`
- Test: `tests/legacy_characterization/determinism_test.gd` or suite entry

**Investigation order:**

1. Repeat every scenario 100 seeds/runs with fresh `Rng.seed_run(seed)`.
2. Compare first divergent canonical event, not only final HP.
3. Check `Array.shuffle`, bare `randf/randi`, unordered `Dictionary` iteration, reaction registry keyed by `def_id`, and same-process autoload state leakage.
4. Check whether visual cleanup changes registry order before logical snapshots.
5. Add a regression test for each root cause; do not “stabilize” by sorting after the fact if order represents gameplay.
6. If behavior is genuinely ambiguous, document the old rule and choose an explicit deterministic rule for the new contract; do not silently rewrite balance.

**Verification:** 100 repetitions of every golden scenario produce identical hash, or the audit contains a concrete known nondeterminism and blocks architecture migration until fixed.

**Commit:** `fix(rng): eliminate legacy golden nondeterminism` or `docs(battle): document legacy nondeterminism`

---

### P0-T7: Make characterization and lint a CI gate

**Objective:** Ensure legacy characterization and lint cannot drift while the new backend is built.

**Files:**
- Modify: `.github/workflows/test.yml`
- Create if needed: `tools/run_headless_tests.sh` or repository-compatible workflow step
- Modify: `docs/BATTLE_MIGRATION_AUDIT.md`

**CI order at this stage:**

```text
checkout
→ install Godot 4.7
→ install/export templates as needed
→ python tools/lint_anti_patterns.py
→ /tmp/godot --headless --path . --script tests/run_tests.gd
→ legacy characterization repeat/determinism command
```

The current placeholder `echo hello` workflow must become a real gate. Keep Web export/deploy in `web-build.yml`, but later make it depend on successful test workflow or duplicate the required test job before export.

**Verification:** intentionally modify one expected fixture locally and confirm CI-equivalent command fails; restore it and confirm pass.

**Commit:** `chore(ci): gate migration on characterization tests`

---

## Phase 1 — Run identity and Save Schema v4 (blocked until Phase 0 approval)

This phase is deliberately before `BattleSetup`. It is not executable in the current Phase 0 turn.

### P1-T1: Introduce stable RunUnit and RunItem instance identity

**Objective:** Make persisted run entities addressable independently of definition ID, board position and array index.

**Files:**
- Create: `core/progression/run_unit.gd`
- Create: `core/progression/run_item.gd`
- Modify: `core/progression/run_state.gd`
- Modify: `core/progression/run_unit_state.gd`
- Modify: `core/progression/run_controller.gd`
- Test: `tests/integration/run_instance_identity_test.gd`

Use `String` or `int` for unique `instance_id`; use `StringName` only for `definition_id`. IDs are allocated by a run-scoped allocator and serialized explicitly. Never derive an ID from board index, bench index, cell, definition ID or array order. Two equal definitions must receive distinct IDs and preserve their state across board/bench swaps.

### P1-T2: Production SaveRepository and atomic migration (deferred)

**Objective:** Wire the in-memory migrator to a new `SaveRepository` API and replace legacy `.tres` files with atomic writes. **Not in this work order.** Requires separate approval before any user save is touched.

**Files (deferred):**
- Create: `core/save/save_repository.gd`
- Modify: `core/save/save_service.gd`
- Modify: `core/progression/run_controller.gd`
- Modify: `core/utils/save_manager.gd`
- Test: `tests/save_schema_v4/repository_integration_test.gd`

Atomic replace uses `user://saves/runs/<seed>.tmp` followed by rename. Failed replace leaves the prior file intact and emits a `MigrationResult` with `success == false`. Until this task is approved and merged, the production `SaveService` keeps reading the legacy format and the migrator is only invoked from tests.

**Commit (deferred):** `feat(save): wire production save repository and atomic migration`

---

## P1-T3: Freeze the simulation-scoped RNG contract

**Objective:** Define deterministic random ownership before BattleSetup or ECS code exists.

**Files:**
- Create: `core/battle_rng/simulation_rng.gd`
- Create: `core/battle_rng/random_channel.gd`
- Create: `tests/determinism/simulation_rng_contract_test.gd`
- Create: `docs/BATTLE_RNG_CONTRACT.md`

One simulation owns one RNG object. Either use explicitly named channels (`attack`, `status`, `reaction`, `target`) with deterministic derivation, or document a single ordered stream and its call order. Simulation code cannot use global `Rng`/Godot random. Debug mode records channel, draw index and result. Run Domain RNG remains separate.

---

## Phase 2 — Common battle contract and legacy adapter (blocked until Phase 1)

### P2-T1: Add `BattleSetup` and `BattleUnitSetup` as pure input data

**Objective:** Define a scene-free, stable input snapshot that can feed either backend.

**Files:**
- Create: `core/battle_ecs/battle_setup.gd`
- Create: `core/battle_ecs/battle_unit_setup.gd`
- Test: `tests/integration/battle_setup_test.gd`

**Required fields:**

```gdscript
class_name BattleUnitSetup
extends RefCounted

var instance_id: String
var definition_id: StringName
var team: int
var position: Vector2i
var starting_hp: int
var persistent_modifiers: Dictionary
var equipped_item_ids: Array[StringName]
var seed_data: Dictionary
```

`BattleSetup` must contain seed, tick configuration, grid dimensions/configuration, ordered unit setups, ruleset/content references and chain limits. It must deep-copy mutable arrays/dictionaries at construction so later RunState/UI mutation cannot alter an active simulation. `instance_id` is copied from persisted `RunUnit.instance_id`; it must never be generated from an index, position or `definition_id`.

**Tests:** stable instance IDs survive serialization; duplicate instance IDs are rejected; setup order is explicit; same setup serializes identically.

**Commit:** `feat(battle): add backend-independent battle setup contract`

---

### P2-T2: Add `BattleEvent`, `BattleResult`, `BattleSnapshot` and trace contract

**Objective:** Define public outputs independent of Godot Nodes and independent of presentation timing.

**Files:**
- Create: `core/battle_ecs/battle_result.gd`
- Create: `core/battle_ecs/battle_snapshot.gd`
- Create: `core/battle_ecs/events/battle_event_type.gd`
- Create: `core/battle_ecs/events/battle_event.gd`
- Create: `core/battle_ecs/events/battle_trace.gd`
- Test: `tests/determinism/battle_event_contract_test.gd`

**Event fields:** unique monotonic event ID, tick, type, `parent_event_id`, `root_action_id`, `chain_depth`, source/target entity IDs, source/target instance IDs where available, logical tags, typed event payload, deterministic sequence number. Do not use an unstructured `Dictionary payload` for core data. Use typed payload classes such as `DamageEventData`, `HealingEventData`, `StatusEventData`, `AbilityEventData` and `MovementEventData`; reserve an optional dictionary for diagnostics only.

**Required event types for first contract:** `BATTLE_STARTED`, `UNIT_SPAWNED`, `UNIT_MOVED`, `ATTACK_STARTED`, `ABILITY_CAST`, `DAMAGE_APPLIED`, `HEALING_APPLIED`, `STATUS_APPLIED`, `STATUS_REMOVED`, `UNIT_DIED`, `BATTLE_ENDED`.

`BattleResult` must expose winner, end tick, final unit snapshots, normative counters and diagnostics. An implementation may expose a backend-local trace for debugging, but full event hash equality is not a contract between legacy and ECS. It must not contain Node, `Combatant`, `Tween`, sprite, frame or visual alpha.

**Verification:** constructing/serializing each event in headless mode produces no SceneTree dependency; typed payload fields use canonical field order. A backend-local trace hash may be tested within one backend, but it is not a cross-backend parity requirement.

**Commit:** `feat(battle): define logical battle events and result`

---

### P2-T3: Implement the common `BattleSimulation` API

**Objective:** Provide the backend interface required by Run Domain and UI.

**Files:**
- Create: `core/battle_ecs/battle_simulation.gd`
- Test: `tests/integration/battle_simulation_contract_test.gd`

**API:**

```gdscript
class_name BattleSimulation
extends RefCounted

func initialize(setup: BattleSetup) -> void:
    pass

func step_ticks(tick_count: int = 1) -> Array[BattleEvent]:
    return []

func is_finished() -> bool:
    return false

func get_result() -> BattleResult:
    return null

func create_snapshot() -> BattleSnapshot:
    return null
```

Use string-path inheritance/preload patterns required by `AGENTS.md`; do not use fragile cross-file `extends BattleSimulation` by class name in production core files. Normative contract tests belong under `tests/battle_simulation_contract/`; legacy characterization tests remain separate under `tests/legacy_characterization/`.

**Verification:** contract test can hold a backend as a generic object and call all five methods; no UI dependency.

**Commit:** `feat(battle): add battle simulation interface`

---

### P2-T4: Wrap the old engine in `LegacyBattleSimulation`

**Objective:** Make the current engine accessible through the new interface without changing its behavior.

**Files:**
- Create: `core/battle_ecs/legacy_battle_simulation.gd`
- Modify: `core/progression/run_controller.gd` only to construct this adapter behind an explicit backend selection
- Test: `tests/integration/legacy_simulation_adapter_test.gd`

**Adapter rules:**

- Convert `BattleSetup` to `BattleContext`/`Combatant` in exact setup order.
- Call legacy `BattleRunner.step(0.05)` only from `step_ticks`, never from `_process`/FPS.
- Convert legacy observations into `BattleEvent[]`; map temporary labels/entity handles deterministically.
- Preserve existing legacy visual state only for old UI compatibility; do not expose it through `BattleResult`.
- `create_snapshot()` must be logical and scene-free.
- Do not delete or rename the old classes.

**Parity test:** same fixture through direct legacy harness and adapter compares only normative invariants. It must not require identical internal event ordering or SHA-256 hash; legacy quirks are recorded in characterization fixtures and are not promoted automatically.

**Commit:** `feat(battle): expose legacy backend through simulation contract`

---

## Phase 3 — Minimal readable Battle ECS (blocked until normative contract tests exist)

### P3-T1: Implement entity allocation and `BattleWorld`

**Objective:** Add numeric entity IDs and simple readable component stores, with no archetype/chunk optimization.

**Files:**
- Create: `core/battle_ecs/world/entity_allocator.gd`
- Create: `core/battle_ecs/world/battle_world.gd`
- Test: `tests/battle_ecs/world_test.gd`

**Initial storage:** explicit dictionaries keyed by numeric entity ID inside `BattleWorld`: `health`, `positions`, `teams`, `stats`, `action_gauges`, `ability_loadouts`, `statuses`, `reactions`, `tags`, `ai`. Do not create `ComponentMask`, `ComponentStore`, PackedArrays or archetype/chunk storage before profiling.

**Tests:** allocation/release behavior; two equal definitions have distinct entities; unknown/dead entities are rejected; snapshot order is numeric entity order.

**Commit:** `feat(battle): add readable battle ecs world`

---

### P3-T2: Add the first ECS components

**Objective:** Represent the minimum combat state without Node or `Combatant` references.

**Files:**
- Create: `core/battle_ecs/components/identity_component.gd`
- Create: `core/battle_ecs/components/team_component.gd`
- Create: `core/battle_ecs/components/position_component.gd`
- Create: `core/battle_ecs/components/health_component.gd`
- Create: `core/battle_ecs/components/stats_component.gd`
- Create: `core/battle_ecs/components/action_gauge_component.gd`
- Create: `core/battle_ecs/components/ability_loadout_component.gd`
- Create: `core/battle_ecs/components/ai_component.gd`
- Tests: `tests/battle_ecs/components_test.gd`

`HealthComponent` must model HP/shield and death state logically. `StatsComponent` must initially support only the fields needed for ordinary attack, movement and first vertical slice. Do not create one ECS component per status.

**Verification:** import every component in headless mode; component tests never instantiate a Node or load a scene.

**Commit:** `feat(battle): add initial ecs components`

---

### P3-T3: Add BattleSetup → World spawn and snapshot round-trip

**Objective:** Spawn all setup units into ECS and produce a stable logical snapshot.

**Files:**
- Modify: `core/battle_ecs/world/battle_world.gd`
- Create/modify: `core/battle_ecs/battle_snapshot.gd`
- Test: `tests/battle_ecs/spawn_snapshot_test.gd`

**Rules:**

- Preserve `BattleUnitSetup.instance_id` in identity component.
- Allocate numeric IDs in ordered setup sequence.
- Reject out-of-bounds/occupied positions deterministically.
- Snapshot final units by numeric entity ID and include original instance ID.
- No content-specific branches or Node access.

**Commit:** `test(battle): cover ecs spawn and snapshot identity`

---

### P3-T4: Implement command/event queues and deterministic ordering

**Objective:** Prevent systems from directly calling each other and establish bounded action chains.

**Files:**
- Create: `core/battle_ecs/commands/battle_command.gd`
- Create: `core/battle_ecs/commands/battle_command_queue.gd`
- Create: `core/battle_ecs/events/battle_event_queue.gd`
- Modify: `core/battle_ecs/events/battle_event.gd`
- Test: `tests/battle_ecs/queues_test.gd`

**Commands:** `MoveRequested`, `AttackRequested`, `AbilityRequested`, `DamageRequested`, `HealRequested`, `ApplyStatusRequested`, `RemoveStatusRequested`, `SpawnRequested`, `DeathRequested`.

**Ordering:** every queue entry has sequence ID and parent/root/depth metadata. Drain by explicit `(tick, system_phase, insertion_sequence)`; never sort by a Dictionary key or object string.

**Limits:** constants live in one explicit balance/config contract, initially:

```gdscript
const MAX_CHAIN_DEPTH: int = 32
const MAX_EVENTS_PER_TICK: int = 10000
const MAX_REACTIONS_PER_ROOT_ACTION: int = 256
```

Limit failures return diagnostic result with trace chain; they do not recurse indefinitely or silently truncate.

**Commit:** `feat(battle): add deterministic command and event queues`

---

### P3-T5: Implement fixed-tick simulation shell and core systems

**Objective:** Run a scene-free battle using explicit systems and queues.

**Files:**
- Create: `core/battle_ecs/systems/battle_command_system.gd`
- Create: `core/battle_ecs/systems/action_gauge_system.gd`
- Create: `core/battle_ecs/systems/ai_system.gd`
- Create: `core/battle_ecs/systems/targeting_system.gd`
- Create: `core/battle_ecs/systems/movement_system.gd`
- Create: `core/battle_ecs/systems/attack_system.gd`
- Create: `core/battle_ecs/systems/damage_system.gd`
- Create: `core/battle_ecs/systems/death_system.gd`
- Create: `core/battle_ecs/systems/victory_system.gd`
- Modify: `core/battle_ecs/battle_simulation.gd`
- Tests: `tests/battle_ecs/systems_test.gd`, `tests/integration/scene_free_battle_test.gd`

**System rules:**

- State-changing systems do not directly invoke other state-changing systems. Pure resolvers, queries, calculators and validators may be called directly. Cross-phase state mutations pass through commands/events.
- Use explicit phase order per tick: input/commands → gauge → AI/targeting → movement → attacks → damage → death → victory.
- Dead entities cannot submit or execute actions.
- Target tie-break: distance, then position, then numeric entity ID.
- Movement uses `Grid` semantics copied into pure world rules, with no `Grid` Combatant references.
- Attack and damage formulas call existing balance functions initially; no balance tuning in this phase.

**First ECS acceptance test:** one warrior-like setup versus one enemy-like setup ends with deterministic winner/result and no SceneTree.

**Commit:** `feat(battle): run minimal scene-free ecs battle`

---

## Phase 4 — Effect Engine and statuses

### P4-T1: Add Effect Engine data/context/registry

**Objective:** Move ability execution behind a generic executor without encoding every mechanic as a system special case.

**Files:**
- Create: `core/battle_ecs/effects/effect_context.gd`
- Create: `core/battle_ecs/effects/effect_registry.gd`
- Create: `core/battle_ecs/effects/effect_executor.gd`
- Create: `core/battle_ecs/effects/condition_evaluator.gd`
- Create: `core/battle_ecs/effects/target_selector.gd`
- Test: `tests/effects/effect_executor_test.gd`

**Initial operations:** `DAMAGE`, `HEAL`, `APPLY_STATUS`, `REMOVE_STATUS`, `ADD_SHIELD`, `MODIFY_RESOURCE`, `MODIFY_STAT`, `MOVE`, `PERFORM_ATTACK`, `SEQUENCE`, `CONDITIONAL`, `REPEAT`, `CUSTOM`.

Effects emit commands through `EffectContext`; they cannot call UI, mutate scene nodes, invoke systems directly, or bypass event trace. `custom_executor_id` is resolved through an allowlisted registry and receives only `EffectContext`.

**Safety:** validate repeat counts and chain depth before execution; custom executor errors become diagnostics.

**Commit:** `feat(effects): add data-driven effect executor`

---

### P4-T2: Add indexed status containers and stacking policies

**Objective:** Support hundreds of statuses as data instances rather than hundreds of ECS component types.

**Files:**
- Create: `core/battle_ecs/components/status_container_component.gd`
- Create: `core/battle_ecs/components/status_instance.gd`
- Create: `core/battle_ecs/systems/status_system.gd`
- Test: `tests/statuses/status_container_test.gd`

`StatusInstance` fields: unique instance ID, definition ID, owner/source entity, stacks, remaining ticks, local values, trigger flags/cooldowns.

Stacking policies: `REPLACE`, `REFRESH_DURATION`, `ADD_DURATION`, `ADD_STACK`, `REPLACE_IF_STRONGER`, `INDEPENDENT_INSTANCES`, `UNIQUE_PER_SOURCE`.

Build event subscription index `(event_type, entity)` → status/reaction instance IDs. Status system must not scan every status on every event. Expiry/removal must invalidate modifier contributions and subscriptions completely.

**Tests:** independent equal units; source-sensitive unique policy; removal; expiry; tick limits; no scene dependency.

**Commit:** `feat(statuses): add indexed status container`

---

### P4-T3: Add trigger dispatcher and reaction safety limits

**Objective:** Convert status/reaction chains into queued, traceable, bounded operations.

**Files:**
- Create: `core/battle_ecs/systems/trigger_system.gd`
- Create: `core/battle_ecs/components/reaction_container_component.gd`
- Modify: `core/battle_ecs/events/battle_trace.gd`
- Test: `tests/triggers/trigger_dispatcher_test.gd`

Support trigger scopes: once per event, action, tick; maximum trigger count; cooldown; root-action and parent-event propagation.

Required tests:

- cyclic reaction terminates at `MAX_CHAIN_DEPTH`/reaction limit with diagnostic trace;
- shield block, counterattack, attack of opportunity and on-death effects preserve parent/root IDs;
- trigger order is stable when multiple statuses subscribe to the same event;
- coupling: state-changing systems do not directly invoke other state-changing systems; pure resolvers, queries, calculators and validators may be called directly; cross-phase state mutations pass through commands/events.



**Cross-cutting coupling rule (applies to every system):** state-changing systems do not directly invoke other state-changing systems. Pure resolvers, queries, calculators and validators may be called directly. Cross-phase state mutations pass through commands/events.

**Commit:** `feat(triggers): add bounded reaction dispatcher`

---

### P4-T4: Add stat modifier pipeline and breakdown

**Objective:** Separate base, persistent, battle and computed stats with explicit deterministic ordering.

**Files:**
- Create: `core/battle_ecs/components/stats_component.gd` or modify its placeholder
- Create: `core/battle_ecs/stats/stat_modifier.gd`
- Create: `core/battle_ecs/stats/stat_pipeline.gd`
- Create: `core/battle_ecs/stats/stat_breakdown.gd`
- Test: `tests/battle_ecs/stat_pipeline_test.gd`

Apply in fixed order: `BASE → FLAT_ADD → PERCENT_ADD → MULTIPLY → OVERRIDE → CLAMP`. Store modifiers as explicit records with stable source/order keys. Use dirty flag and lazy recompute. Dictionary order must never decide the result.

Test breakdown output such as:

```text
Attack = 42
Base: 30
Weapon: +5
Rage: +20%
Weakness: -2
Final: 42
```

**Commit:** `feat(battle): add deterministic stat modifier pipeline`

---

## Phase 5 — Content and first vertical slice

### P5-T1: Extend content schema compositionally

**Objective:** Make archetypes data composition rather than inheritance or central unit-ID branches.

**Files:**
- Modify: `core/data/unit_def.gd`
- Modify: `core/data/ability_def.gd`
- Modify: `core/data/status_def.gd`
- Modify: `core/data/reaction_def.gd`
- Create: `core/data/ai_profile_def.gd`
- Create: `tools/validate_content.py` or a headless `core/content/content_validator.gd` according to project convention
- Test: `tests/integration/content_validation_test.gd`

Add/validate `tags`, `passives`, `reactions`, `ai_profile` and effect definitions without requiring every content file to be migrated at once. Preserve current `.tres` compatibility; never reintroduce `script_class=` references that fail Web load.

Validator checks: unique IDs, references exist, valid stat IDs, trigger types, stacking rules, target selectors, no cyclic effect graph, AI profile present, legal definitions.

**Tests:** an ordinary new status and archetype can be loaded/validated without changing a central battle system; invalid content fails with file/id/path diagnostics.

**Commit:** `feat(content): validate compositional battle definitions`

---

### P5-T2: Migrate only the first vertical-slice content

**Objective:** Prove the new backend with a small representative set, not all existing content.

**Files:**
- Modify/create only the required `.tres` resources under:
  - `content/units/warrior.tres`
  - `content/units/archer.tres`
  - `content/enemies/goblin.tres`
  - `content/enemies/orc_warrior.tres`
  - `content/effects/*.tres`
  - `content/effects/instances/*.tres`
  - `content/abilities/*.tres`
  - `content/reactions/*.tres`
- Test: `tests/integration/vertical_slice_test.gd`

Use existing IDs to avoid mass rename: canonical first slice is `warrior`, `archer`, `goblin`, and existing `orc_warrior` as the Orc content ID unless a product decision explicitly introduces a new alias. Do not add `if unit_def.id == ...` branches.

Required behavior: basic attack, Damage, Heal, ApplyStatus, RemoveStatus, Move, PerformAttack, Poison/Burn-equivalent DOT, Stun, Shield, Regeneration, AttackUp, Thorns, ShieldBlock, Counterattack. Existing content names may be mapped through data, but balance values remain unchanged.

**Verification:** run the same vertical slice through legacy adapter and ECS. Compare only normative invariants: winner semantics, final HP/shield values, attack/ability counters where defined, status application/removal, logical death cause/order, required parent/root relationships on chained events. Full canonical event trace equality is **not** required. Diagnose only differences in the projected normative invariants; do not silently rewrite balance.

**Commit:** `feat(battle): add first ecs combat vertical slice`

---

## Phase 6 — Presentation and Run Domain integration

### P6-T1: Add `BattlePresenter` as a scene-layer adapter

**Objective:** Make visual output consume logical events without making ECS depend on Godot Nodes.

**Files:**
- Create: `scenes/battle/battle_presenter.gd`
- Modify: `scenes/battle/battle_scene.gd`
- Modify: `scenes/battle/battle_view.gd` and `scenes/battle/ui_overlay.gd` only where event consumption is needed
- Test: `tests/integration/battle_presenter_test.gd`, scene smoke test

The presenter maps `UNIT_SPAWNED`, `UNIT_MOVED`, `DAMAGE_APPLIED`, `ABILITY_CAST`, `UNIT_DIED`, `BATTLE_ENDED` to view operations. Logical death is immediate in simulation; death animation and Node lifetime are presentation-only. Presenter must tolerate headless/no-visual mode.

Architectural deviation: `BattlePresenter` belongs under `scenes/battle`, not `core/battle_ecs`, because it is the explicit Presentation layer and may use Nodes/Tweens. The ECS event types remain pure.

**Commit:** `feat(ui): consume battle events through presenter adapter`

---

### P6-T2: Integrate Run Domain with BattleSimulation

**Objective:** Wire Run Domain to the selected `BattleSimulation` backend without exposing internal world/components.

**Flow:**

```text
RunUnit/RunItem
→ BattleSetupFactory
→ selected BattleSimulation backend
→ BattleResult
→ BattleResultApplier
→ RunValidator
→ one atomic save
→ UI notification
```

**Files:**
- Create: `core/progression/battle_setup_factory.gd`
- Create: `core/progression/battle_result_applier.gd`
- Modify: `core/progression/run_controller.gd`
- Tests: `tests/integration/run_battle_integration_test.gd`

Rules:

- Use `String` (or `int`) for unique `instance_id`. Use `StringName` only for `definition_id`, `status_id`, tags and event types. `instance_id` и `definition_id` не смешивать.
- `BattleSetupFactory` consumes ordered `RunUnit`s and produces `BattleSetup` + `BattleUnitSetup`; it must copy `instance_id` verbatim and never derive identity from index, position or `definition_id`.
- `BattleResultApplier` consumes `BattleResult`, applies HP/rewards/round transitions and writes back through existing per-unit state.
- `RunValidator` rejects duplicate `instance_id`s and undefined `definition_id` references.
- Run Domain sees only `BattleSetup`, `BattleResult`, `RunUnit`, `RunItem`; it must not import `BattleWorld` or component types.
- No intermediate save before result application; one atomic save after `RunValidator` accepts the result.
- Do not duplicate `SaveManager`, migrator, validator or RNG contract work from Phase 1.
- No new battle simulation code in this task.

**Commit:** `feat(progression): integrate run domain with battle simulation`

---

## Phase 7 — Backend switch, CI, performance and cleanup

### P7-T1: Add explicit backend selection and parity gate

**Objective:** Allow legacy/ECS selection while keeping legacy available as fallback until parity is proven.

**Files:**
- Modify: `core/progression/run_controller.gd`
- Create/modify: `core/progression/battle_backend_kind.gd`
- Modify: `project.godot` only if a non-gameplay debug setting is required
- Tests: `tests/integration/backend_parity_test.gd`

Default during migration: legacy. Debug/test modes can choose ECS. Once vertical slice parity passes across all golden scenarios, switch default to ECS without deleting legacy. Add a test that both backends accept the same setup and produce equivalent result contract for migrated content.

**Commit:** `feat(battle): add selectable legacy and ecs backends`

---

### P7-T2: Add required test directories and CI sequence

**Objective:** Make architecture boundaries and migration criteria continuously verifiable.

**Files:**
- Create/populate: `tests/battle_ecs/`
- Create/populate: `tests/effects/`
- Create/populate: `tests/statuses/`
- Create/populate: `tests/triggers/`
- Create/populate: `tests/determinism/`
- Create/populate: `tests/integration/`
- Create/populate: `tests/performance/`
- Modify: `.github/workflows/test.yml`
- Modify: `.github/workflows/web-build.yml`

Required tests:

1. Same setup + seed → same result/event trace.
2. Two equal units have independent state.
3. Movement never transfers items.
4. Removing status removes all modifiers.
5. Effect order independent of Dictionary insertion order.
6. Cyclic reaction stops safely with diagnostic trace.
7. Dead unit cannot act.
8. Simultaneous deaths are deterministic.
9. Aura add/remove is correct.
10. Summoned entity spawns/dies correctly.
11. `UNIQUE_PER_SOURCE` distinguishes sources.
12. Save/load preserves instance IDs.
13. Scene-free battle works.
14. Event trace reconstructs damage cause.
15. New ordinary status requires data/validator changes only, not central systems.

CI order:

```text
lint
→ content validation
→ headless legacy/golden tests
→ determinism tests
→ ECS unit tests
→ integration/parity tests
→ performance smoke threshold (non-flaky, informational initially)
→ Web no-threads export
→ smoke check
→ deploy
```

Do not use `/jobs/{id}/logs` API for Actions diagnostics; use `gh run view --log-failed` when debugging CI. Preserve `mkdir -p build` before Godot export and `set -eo pipefail`.

**Commit:** `chore(ci): run battle gates before web export`

---

### P7-T3: Add headless performance benchmarks after correctness

**Objective:** Measure the actual architecture before considering storage optimization.

**Files:**
- Create: `tests/performance/battle_benchmark.gd`
- Create: `docs/BATTLE_PERFORMANCE.md`
- Modify: CI only if benchmark output is stable enough for a non-blocking report

Benchmarks:

- 10 units × 50 active statuses.
- 20 units × 100 active statuses.
- 50 units × 200 active statuses.
- 1000 scene-free battles.

Record average/max tick time, events per tick, max chain depth, stat recomputes, allocated objects and 1000-battle duration. Run with visual/presenter disabled. Do not optimize before measurements. Only after a profile may the implementation consider PackedArrays, component masks, dense IDs, pooling or SoA storage.

**Commit:** `perf(battle): benchmark headless ecs simulation`

---

### P7-T4: Remove remaining content-specific and visual legacy dependencies

**Objective:** Complete the migration only after all gates are green.

**Files:**
- Modify: `core/progression/run_controller.gd`
- Modify: `core/battle/battle_runner.gd`, `core/battle/combatant.gd`, `core/battle/battle_context.gd` only when no callers remain
- Modify: `scenes/battle/*`
- Modify: `docs/ARCHITECTURE.md`, `README.md`, `docs/ARCHITECTURE_GUARDS.md`, `AGENTS.md` if conventions changed
- Tests: full suite, golden/parity/integration suite, Web smoke

Preconditions before deletion:

- ECS backend is default and used by RunController.
- All normative BattleSimulation contract scenarios pass through ECS. Legacy characterization scenarios remain legacy-only regression tests. Selected characterization scenarios may be projected into explicitly approved normative invariants, but ECS must not reproduce undocumented legacy quirks.
- No production caller imports legacy backend.
- UI consumes only `BattleEvent[]`/presenter APIs.
- Run Domain has no ECS imports.
- Content validator and all tests are CI gates.
- Save migration and rollback strategy are tested.

Do not mass-rename or mass-move files; remove only dead files proven by search and test coverage. Update documentation to describe actual code, not aspirational structure.

**Commit:** `refactor(battle): retire legacy backend after parity`

---

## Cross-cutting implementation rules\n**Cross-cutting coupling rule (canonical):** state-changing systems do not directly invoke other state-changing systems. Pure resolvers, queries, calculators and validators may be called directly. Cross-phase state mutations pass through commands/events. This is the only accepted form of system coupling.



1. Before every major phase, report current state, exact files to change, regression risk, commands to run, and known limitations.
2. Every production behavior change follows strict RED → verify failure → minimal GREEN → verify targeted test → full suite → refactor.
3. Tests and fixtures ship with the code they protect; no unverified golden values and no automatic fixture rewriting in CI.
4. Every public GDScript method gets a `##` doc comment; use typed variables where project conventions permit.
5. Cross-file references follow `AGENTS.md`: const preload for core classes, string-path `extends`, no direct `EventBus.signal.emit` in core, no direct RNG calls, no `print()` in core.
6. Keep all balance formulas in `core/balance.gd`; architecture work must not silently rebalance combat.
7. Never put `Node`, `Node2D`, `Sprite2D`, `Tween`, UI or animation state in `core/battle_ecs`.
8. Systems exchange commands/events; they do not invoke each other directly.
9. Stable ordering is always explicit: setup order, numeric entity ID, event sequence, or declared priority.
10. Use diagnostic traces for chain-limit failures; do not swallow or silently truncate them.
11. After every `.gd` edit, inspect tab indentation and run headless parse/tests; `patch` can corrupt tab-indented GDScript, so prefer a tab-safe edit method for multi-line blocks.
12. Validate real stderr for `SCRIPT ERROR`/`Parse Error`; a test counter alone is insufficient because the existing harness can silently miss assertions after runtime errors.
13. Preserve Web constraints: no `DirAccess.open("res://...")` for Web enumeration, no invalid `.tres script_class`, editor-generated import metadata only, and `Web (no threads)` for public GitHub Pages.

## Completion criteria

The migration is complete only when:

- A battle runs headlessly without a scene.
- UI receives logical events through `BattlePresenter` only.
- Within one backend, the same setup and seed produce the same backend-local normative trace/hash.
- Across legacy and ECS, only explicitly approved normative invariants must match.
- Backend-local trace hashes are not compared across different backends.
- All normative BattleSimulation contract scenarios pass through ECS.
- Legacy characterization scenarios remain legacy-only regression tests. Selected characterization scenarios may be projected into explicitly approved normative invariants, but ECS must not reproduce undocumented legacy quirks.
- A normal new status is data-driven and does not require central system edits.
- A new archetype is composition, not a central unit-ID branch.
- Equal classes have independent instance IDs and state.
- Items belong to unit instances.
- Reaction chains have parent/root trace and hard limits.
- Run Domain does not depend on ECS internals.
- Legacy backend is no longer used by production, with removal justified by normative-invariants parity evidence.
- Golden, content validation, determinism, integration and headless tests are CI gates before Web export/deploy.