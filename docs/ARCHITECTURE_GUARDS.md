# Architecture Guards (Rogue AutoBattler)

> Адаптация 29 архитектурных гвардейцев из Bevy "Absolute Zenith" проекта к Godot/GDScript.
> Цель — поддерживать качество, тестируемость и читаемость кода на уровне "world-class".

## Что перенесено и что не перенесено

**Полностью переносимо в Godot/GDScript:**

| # | Гвардеец | Где применён |
|---|---|---|
| #2 | Conventional Commits | `.githooks/commit-msg` hook |
| #8 | Determinism через seeded RNG | `Rng.randi_range()` + `tools/lint_anti_patterns.py:direct-rng` |
| #11 | Type-Driven Design (без classification flags) | `tools/lint_anti_patterns.py:no-classification-flags` |
| #13 | Strict typing (нет broad queries) | `Array[EncounterNode]` typed arrays |
| #19 | Decoupling (logic без I/O) | `core/*` без `Node`, без `Input`, без `print` |
| #20 | Explicit DI (без static singletons) | Static методы на class_name (Rng, GameBus, GameLog) |
| #22 | Zero tolerance for unwraps/panics | `tools/lint_anti_patterns.py:no-direct-prints-in-core` + AGENTS.md |
| #23 | Global guard (state-based execution) | `RunController.Phase` enum (PREP/BATTLE/REWARD/GAMEOVER) |
| #25 | Plugin 2.0 (нет anonymous closures) | Каждый core/* класс — RefCounted, не Node (тонкая обёртка) |
| #26 | Commit message standard | Conventional Commits hook |
| #28 | Linting mandate | `tools/lint_anti_patterns.py` (7 правил, --strict mode) |

**Частично переносимо (нуждаются в Godot адаптации):**

| # | Гвардеец | Godot аналог |
|---|---|---|
| #1 | Чистый `main.rs` | ✅ `scenes/main.gd` (5 строк) |
| #9 | No Boolean State Flags | ⚠️ Частично — `is_dying` флаг в `visual_state` (см. #11 ниже) |
| #15 | Query Filters | ⚠️ `Array[EncounterNode]` typed, но `for n in _nodes` без фильтра |
| #19 | Decoupling logging | ✅ `GameLog` для core/* (см. lint rule) |
| #21 | Marker Components (ZST) | ⚠️ Частично — `visual_state["is_dying"]` boolean, не ZST |

**Не переносимо в Godot (engine-specific):**

| # | Гвардеец | Причина |
|---|---|---|
| #3 | Entity Relations | Godot не имеет Bevy Relations API |
| #5 | ECS Observers | Godot имеет signals, другая семантика |
| #6 | Все есть Plugin | Godot — не ECS, другая модель (autoload + scenes) |
| #14 | Clippy | Godot не имеет аналога (но `tools/lint_anti_patterns.py` есть) |
| #17 | Safe Behavior Switcher | Не применимо (нет ECS) |
| #18 | Asset Separation | Godot не имеет отдельного AssetPlugin |
| #24 | AsyncComputeTaskPool | Godot имеет `WorkerThreadPool`, но другая семантика |
| #29 | `cargo fmt` | Godot имеет editor formatting (вручную) |

---

## Применённые гвардейцы (детально)

### #8 — Determinism (RNG)

**Правило:** Никакого прямого `randf()` / `randi()` — только `Rng.*` методы.

**Почему:** Прямой `randf()` в GDScript — это Godot built-in random, **НЕ seeded**. Два прогона с одинаковым seed дадут разные результаты. Это ломает replay/daily-runs.

**Реализация:**
- `tools/lint_anti_patterns.py:direct-rng` (severity: error)
- Все static методы используют `Rng.randf()` (с префиксом), не bare `randf()`

**Что перенесено дополнительно:**
- `Rng.pick_unique()` теперь использует Fisher-Yates через `Rng.randf()` вместо встроенного `Array.shuffle()` (был bug — ломал детерминизм магазина)
- `Rng.chance()` — `Rng.randf()` вместо bare `randf()`

### #11 — Type-Driven Design (No Classification Flags)

**Правило:** Запрет `is_X: bool` / `has_X: bool` / `can_X: bool` полей в entity.

**Почему:** Boolean флаги не self-documenting, ломают enum-семантику. Лучше использовать ZST marker components или enum.

**Реализация:**
- `tools/lint_anti_patterns.py:no-classification-flags` (severity: warning)

**Известное нарушение:** `visual_state["is_dying"]: bool` в `Combatant`. По хорошему должно быть `Dying()` marker component. Миграция в S5.x — создать `class_name Dying: pass`.

### #19 — Decoupling (Logic без I/O)

**Правило:** `core/*` файлы не должны использовать `print()`, `printerr()`, `Input`, etc.

**Почему:** Логика должна быть тестируемой headless. UI/logging — отдельная ответственность.

**Реализация:**
- `tools/lint_anti_patterns.py:no-direct-prints-in-core` (severity: error)
- AGENTS.md явно запрещает
- `GameLog` — единственная точка входа для core/* логирования

### #20 — Explicit DI (Без Hidden Globals)

**Правило:** Никаких `static mut`, глобальных переменных для игрового state.

**Почему:** Скрытые глобалы делают тесты изолированными невозможно, и parallel execution ломается.

**Реализация:**
- В GDScript: static методы на `class_name` (Rng, GameBus, GameLog) — это не скрытое состояние, а явный API
- Все игровое state — в Combatant (RefCounted) или Resource (UnitDef, MetaProfile)
- Никаких global переменных уровня проекта

### #22 — Zero Tolerance for Unwraps/Panics

**Правило:** Запрет `.unwrap()`, `.expect()`, `panic!`, `todo!`, `unreachable!` в production коде.

**Почему:** Любая ошибка должна быть обработана gracefully — иначе crash.

**Godot эквивалент:**
- Запрет `assert()` (crashes в release builds) → `_assert()` helper или `if let/match`
- Запрет `print()` в core/* → `GameLog.warn/error`
- AGENTS.md запрещает несколько anti-patterns

**Реализация:**
- `tools/lint_anti_patterns.py:no-assert-in-core` (severity: warning)
- `tools/lint_anti_patterns.py:no-direct-prints-in-core` (severity: error)

### #25 — Plugin 2.0 (No Anonymous Closures)

**Bevy правило:** Запрет `.queue(|world| ...)` анонимных closures. Использовать именованные `Command` structs.

**Godot эквивалент:**
- Каждый core/* класс — `RefCounted` (тонкая обёртка), не `Node` (независимый lifecycle)
- Это автоматически даёт структурированный API — нет анонимных closures
- `RunController` — отдельный класс с явными методами (start_run, buy_unit, move_to_board, start_battle)

### #26 — Conventional Commits

**Правило:** Сообщения коммитов в формате `<type>(<scope>): <subject>`.

**Реализация:**
- `.githooks/commit-msg` — shell hook валидирует
- `.gitmessage.txt` — шаблон для `git commit` без `-m`
- AGENTS.md секция "Conventional Commits (формат)"

**Types:** feat | fix | chore | test | docs | refactor | perf
**Scope:** sprint version (`s3.1`, `s5.1`) или area (`rng`, `ui`, `repo`)

### #28 — Linting Mandate

**Bevy правило:** `cargo clippy -- -D warnings` обязателен.

**Godot эквивалент:**
- `tools/lint_anti_patterns.py` — Python линтер
- Запуск: `python tools/lint_anti_patterns.py` (default) или `--strict` (включая тесты)

**Существующие правила (7):**
1. `combatant-callable-as-field` — error
2. `combatant-magic-power-field` — error
3. `status-def-missing-field` — warning
4. `magic-number` — info
5. `direct-rng` — error
6. `deprecated-class-name` — error
7. `event-bus-direct-emit` — error

**Добавлено в S5.1.x (5 новых):**
8. `no-direct-prints-in-core` — error (#22 decoupling)
9. `no-assert-in-core` — warning (#22 stability)
10. `no-bare-randf-in-static` — error (#8 determinism, static methods)
11. `no-classification-flags` — warning (#11 type-driven)
12. (reserved: `no-dictionary-state` — пока не реализовано)

---

## Что НЕ перенесено (с обоснованием)

### #3 Entity Relations (Bevy 0.18)
Bevy имеет типизированные `Relationship`/`Relation` компоненты, которые автоматически отслеживают lifecycle. Godot не имеет аналога — мы используем `NodePath` для связей в сцене, и direct `Node` references для runtime.

**Альтернатива в Godot:** Использовать `Signal`-based communication + tree-based references (`get_parent()`, `find_child()`).

### #6 Все есть Plugin
Bevy строится на Plugin'ах. Godot имеет свой autoload pattern — `project.godot [autoload]` секция. У нас уже есть `EventBus`, `SaveManager`, `RngService` как autoloads.

### #14 Clippy
Godot не имеет статического анализатора уровня Clippy. Наш `tools/lint_anti_patterns.py` — это компромисс: 12 regex-правил, никакого AST-анализа. Лучше чем ничего.

### #29 cargo fmt
Godot имеет встроенный editor formatter (Ctrl+Shift+I), но **не** автоматический pre-commit. Мы не enforce — это trade-off между friction и consistency.

---

## Как использовать эти гвардейцы в новом спринте

### Перед началом спринта
1. Прочитать раздел "Применённые гвардейцы" выше
2. Понять какие правила нужно соблюдать
3. Запустить `python tools/lint_anti_patterns.py` — baseline violations

### Во время работы
1. Перед каждым коммитом: `python tools/lint_anti_patterns.py` — должно быть 0 errors
2. Если warning — исправить или обосновать в commit message (Why: ...)
3. Следовать Conventional Commits формату

### При code review
1. Проверить что новые файлы проходят lint без errors
2. Если вводится новая anti-pattern категория — добавить lint rule
3. Если рефакторинг убирает class X — проверить нет ли callers

---

## Roadmap (что ещё перенести)

| Sprint | Что |
|---|---|
| S5.1.1 | `no-dictionary-state` rule для lint (запрет `visual_state: Dictionary`) |
| S5.1.2 | Миграция `visual_state["is_dying"]: bool` → `class_name Dying: pass` ZST marker |
| S5.2 | File line count limit (300 lines, как #23) — отдельный lint rule |
| S5.3 | Conventional commits enforce через pre-push hook |
| S6.x | Phased refactor: больше правил из Bevy набора |

---

## История

- **2026-07-15**: Первая версия — 11 перенесённых гвардейцев из 29, интегрированы в `tools/lint_anti_patterns.py` и AGENTS.md.
- **S3.x**: Foundation: Conventional commits hook (commit `2b26133`).
- **S4.x**: GameBus + Rng determinism fix (commit `d19aab4`).

## Источник

29 гвардейцев из Bevy "Absolute Zenith" проекта ("Savage Fantasy"):
- `ARCHITECTURE_GUARDS.md` — реестр всех 29 правил
- `architecture.rs` — runner для всех тестов
- `stability.rs`, `performance.rs`, `decoupling.rs`, `dependency.rs`, `type_safety.rs`, `plugins.rs` — отдельные test files
- `bevy_018_standards.md` — SOP
- `0001-absolute-zenith-architecture.md` — ADR
