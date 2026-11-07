# CI INTEGRITY + RUNFLOW ENTRY SAFETY — LEDGER

**Branch:** `fix/ci-integrity-runflow-entry`
**Base:** `e9d4e4e8e6c0ac248e4630016fee23d30f1304f2` (published: RUN INTEGRITY POST-CLOSURE HARDENING / GREEN)
**Worktree:** `%LOCALAPPDATA%\Temp\ri-ci-entry`
**Published remote:** `canonical/phase3/effect-status-trigger-gauntlet` → `e9d4e4e`
**NO PUSH.**

---

## G0 — BASELINE

The branch is based on the exact published SHA. The canonical, inventory
and A–H worktrees are untouched. The hardening branch
(`fix/run-integrity-postclosure-hardening`, `e9d4e4e`) stays where it is.

The historical numbers are an orientation, not a result of this branch:
118 suites / 9092 assertions / 0 fail / 0 unparsed, A–H PASS with 8+8
fixtures, NC-01..NC-43 = 43/43 RED, the 14 hardening controls = 14/14
RED, the 7 ledger controls = 7/7 RED.

---

## G1 — CI-01: the standalone runner is not fail-closed

### Confirmed root causes

`tools/run_battle_ecs_suites.py`:

1. **Empty discovery is GREEN.** `discover()` returns a list; the main
   loop iterates over it. With an empty list the loop body never runs,
   `failures` stays empty, and `main()` prints `RUNNER: GREEN` and
   returns 0 (lines 167–174, 241–251). Nothing proves that a single
   suite existed.
2. **`--only` without a match is GREEN.** The filter narrows the list
   to nothing; the same empty path follows (lines 168–169).
3. **A suite with `0 pass / 0 fail` is GREEN.** The parsed summary is
   only used for the counters; `summary[0] > 0` is never required
   (lines 211–219). A suite that asserts nothing counts as a pass.
4. **A suite with `rc != 0` is reported** — but only when the summary
   parsed. The non-zero rc IS part of `problems` (line 214), so this
   one is covered; the gap is the combination with an empty discovery.

### Contract

```
discovered suites > 0
executed suites == discovered suites
passed suites == executed suites
passed assertions per suite > 0
failed suites == 0
failed assertions == 0
unparsed == 0
all process return codes == 0
```

The suite count must be allowed to grow; it must never be zero. There
is NO hard-coded `118`.

---

## G2 — CI-02: the A–H differential is not fail-closed

### Confirmed root causes

`tools/run_ah_semantic_differential.py`:

- **A.** `run_probe()` returns the return code (line 42) and both
  `rc_b` / `rc_c` are printed (lines 94, 99), but the final result is
  the COMPARATOR's return code only (line 116). A probe that exits
  non-zero after writing valid snapshots still yields PASS.
- **B.** Only the NON-EMPTINESS of the fixture lists is checked
  (line 102). The canonical set A–H is never required.
- **E.** The `PASS (8 fixtures)` message is a fixed string.

`tools/compare_ah_semantic_differential.py`:

- **C.** `compare()` checks the COUNT equality (line 127) and then
  compares the records pairwise. Two sides that both contain the same
  SEVEN fixtures pass; a duplicated fixture name is not detected.
- **D.** `load_fixtures()` swallows a malformed fixture line
  (`except json.JSONDecodeError: continue`, lines 55–58) and swallows a
  malformed NESTED event (`except json.JSONDecodeError: pass`, lines
  64–67). A damaged record disappears instead of failing.

### G2.4 — the baseline worktree is written to

`run_ah_semantic_differential.py` line 70 copies the probe from the
candidate into the BASELINE tree:
`shutil.copyfile(probe_src, probe_dst)`. That modifies a tracked file
of the historical baseline worktree. The copy must happen in an
isolated temporary copy, or the original must be restored.

### The canonical eight fixtures

```
A_scheduled_nonlethal
B_scheduled_lethal
C_counterattack
D_aoo
E_aoo_counter
F_direct_damage
G_real_burn
H_full_battle
```

---

## G3 — RUN-ENTRY-01: the battle entry is not guarded

### Confirmed root cause

`core/progression/run_controller.gd` line 710:

```gdscript
if phase != Phase.PREP and phase != Phase.MAP:
    return false
if state.get_board_units().is_empty():
    return false
```

Any PREP or MAP with a unit on the board starts a battle. The phase
alone is not a readiness proof.

### The legitimate PREP states (from the production chains)

| PREP origin | Where |
|---|---|
| the first battle of a run | `start_run()` → `_set_phase(Phase.PREP)` (line 126) |
| a selected COMBAT | `_on_node_selected()` → `node.is_combat()` → `_set_phase(Phase.PREP)` (lines 1672–1673) |
| a post-defeat retry | `_on_battle_ended()` → the loss branch → `_set_phase(Phase.PREP)` (line 1021) |
| a MERCHANT visit | `_apply_merchant_effect()` → the phase stays PREP and `state.just_visited_merchant = true` (line 1831) |

And the MAP state: `start_battle()` accepts MAP outright, although MAP
means "the player must select a node".

### The illegal paths

```
MERCHANT open          -> start_battle()
MAP without a selection -> start_battle()
MAP after a service    -> start_battle()
GAMEOVER               -> start_battle()   (the phase guard catches it)
REWARD                 -> start_battle()   (the phase guard catches it)
```

### The refusal must be atomic

The refusal happens BEFORE: the BattleContext creation, the reaction
registry clearing, the enemy generation, the RNG consumption and the
battle participant mapping.

---

## G4 — RUN-ENTRY-02: the merchant input path

`scenes/shop/shop_scene.gd` closes the shop on SPACE, and
`scenes/battle/battle_scene.gd` can start a battle on SPACE in PREP.
The two handlers must not both consume the same event.

---

## THE NEGATIVE CONTROL MATRIX

| Control | Mutation | Expectation |
|---|---|---|
| NC-CI01-A | remove the empty-discovery guard | semantic RED |
| NC-CI01-B | remove the positive-assertion guard | semantic RED |
| NC-CI01-C | remove the unmatched `--only` guard | semantic RED |
| NC-AH-A | ignore the baseline return code | semantic RED |
| NC-AH-B | accept a missing fixture | semantic RED |
| NC-AH-C | accept a duplicated fixture name | semantic RED |
| NC-AH-D | skip a malformed nested JSON | semantic RED |
| NC-AH-E | ignore a failed import | semantic RED |
| NC-ENTRY-A | remove the merchant guard | semantic RED |
| NC-ENTRY-B | allow a MAP battle without a selection | semantic RED |
| NC-ENTRY-C | consume the battle readiness incorrectly | semantic RED |
| NC-ENTRY-D | allow a repeat combat from a completed encounter | semantic RED |
| NC-ENTRY-E | reintroduce the SPACE double-handling | semantic RED |

The historical matrix is preserved: NC-01..NC-43, the 14 hardening
controls and the 7 ledger controls.

---

## THE STATUS TABLE

| Finding | Status | RED | FIX |
|---|---|---|---|
| CI-01 | CONFIRMED | pending | pending |
| CI-02 | CONFIRMED | pending | pending |
| RUN-ENTRY-01 | CONFIRMED | pending | pending |
| RUN-ENTRY-02 | CONFIRMED | pending | pending |
