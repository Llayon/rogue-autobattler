---
title: Rogue AutoBattler
layout: default
---

# 🗡️ Rogue AutoBattler

A roguelike RPG auto-battler built with Godot 4.7. Pit procedurally-generated armies
against waves of enemies, watch them fight, and grow stronger with each victory.

## 🤖 Play in Browser

**[▶ Play Now](build/index.html)** — WebAssembly build, no install required.

> Just open the link, wait for the WebAssembly to load (~2 MB), and click to start.
> Use `SPACE` to begin the battle, `1/2/4` to change speed, `R` to restart.

## 🎮 Features

- **14 unique units** with 13 characteristics each (crit, dodge, lifesteal, thorns, mana, CDR, ...)
- **5 enemy factions** with tier-based progression
- **10 abilities** (cleave, chain lightning, stun, heal, shield, slow, ...)
- **Reactions system** (Attack of Opportunity, Shield Block)
- **Procedural generation** with deterministic seed → same seed = same run
- **Degrees of Success** (Pathfinder 2e inspired): 4 outcomes per check
- **Meta-progression**: unlock new units between runs
- **Visible battle simulation** with HP bars, cooldown rings, status icons

## 📊 Architecture

Built on a clean component-composition architecture:

```
core/                      # Pure game logic (no Node dependencies)
├── battle/                # Combatant, BattleContext, BattleRunner
├── effects/               # EffectResource (Damage, Heal, Shield, Status, AoO, ChainLightning)
├── abilities/             # AbilityResolver + 9-targeting TargetingResolver
├── ai/                    # DefaultAi (extensible interface)
├── data/                  # Resource definitions (UnitDef, AbilityDef, StatusDef, ReactionDef)
├── progression/           # RunController, MetaProfile, UnlockManager
├── utils/                 # EventBus, Rng, SaveService, ContentDB, Logger
└── balance.gd             # Single source of truth for game constants

scenes/                    # Visualization layer (UI, overlays, scene glue)
content/                   # .tres data (units, enemies, abilities, statuses, reactions)
tools/                     # Linter, archive, dev scripts
tests/                     # Headless test suite (471 tests)
```

## 🛠️ Development

Requires **Godot 4.7+** (Mono not needed).

```bash
# Run tests
godot --headless --path . --script tests/run_tests.gd

# Run linter
python tools/lint_anti_patterns.py

# Open in editor
godot --path .
```

## 📦 Build for Web

```bash
# Install export templates (one-time)
# Download from https://github.com/godotengine/godot-builds/releases/download/4.7-stable/Godot_v4.7-stable_export_templates.tpz
# Extract to %APPDATA%/Godot/export_templates/4.7.stable/

# Build
godot --headless --export-release "Web" docs/build/index.html
```

## 📝 License

[MIT](LICENSE)
