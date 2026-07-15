#!/usr/bin/env python3
"""Anti-pattern linter for Rogue AutoBattler.

Запускать: python tools/lint_anti_patterns.py [--strict]

Проверяет:
- Запрещённые обращения к Combatant полям как к свойствам (Callable ошибки)
- Обращения к несуществующим полям StatusDef
- Magic numbers в логике (должны быть в core/balance.gd)
- Прямой randf() вместо Rng.* (нарушение детерминизма)
- Устаревшие имена class_name (Logger, RngService, etc.)
- Запрещённый EventBus.signal.emit в core/* (нужен GameBus.emit_*)

Гвардейцы перенесённые из Bevy Absolute Zenith (29 архитектурных гвардейцев):
- #22 no-direct-prints-in-core: запрет print()/printerr() в core/ (стабильность)
- #22 no-panic-in-core: запрет assert()/push_error() в core/ (стабильность)
- #20 no-bare-randf-in-static: запрет bare randf() в static методах (детерминизм)
- #11 no-classification-flags: запрет is_X: bool флагов в Combatant (использовать ZST)
- #15 no-dictionary-state: запрет Dictionary как state (использовать typed struct)
"""
import os
import re
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent
CORE_DIR = PROJECT_ROOT / "core"
SCENES_DIR = PROJECT_ROOT / "scenes"
TESTS_DIR = PROJECT_ROOT / "tests"

# Правила: (pattern, message, severity, file_filter)
# severity: "error" (exit 1), "warning" (exit 0), "info"
# file_filter: lambda(path) -> bool
RULES = [
    # === Запрещённые обращения к Combatant ===
    # Ловит: c.current_hp / c.defense / c.attack без скобок.
    # Не ловит: c.health.current_hp (есть . перед current_hp),
    #           c.defense() (есть скобка после),
    #           def.defense = 0 (присваивание, не чтение),
    #           @export var defense = 0.
    {
        "id": "combatant-callable-as-field",
        "pattern": re.compile(r"(?<![\w\.])(c|t|target|attacker|defender|source)\.(current_hp|defense|attack|attack_speed|move_speed|magic_resist|attack_range|defense_base|magic_power_base)(?!\s*\(|\s*[\.\[]|\s*=|\s*$)"),
        "message": "Combatant.{1}() is a method, not a property. After refactor: c.health.current_hp / c.defense() / c.attack() etc.",
        "severity": "error",
        "exclude_paths": ["tests/", "core/battle/combatant.gd", "core/data/unit_def.gd"],
    },
    {
        "id": "combatant-magic-power-field",
        "pattern": re.compile(r"(?<![\w\.])\w+\.magic_power\b(?!_base|\s*\()"),
        "message": "Combatant поле называется magic_power_base, не magic_power. See {0}",
        "severity": "error",
        "exclude_paths": ["core/data/unit_def.gd", "content/"],
    },

    # === StatusDef поля ===
    {
        "id": "status-def-missing-field",
        "pattern": re.compile(r'def\.get\("(magic_power|magic_resist)_(modifier|base)"\)'),
        "message": "Reading StatusDef field that must exist. Add @export in core/data/status_def.gd.",
        "severity": "warning",
    },

    # === Magic numbers ===
    {
        "id": "magic-number",
        "pattern": re.compile(r"\b0\.[0-9]{1,4}\b"),
        "message": "Decimal constant. Consider adding to core/balance.gd.",
        "severity": "info",
        "exclude_paths": ["tests/", "core/balance.gd", "core/data/", "*.tres"],
    },

    # === RNG ===
    {
        "id": "direct-rng",
        "pattern": re.compile(r"(?<![\w\.])\b(randf|randi|randf_range|randi_range)\s*\("),
        "message": "Direct RNG call (randf/randi) breaks determinism. Use Rng.randi_range(1, 999999).",
        "severity": "error",
        "exclude_paths": [
            "tests/",
            "core/utils/rng_service.gd",
            "core/balance.gd",
        ],
    },

    # === Устаревшие class_name ===
    {
        "id": "deprecated-class-name",
        "pattern": re.compile(r"\b(Logger|RngService|SaveManager|ContentDB)\."),
        "message": "Deprecated class_name. Use GameLog / Rng / SaveSvc / ContentDB_static.",
        "severity": "error",
        "exclude_paths": ["AGENTS.md", "ARCHITECTURE.md"],
    },

    # === EventBus direct emit в core/* ===
    {
        "id": "event-bus-direct-emit",
        "pattern": re.compile(r"\bEventBus\.\w+\.emit\("),
        "message": "Use GameBus.emit_xxx() static helpers in core/* (EventBus is autoload instance, not class_name).",
        "severity": "error",
        "scope": "core/",
    },

    # === Stability (#22 из Bevy гвардейцев) ===
    # Запрет print/printerr в core/* (нарушение decoupling).
    # core/* не должен знать о выводе — используй GameLog.
    {
        "id": "no-direct-prints-in-core",
        "pattern": re.compile(r"\b(print|printerr|push_error|push_warning)\s*\("),
        "message": "Core logic file uses direct print/printerr. Use GameLog.info/warn/error instead.",
        "severity": "error",
        "scope": "core/",
        "exclude_paths": [
            "core/utils/logger.gd",  # сам GameLog может print для fallback
        ],
    },
    # Запрет assert() в production core/* (стабильность — должен быть graceful).
    {
        "id": "no-assert-in-core",
        "pattern": re.compile(r"\bassert\s*\("),
        "message": "assert() crashes in release builds. Use _assert() helper or if let/match for runtime checks.",
        "severity": "warning",
        "scope": "core/",
    },

    # === Determinism (#22 — Bare randf in static) ===
    # bare randf()/randi() внутри static методов → Godot built-in random,
    # НЕ seeded. Должен быть Rng.randf() (с префиксом class_name).
    {
        "id": "no-bare-randf-in-static",
        # Паттерн: static func или const/var...static внутри с bare randf()
        # Сложно детектить точно, поэтому ловим любой bare randf() внутри core/
        # и требуем префикс Rng.
        "pattern": re.compile(r"(?<![\w.])randf\s*\(|^[^#]*\brandi\s*\("),
        "message": "Bare randf()/randi() — Godot built-in (NOT seeded). Use Rng.randf() / Rng.randi_range().",
        "severity": "error",
        "scope": "core/",
        "exclude_paths": [
            "core/utils/rng_service.gd",  # сам Rng
            "core/balance.gd",  # баланс может ссылаться на global
        ],
    },

    # === Type-Driven Design (#21 — no classification flags) ===
    # Запрет is_X / has_X / can_X : bool полей в Combatant (и других entity).
    # Использовать ZST marker components или enum.
    {
        "id": "no-classification-flags",
        "pattern": re.compile(r"\b(is_|has_|can_|should_)\w+\s*:\s*bool"),
        "message": "Classification flag 'is_X: bool' forbidden. Use ZST marker component or enum.",
        "severity": "warning",
        "exclude_paths": [
            "core/data/unit_def.gd",  # UnitDef может иметь bool поля (но лучше enum)
            "core/battle/status_list.gd",
        ],
    },
]  # noqa


def should_check_file(path: Path) -> bool:
    """Проверяем ли этот файл."""
    if not path.suffix == ".gd":
        return False
    rel = path.relative_to(PROJECT_ROOT).as_posix()
    # Не проверяем .md, .tres, README, и т.д.
    return True


def check_file(path: Path) -> list:
    """Возвращает список нарушений для файла."""
    violations = []
    rel = path.relative_to(PROJECT_ROOT).as_posix()
    try:
        content = path.read_text(encoding="utf-8")
    except Exception as e:
        return [{"file": rel, "line": 0, "severity": "error", "message": f"Failed to read: {e}"}]

    for rule in RULES:
        # Проверка scope.
        if "scope" in rule:
            if not rel.startswith(rule["scope"].rstrip("/")):
                continue
        # Исключения.
        if rule.get("exclude_paths"):
            skip = False
            for ex in rule["exclude_paths"]:
                if ex in rel:
                    skip = True
                    break
            if skip:
                continue
        # Поиск паттерна.
        for match in rule["pattern"].finditer(content):
            line_no = content[:match.start()].count("\n") + 1
            line = content.split("\n")[line_no - 1].strip()
            # Пропускаем комментарии и @export директивы.
            if line.startswith("#") or line.startswith("##") or "@export" in line:
                continue
            violations.append({
                "file": rel,
                "line": line_no,
                "severity": rule["severity"],
                "rule": rule["id"],
                "message": rule["message"],  # без format — упрощение
                "context": line[:100] + (line[100:] and "..."),
            })
    return violations


def main():
    """Запуск всех проверок."""
    strict = "--strict" in(sys.argv)

    targets = []
    if strict:
        # Strict: проверяем ВСЁ включая тесты и контент.
        for root in [CORE_DIR, SCENES_DIR, TESTS_DIR]:
            if root.exists():
                targets.extend(root.rglob("*.gd"))
    else:
        # Default: только core/ и scenes/ (не тесты).
        for root in [CORE_DIR, SCENES_DIR]:
            if root.exists():
                targets.extend(root.rglob("*.gd"))

    all_violations = []
    for path in sorted(targets):
        if should_check_file(path):
            all_violations.extend(check_file(path))

    errors = [v for v in all_violations if v["severity"] == "error"]
    warnings = [v for v in all_violations if v["severity"] == "warning"]
    infos = [v for v in all_violations if v["severity"] == "info"]

    print(f"\n=== Lint Results ({len(targets)} files scanned) ===\n")
    print(f"  Errors:   {len(errors)}")
    print(f"  Warnings: {len(warnings)}")
    print(f"  Info:     {len(infos)}\n")

    if errors:
        print("=== ERRORS (must fix) ===\n")
        for v in errors:
            print(f"  [{v['rule']}] {v['file']}:{v['line']}")
            print(f"    {v['context']}")
            print(f"    → {v['message']}\n")

    if warnings:
        print("=== WARNINGS ===\n")
        for v in warnings[:20]:
            print(f"  [{v['rule']}] {v['file']}:{v['line']}: {v['message']}")

    if errors:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
