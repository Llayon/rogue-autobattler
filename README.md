# Rogue AutoBattler

[![Tests](https://img.shields.io/badge/tests-471%20passed-brightgreen)](https://github.com/youruser/rogueautobattler)
[![Godot](https://img.shields.io/badge/Godot-4.7%2B-blue)](https://godotengine.org)
[![CI](https://github.com/Llayon/rogue-autobattler/actions/workflows/web-build.yml/badge.svg)](https://github.com/Llayon/rogue-autobattler/actions/workflows/web-build.yml)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**[▶ Play in Browser](https://youruser.github.io/rogueautobattler/build/index.html)** — WebAssembly build, no install.

Roguelike RPG AutoBattler на Godot 4.7 (GDScript 2.0, single dev, 6-12 months to Steam).

Roguelike RPG AutoBattler на Godot 4.7 (GDScript 2.0, single dev, 6-12 months to Steam).

## Запуск

1. Установи Godot 4.3+ (проект на 4.7).
2. Открой проект: `Project Manager → Import → выбери project.godot`.
3. Нажми F5 (Play). Откроется BattleScene — PREP → SPACE → BATTLE → REWARD → MAP → click encounter.

## Текущее состояние

- 65 `.gd` файлов, **465/465 тестов** проходят (`/tmp/godot47 --headless --path . --script tests/run_tests.gd`).
- **Encounter map**: 10-слойный DAG с 8 типами (combat/treasure/heal/rest/merchant/shrine/elite/boss), placement screen с swap/move, reward modal с auto-place.
- **Persistence**: RunState v3 + per-unit RunUnitState (HP persists между боями), atomic save, resume по seed.
- **UI**: HUD bar, SystemFont (Cyrillic), centered modals через CenterContainer.
- **Tooling**: `tools/lint_anti_patterns.py` (16 правил из Bevy Zenith + Godot-specific), Conventional Commits via `.githooks/commit-msg`.

## Структура

```
core/           # Чистая логика (без Node): battle, progression, economy, balance
scenes/         # UI: battle, encounter, reward, prep
content/        # .tres ресурсы: units, abilities, effects, items
tests/          # Smoke-тесты (headless SceneTree)
docs/           # ARCHITECTURE.md, ARCHITECTURE_GUARDS.md, GODOT_PATTERNS.md
tools/          # lint_anti_patterns.py
```

Подробнее: `ARCHITECTURE.md` (дизайн, слои, системы), `docs/ARCHITECTURE_GUARDS.md` (roadmap + история коммитов).

## История

- v0.1: каркас (core, scenes, content).
- v0.4: автобаттлер с 1 юнитом против 1 врага.
- v0.5 (текущая, S5-S6.2): encounter map, placement screen, persistence, UI polish, 8 encounter types, 13 unit characteristics.

## Лицензия

TBD (коммерческая — ранний доступ в Steam).