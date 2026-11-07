# CI INTEGRITY + RUNFLOW ENTRY SAFETY — FINAL REPORT

**Branch:** `fix/ci-integrity-runflow-entry`
**Base:** `e9d4e4e8e6c0ac248e4630016fee23d30f1304f2` (published: RUN INTEGRITY
POST-CLOSURE HARDENING / GREEN, CI run `42359551317`)
**Worktree:** `%LOCALAPPDATA%\Temp\ri-ci-entry`
**NO PUSH.**

---

## A. BASELINE AND WORKTREE

The branch is based on the exact published SHA of the Run Integrity
hardening. The canonical, inventory and A–H worktrees are untouched, and
the published remote branch still points at the base.

The historical numbers of the base are an orientation, not a result of
this branch: 118 suites / 9092 assertions / 0 fail / 0 unparsed, A–H PASS
with 8 + 8 fixtures, NC-01..NC-43 = 43/43 RED, the 14 hardening controls
= 14/14 RED, the 7 ledger controls = 7/7 RED.

The worktree was created from the published SHA and got its own
`.godot` cache copy, so the class_name registry resolves.

---

## B. CONFIRMED ROOT CAUSES

### CI-01 — the standalone runner was not fail-closed

`tools/run_battle_ecs_suites.py`:

1. `discover()` may return an empty list. The main loop iterates over
   it, the body never runs, `failures` stays empty and `main()` prints
   `RUNNER: GREEN` and returns 0.
2. `--only` that matches nothing narrows the list to nothing and takes
   the same path.
3. The parsed summary is only counted: `summary[0] > 0` was never
   required, so a suite that printed `0 pass / 0 fail` counted as a
   pass.

### CI-02 — the A–H differential was not fail-closed

`tools/run_ah_semantic_differential.py`:

- **A.** `run_probe()` returns the return code and both `rc_b` / `rc_c`
  are printed, but the final result was the COMPARATOR's return code.
  A probe that exited non-zero after writing valid snapshots still
  yielded PASS.
- **B.** Only the NON-EMPTINESS of the fixture lists was checked.
- **E.** The `PASS (8 fixtures)` message was a fixed string.

`tools/compare_ah_semantic_differential.py`:

- **C.** `compare()` checked the COUNT equality and then compared the
  records pairwise, so two sides carrying the same SEVEN fixtures
  passed and a duplicated name was compared against itself.
- **D.** `load_fixtures()` swallowed a malformed fixture line and a
  malformed NESTED event, so a damaged record disappeared instead of
  failing.

**G2.4 — the baseline worktree was written to.** The runner copied the
probe into the BASELINE tree, modifying a tracked file of the
historical baseline.

### RUN-ENTRY-01 — the battle entry was not guarded

`core/progression/run_controller.gd`:

```gdscript
if phase != Phase.PREP and phase != Phase.MAP:
    return false
if state.get_board_units().is_empty():
    return false
```

Any PREP or MAP with a unit on the board started a battle. But the
phase alone is not a readiness proof: a PREP can be the initial
preparation, a selected COMBAT, a MERCHANT visit or a post-defeat
preparation, and a MAP means "the player must select a node".

### RUN-ENTRY-02 — the merchant input path

The shop scene closes on SPACE and on ESC, and the battle scene starts
a battle on SPACE in PREP. The finding was VERIFIED, not assumed: the
baseline behaviour was already correct for the merchant, because the
shop's handler closes the shop and the phase becomes MAP, so the battle
scene's SPACE handler does not fire. The suite locks that behaviour
down.

---

## C. RED REPRODUCTION

| Suite | RED on the baseline | GREEN after the fix |
|---|---|---|
| `tests/ci/standalone_runner_test.py` | 7 of 13 checks failed | 13 / 13 |
| `tests/ci/ah_differential_test.py` | 5 of 15 checks failed | 20 / 20 |
| `tests/run_integrity/battle_entry_guard_test.gd` | 8 assertions failed | 32 / 32 |
| `tests/run_integrity/merchant_input_path_test.gd` | the baseline was already correct | 18 / 18 |

Every RED was semantic: a non-zero exit, a semantic assertion failure,
no parse error and no script error.

---

## D. STANDALONE RUNNER CONTRACT

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

The suite COUNT is free to grow — there is NO hard-coded number — but
it must never be zero. An unmatched `--only` filter is RED. The
SPECIAL PROBES stay excluded: they are judged by the A–H comparator,
which has its own contract.

---

## E. A–H STRICT COMPARATOR CONTRACT

The canonical eight scenarios:

```
A_scheduled_nonlethal  B_scheduled_lethal  C_counterattack  D_aoo
E_aoo_counter          F_direct_damage     G_real_burn      H_full_battle
```

A successful comparison requires:

- both processes exit 0;
- the fixture set is EXACTLY A–H, once each, on BOTH sides;
- every fixture line that carries the fixture marker parses;
- every nested event JSON parses;
- the mandatory sections (world, rng, emitter, result, events) are
  present;
- the existing semantic comparison passes unchanged.

The comparator and the runner now expose PURE decision functions
(`probe_failure_reason`, `import_failure_reason`) so the contract is
tested BEHAVIOURALLY. The baseline is an isolated COPY: the historical
worktree is never written to, and the copy is removed afterwards. A
failed Godot editor import blocks the run.

---

## F. BATTLE ENTRY STATE MATRIX

| State | Battle allowed | Why |
|---|---|---|
| the initial preparation (`current_encounter_id == -1`) | YES | the first battle of a run |
| a selected COMBAT / ELITE / BOSS | YES | the current encounter is a combat node |
| a post-defeat preparation | YES | the current encounter is the combat node that was fought |
| a MERCHANT visit | NO | the phase is PREP, but the player is in the shop |
| a SERVICE encounter (the merchant flag cleared) | NO | the current encounter is not a combat node |
| MAP without a selection | NO | a MAP means "the player must select a node" |
| MAP after a service | NO | the same |
| REWARD | NO | the offer is shown |
| GAMEOVER | NO | the run is over |

The readiness is derived from the state that ALREADY exists — the
phase, the merchant context and the encounter map. No new runtime flag
was introduced, so nothing can be lost by a Continue, and the v4/v5
checkpoints are untouched.

The refusal happens BEFORE the BattleContext creation, the reaction
registry clearing, the enemy generation, the RNG consumption and the
battle participant mapping. The suite asserts that the phase, the map,
the merchant offer and flag, the state, the context, the runner, the
participants, the RNG stream, the save count and the meta are all
UNCHANGED by a refusal.

---

## G. MERCHANT INPUT BEHAVIOUR

The checks push a real key event through the viewport; the handler is
never called directly.

| Input | Result |
|---|---|
| MERCHANT visible + SPACE | the shop closes, the phase is MAP, NO battle starts |
| MERCHANT visible + ESC | the shop closes, the phase is MAP, NO battle starts |
| a normal PREP + SPACE | a valid battle starts |
| an invalid MAP + SPACE | NO battle starts |

The last case holds because of the controller guard, not because of the
scene: the scene's SPACE handler calls `start_battle()`, and the
controller refuses the illegal context.

---

## H. PRODUCTION CHANGES

| File | Change |
|---|---|
| `core/progression/run_controller.gd` | `_battle_entry_ready()` and `_current_encounter_is_combat()`; `start_battle()` calls the guard before anything else |
| `tools/run_battle_ecs_suites.py` | the empty-discovery guard, the positive-assertion guard, the count agreement |
| `tools/compare_ah_semantic_differential.py` | the strict loader, the canonical fixture set, the mandatory sections, the real count |
| `tools/run_ah_semantic_differential.py` | the probe and import decisions, the isolated baseline copy, the reported fixture ids |
| `.github/workflows/test.yml` | five new steps for the new contract checks |

Nothing else in `core/` or `scenes/` changed. The shipping content,
the balance, the gameplay RNG, the Battle ECS combat semantics, the
Clock Policy and the v4/v5 formats are UNCHANGED.

---

## I. TEST CHANGES

New:

```
tests/ci/standalone_runner_test.py
tests/ci/ah_differential_test.py
tests/run_integrity/battle_entry_guard_test.gd
tests/run_integrity/merchant_input_path_test.gd
tests/run_integrity/battle_entry_fixtures.gd
```

Migrated: eight pre-existing suites reached a started battle through
states the game cannot produce (`_enter_map()` then `start_battle()`,
or a boss id written into the state by hand). NONE of them was testing
the map; they needed a STARTED BATTLE. The fixtures were rebuilt on the
production paths — the first battle of the run, and the walk to the
boss through the map's own transition — and the assertions are
unchanged.

---

## J. NEGATIVE CONTROLS

| Control | Mutation | Verdict |
|---|---|---|
| NC-CI01-A | remove the empty-discovery guard | RED |
| NC-CI01-B | remove the positive-assertion guard | RED |
| NC-CI01-C | the unmatched `--only` filter is ignored | RED |
| NC-AH-A | the baseline return code is ignored | RED |
| NC-AH-B | accept a missing fixture | RED |
| NC-AH-C | accept a duplicated fixture name | RED |
| NC-AH-D | skip a malformed nested JSON | RED |
| NC-AH-E | ignore a failed import | RED |
| NC-ENTRY-A | remove the merchant guard | RED |
| NC-ENTRY-B | allow a MAP battle without a selection | RED |
| NC-ENTRY-C | consume the battle readiness incorrectly | RED |
| NC-ENTRY-D | allow a repeat combat from a completed encounter | RED |
| NC-ENTRY-E | the shop closes without releasing the merchant context | RED |

Two of them were MISSED at first, and both were real gaps: NC-ENTRY-D
needed a case for a SERVICE encounter, and NC-AH-A / NC-AH-E mutate the
RUNNER while the self-tests only looked at the comparator.

---

## K. HISTORICAL NC PRESERVATION

```
NC-01..NC-43   44 semantic RED, 0 SKIP, 0 INVALID, the tree CLEAN
NC-H01..NC-H12 14/14 RED
NC-H10A..NC-H10G 7/7 RED
the ledger      VALID
```

The historical matrix lives OUTSIDE the repository (it was a scratch
harness); it was re-pointed at this worktree and run. Three of its
anchors had drifted after the H-12 fix of the previous series; the
anchors were re-targeted WITHOUT changing the semantic mutation.

---

## L. FULL REGRESSION

Every gate was executed; none of them was taken on trust.

| Gate | Suites | Assertions | Failures | Unparsed | rc |
|---|---|---|---|---|---|
| the standalone runner | 120 | 9165 | 0 | 0 | 0 |
| the legacy characterization | — | — | 0 | — | 0 (identical across 3 runs) |
| the lint | — | — | 0 errors, 5 warnings | — | 0 |
| the editor parse | — | — | 0 parse errors, 0 script errors | — | 0 |
| the CI gates | 10 | — | 0 | — | 0 |
| the A-H differential | 8 + 8 fixtures | — | 0 | 0 | 0 on both sides |
| the test reachability audit | 180 declared | — | 0 dead | — | 0 |
| the test exit-contract audit | 125 suites | — | 0 unsafe exit paths | — | 0 |
| the standalone runner self-tests | 13 | — | 0 | — | 0 |
| the A-H comparator self-tests | 20 | — | 0 | — | 0 |
| the NC-CI01 controls | 3 | — | 0 | 0 | 0 |
| the NC-AH controls | 5 | — | 0 | 0 | 0 |
| the NC-ENTRY controls | 5 | — | 0 | 0 | 0 |
| the historical NC-01..NC-43 | 44 | — | 0 | 0 | 0 |
| the hardening NC-H01..NC-H12 | 14 | — | 0 | 0 | 0 |
| the ledger controls | 7 | — | 0 | 0 | 0 |
| the ledger validator | — | — | 0 | — | 0 (VALID) |

The A-H differential on the final tree:

```
baseline fixtures  : 8 (rc=0)
candidate fixtures : 8 (rc=0)
PASS (8 fixtures, legacy-projected traces + world + rng + emitter + result all identical)
baseline fixture ids  == candidate fixture ids
```

The historical baseline worktree was CLEAN after the run: the probe is
copied into an isolated COPY, so the tracked file of the historical
baseline is never written to.

---

## M. INDEPENDENT CRITIC FINDINGS

An independent critic read the whole diff and the new production code,
and hunted the twenty listed classes of defect. Its verdict was
**HOLD** — with **no HIGH** finding, two MAJOR and three MINOR.

### MAJOR-1 — the negative-control harness was not crash-safe

The harness wrote a MUTATED tracked production file in place and
restored it in a `finally:` block. A kill between the write and the
restore — a CI job timeout, a Ctrl-C, a reboot — left the tracked file
mutated.

**Closed.** The restore is now ATOMIC (a temp file plus `os.replace`,
so a reader never sees a half-written file) and VERIFIED (the bytes
are compared with the original, and a mismatch is a loud failure). The
three harnesses share the fix.

### MAJOR-2 — the post-defeat retry was not covered

The post-defeat retry is the ONE legal PREP origin whose encounter id
is stale BY CONSTRUCTION: the loss branch of `_on_battle_ended()`
grows the round and returns the run to PREP, but it does NOT change
`current_encounter_id`, so the DEFEATED combat node is still current.
The guard accepts it, but no test exercised it. The critic was right:
a future change that required "not yet completed" would have broken
the retry with nothing catching it.

**Closed.** Two cases now drive a REAL loss through the production
path — the initial battle and a real combat node. Both assert that the
run returns to PREP, that the defeated node is still current, that the
retry starts the battle, that the phase becomes BATTLE and that the
outcome is not repeated.

### MINOR-1 — a stale comment

The A–H self-test comment still claimed a source-text inspection while
the code checked the behaviour. **Closed.**

### MINOR-2 — the PASS count was re-derived

The comparator re-read the baseline file to get the fixture count. If
the fixture-set check were ever weakened, the message could report a
count that was never compared. **Closed:** `compare()` now REPORTS the
number of PAIRS it walked.

### MINOR-3 — the copy took the cache

The baseline copy took the `.godot` cache with it — the largest part of
the tree. **Closed:** the cache is built in the copy by `import_cache()`,
the same path a fresh checkout takes.

### What the critic confirmed clean

The critic verified the twenty hunt items and named the verified
evidence for each. The most important ones:

- the production diff of `run_controller.gd` is 55 lines, ALL of it the
  two new helpers plus the guard call — everything after the guard is
  byte-identical to the base, so no battle semantics changed;
- the guard is the FIRST statement of `start_battle()`, before the
  context creation, the reaction registry clearing, the enemy wave and
  the participant bridge — so a refusal consumes no RNG and writes no
  checkpoint;
- every `_assert(...)` of the eight migrated suites survives: the
  migrations are setup-only, and several cases were STRENGTHENED (the
  old "fight the first reachable node" fallback could pick a SERVICE
  node; the new walk cannot);
- all three control suites were re-run in an ISOLATED copy — 3/3, 5/5
  and 5/5 RED, restore GREEN;
- the "unmigrated" suites the critic flagged were checked directly:
  their calls are legal, because a bare controller is in the INITIAL
  preparation (`phase = PREP`, `current_encounter_id = -1`).

---

## N. v4/v5 COMPATIBILITY

The v5 mapper, the v4 mapper and the schema files are UNCHANGED. The
battle-entry guard reads only `state.current_encounter_id` and
`state.just_visited_merchant`, both of which were already persisted.
The guard adds no field, so no checkpoint can describe a state the
format cannot express.

---

## O. RNG / DETERMINISM VERIFICATION

The guard consumes NO RNG: it reads the phase, the merchant flag and
the map node. A refused `start_battle()` does not create a context, does
not clear the reaction registry, does not generate enemies and does not
draw. The suite asserts that the RNG snapshot is byte-identical before
and after a refusal.

The A–H differential passed with the RNG state compared exactly on all
eight fixtures.

---

## P. ACTUAL COMMIT GRAPH

```
e9d4e4e  the published Run Integrity hardening (the base)
  |
  +-- 194ba3f  test(ci): characterize the empty standalone suite behavior
  +-- 0a1fbd4  fix(ci): reject empty and zero-assertion suites
  +-- 33df14f  test(ah): characterize incomplete and failed probes
  +-- b96e42e  fix(ah): enforce the strict differential contract
  +-- 8a21079  test(run): characterize the invalid battle entry
  +-- f458f26  fix(run): enforce the legal battle entry
  +-- d9bc3e0  test(ui): verify the merchant SPACE and ESC handling
  +-- 508c76f  test(run): rebuild the battle fixtures on the production paths
  +-- 7fe8cca  test(run): reach the battle contexts the way the player does
  +-- cc31042  test(gauntlet): prove the negative controls
  +-- a193cbd  test(ah): check the runner contract behaviourally
  +-- e2fddb7  chore(ci): run the new contract checks on the runner and the guard
  +-- f32934a  docs(gauntlet): write the CI and runflow entry report
  +-- bbcb827  docs(gauntlet): record the measured regression results
  +-- 3481725  fix(gauntlet): close the critic findings
  +-- 16fc150  fix(gauntlet): make the post-defeat cases degrade gracefully
```

Sixteen commits over the base. Each RED/FIX pair is two commits: the
characterisation, then the fix. The production change of the battle
entry is a SINGLE commit.

Each RED/FIX pair is two commits: the characterisation, then the fix.
The production change of the battle entry is a SINGLE commit.

---

## Q. REMAINING RISKS

1. The battle-entry guard is derived from the CURRENT encounter. A run
   that reaches the PREP phase through a path the guard does not know
   would be refused. The four known paths are covered by tests.
2. The A–H runner copies the whole baseline tree into a temporary
   directory. That costs disk space and time on a large tree.
3. The CI self-tests of the runner use a FAKE godot, so they prove the
   runner's LOGIC, not the interaction with a real Godot binary. The
   real interaction is covered by the real A–H differential.
4. The historical NC matrix still lives outside the repository. It is
   reproducible, but it is not in the tree.

---

## R. FINAL STATUS

```
CI INTEGRITY + RUNFLOW ENTRY SAFETY
= READY
```

The independent critic held the branch for two MAJOR findings. Both are
closed and verified: the harness restore is atomic and verified, and
the post-defeat retry — the one legal PREP origin whose encounter id is
stale by construction — now has two cases that drive a real loss
through the production path.

There is no open HIGH or MAJOR finding. The three MINOR findings are
closed as well.

**The branch is NOT published.** It is a local branch over the exact
published SHA, the working tree is clean, and nothing was pushed, force
pushed, rebased or reset.

The A0 Persistence Transaction Gauntlet and the architectural migration
were NOT started.

What the next stage would still need, and what this series did NOT
claim:

- the crash and restart recovery of `CHECKPOINT_AND_META`, `TREASURE`
  and `FINALIZE_RUN`, the atomic MetaProfile and the stale cleanup
  protection remain unproven — they belong to A0;
- the battle-entry guard derives the readiness from the CURRENT
  encounter, so a PREP path the guard does not know would be refused.
  The four known paths are covered by tests;
- the CI self-tests of the runner use a FAKE godot, so they prove the
  LOGIC of the runner, not the interaction with a real Godot binary.
  The real interaction is covered by the real A–H differential.
