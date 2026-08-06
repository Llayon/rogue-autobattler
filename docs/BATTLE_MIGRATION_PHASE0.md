# Battle Migration Phase 0 Audit

Date: 2026-08-06
Repository: `C:\Users\user\Documents\GodotProjects\RogueAutoBattler`
Branch: `master`
HEAD before Phase 0 changes: `f44a295` (`fix(web): reward modal + shop split (local fix, awaiting deploy)`)
Godot executable: `/tmp/godot47.exe`, reported `4.7.stable.official.5b4e0cb0f`

## Scope boundary

This phase intentionally changes only characterization tests, characterization fixture documentation, the migration plan, and the test workflow. It does **not** introduce `RunUnit.instance_id`, `RunItem.instance_id`, Save Schema v4, `BattleSetup`, `BattleSimulation`, ECS code, or balance changes.

## Commands and actual results

### Existing regression suite

```text
/tmp/godot47.exe --headless --path . --script tests/run_tests.gd
```

Result:

```text
EXIT_CODE=0
=== Result: 495 passed, 0 failed ===
```

The command was run twice before characterization changes; both runs returned `0` and `=== Result: 495 passed, 0 failed ===`. The final Phase 0 run also returned `0` with the same result.

The test output contained no `SCRIPT ERROR`, `Parse Error` or `ERROR:` matches in the checked output. The existing suite printed many informational `GameLog` lines, which are expected runtime logs rather than failures.

### Anti-pattern lint

```text
python tools/lint_anti_patterns.py
```

Result:

```text
EXIT_CODE=0
75 files scanned
Errors:   0
Warnings: 5
Info:     292
```

The five existing warnings are `no-classification-flags` matches in:

- `core/balance.gd:175`
- `core/balance.gd:198`
- `core/balance.gd:252`
- `core/balance.gd:259`
- `scenes/main_menu/main_menu.gd:193`

They are pre-existing warnings; Phase 0 introduced no lint errors.

### Editor/headless parse check

```text
/tmp/godot47.exe --headless --editor --path . --quit
```

Result:

```text
EXIT_CODE=0
```

The checked output contained no `SCRIPT ERROR`, `Parse Error` or `ERROR:` matches.

### New legacy characterization suite

```text
/tmp/godot47.exe --headless --path . --script tests/legacy_characterization/legacy_characterization_test.gd
```

Result:

```text
EXIT_CODE=0
=== Legacy characterization: 25 passed, 0 failed ===
```

The suite covers:

- one warrior versus one enemy;
- exact observed tick termination and winner;
- independent state for two equal definitions;
- periodic damage kill;
- stun behavior at the runner guard and direct `Combatant.basic_attack()` seam;
- declared multi-effect order;
- same-seed repeated result (winner, tick count, final HP).

The direct `Combatant.basic_attack()` test intentionally records an observed legacy quirk: the method itself does not reject a stunned attacker; `BattleRunner._tick_unit()` performs that guard. This is characterization, not a normative requirement for the future simulation contract.

### Repeated characterization / nondeterminism probe

The characterization script was run 100 times in separate Godot processes:

```text
for i in $(seq 1 100); do
  /tmp/godot47.exe --headless --path . --script tests/legacy_characterization/legacy_characterization_test.gd
 done
```

Observed result for all 100 runs:

```text
=== Legacy characterization: 25 passed, 0 failed ===
```

All 100 runs returned exit code `0`. The collected outputs contained zero `SCRIPT ERROR`, `Parse Error`, `ERROR:` or `[FAIL]` lines.

This probe establishes repeatability for the current minimal cases. It does not prove all legacy battle paths are deterministic. A broader 100-seed characterization matrix remains a post-Phase-0 follow-up.

## Nondeterminism findings

### Confirmed current behavior

- Legacy randomness is process-global static state in `core/utils/rng_service.gd` (`static var _rng`). Callers use the `Rng.*` API, but there is no simulation-scoped owner or channel trace yet.
- Battle formulas and effects consume the shared stream through `Rng.chance`, `Rng.randf_range`, `Rng.randi_range` and `Rng.pick`.
- `core/battle/cooldown_list.gd` iterates dictionary keys during serialization/ticking. This was not exercised by the minimal characterization scenarios and therefore remains a risk to investigate before ECS.
- The current minimal cases did not expose `Array.shuffle()` use in the battle path. Existing `Rng.pick_unique()` and encounter-map code use explicit Fisher–Yates-like logic instead.

### No fix applied in Phase 0

No RNG or battle production code was changed. The requested simulation RNG contract is intentionally deferred to the post-Phase-0 phase, before `BattleSetup` and ECS.

## CI gate added

`.github/workflows/test.yml` now runs, in order:

1. install Godot 4.7;
2. `python tools/lint_anti_patterns.py`;
3. headless editor parse check with stderr pattern guard;
4. existing `tests/run_tests.gd` regression suite with stderr pattern guard;
5. the legacy characterization suite three times and checks that all result lines agree.

The Web workflow remains separate and still preserves the known required `mkdir -p build`, `set -eo pipefail` and `Web (no threads)` behavior.

## Known limitations and problems

1. Characterization currently uses isolated runtime object references because stable persisted instance IDs are explicitly deferred until Save Schema v4. It does not claim to test save identity.
2. Characterization is a dedicated script, not yet a large fixture corpus. The remaining scenarios (multi-unit target tie-breaks, shield/block, counterattack, simultaneous deaths, healing and full reaction chains) should be added after this Phase 0 approval and before normative contract implementation.
3. The repository's existing `tests/run_tests.gd` remains a monolithic 495-assertion harness. Splitting it into legacy characterization and normative contract directories is planned, but only the minimal legacy characterization suite was added in Phase 0.
4. CI was edited locally but not pushed or observed in GitHub Actions in this phase. Remote verification requires a push/PR and is intentionally not performed here.
5. Current branch contains an untracked plan file from the earlier planning turn; it is included in the Phase 0 commit as documentation.

## Phase 0 acceptance

- Baseline regression suite: PASS, 495 passed / 0 failed.
- New characterization suite: PASS, 25 passed / 0 failed.
- Editor parse: PASS.
- Lint: PASS with 0 errors and 5 pre-existing warnings.
- 100 repeated characterization runs: PASS, stable result and no captured runtime error markers.
- No BattleSetup, instance migration, Save Schema v4 or ECS implementation performed.
