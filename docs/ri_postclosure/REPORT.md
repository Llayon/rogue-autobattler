# RUN INTEGRITY POST-CLOSURE HARDENING — REPORT

**Repository:** `Llayon/rogue-autobattler`
**Baseline:** `8642de541da88c7d76fe7f083997360a143c355f` (published integration)
**Base commit of the branch:** `15628b885f10b8f5ade0a3e8296878ee7c45d8a9`
**Branch:** `fix/run-integrity-postclosure-hardening`
**Worktree:** `%LOCALAPPDATA%\Temp\ri-hardening` (isolated)

---

## A. ACTUAL BASELINE

The published integration was verified by its own CI run
<https://github.com/Llayon/rogue-autobattler/actions/runs/42258689657>:
106 suites / 8735 assertions, 0 fail / 0 unparsed, A-H differential PASS,
`battle-ecs` success, `save-battle-migration` success, NC-01..NC-43 = 43/43
semantic RED.

The branch base is `15628b8`, the UNPUBLISHED publication-ledger commit on
top of the published integration. It touches no production code -- it
records the facts of the publication in
`.hermes/plans/run_integrity_ledger.json`. It is kept, not cherry-picked,
because it IS the base of the branch.

**The historical numbers are NOT reused as the current result.** Every
number below was measured on the hardening branch itself.

---

## B. GIT / WORKTREE ISOLATION

- The hardening work happened in an isolated worktree on a dedicated
  branch. The canonical worktree, the inventory worktree (`4986157`) and
  the A-H baseline worktree were never modified.
- Every package is a separate logical commit: a RED commit and a FIX
  commit.
- The existing commit-msg hook (Conventional Commits with a mandatory
  scope) was honoured; several first drafts were rejected by it and
  corrected.
- **NO PUSH.** The branch is local only.

---

## C. ALL 11 FINDINGS AND THEIR DISPOSITIONS

| ID | Disposition | RED | FIX |
|---|---|---|---|
| H-01 | FIXED | `5048c9d` | `5695085` `1084de2` |
| H-02 | FIXED | `8a17df2` | `8f4e680` |
| H-03 | FIXED | `3c85fef` | `bc3365e` |
| H-04 | ALREADY FIXED (core) + FIXED (presentation) | `443c49b` | `5d380c0` |
| H-05 | FIXED | `8a73743` | `022ec47` |
| H-06 | FIXED | `858cf70` | `4ee9feb` |
| H-07 | FIXED | `a9635ef` | `4a34d93` |
| H-08 | FIXED | `6ea0bc3` | `88ed22c` |
| H-09 | FIXED | `e0db30f` | `b07b209` |
| H-10 | FIXED | `8633fe4` | `793aebc` |
| H-11 | FIXED | `c204be3` | `a74e58d` |
| **H-12** | **NEW — FIXED** | `f50d7e0` | `0d147d5` |

H-12 was NOT in the original eleven. It was found by the cross-package
gauntlet (G10) that this mission required.

---

## D. ROOT-CAUSE ANALYSIS

Every finding had a **specific, mechanical** cause:

- **H-01** — the save counter was incremented BEFORE the temp write,
  while its own comment claimed it moved "only where the checkpoint
  actually lands". The code contradicted its comment.
- **H-02** — the merchant discount became run-scoped when the v5
  checkpoint began persisting it, but the reset was not updated to
  match. `reset_offer()` cleared only the offer list.
- **H-03** — the save points around the map flow were added ad hoc: one
  before the transition, one inside the service handler, one after it.
- **H-04** — the core was already fixed by the published integration; the
  PRESENTATION boundary was not: the battle view was refreshed only when
  the controller's context was NOT null.
- **H-05** — the latch conflated "the outcome was applied" with "the
  outcome was persisted", and the normal tick could not retry it.
- **H-06** — the merchant flow predated the checkpoint contract.
- **H-07** — the run termination was derived from the map's TOPOLOGY
  (an empty successor list) instead of from a confirmed BOSS outcome.
- **H-08** — the checkpoint commit and the meta pointer are two separate
  writes, but the result reported only the first.
- **H-09** — the equipment commands were hardened for the phase guards
  but never given a persistence contract; and the index pair called the
  state method directly, bypassing the by-id path.
- **H-10** — the ledger is a documentation artifact with no structural
  guard, so no test could see it destroyed.
- **H-11** — the builder trusted the owner projection and never consulted
  the strict live gate the inventory package had introduced.
- **H-12** — the latch was the one-shot of the WRITE, not of the
  OUTCOME; the terminal paths have no write, so they never consumed it.

---

## E. TEST-BEFORE-FIX EVIDENCE

Every package followed RED -> GREEN. The RED was always a semantic
`[FAIL]` with zero parse errors and zero script errors; where an absent
API produced a script error instead, the suite was changed to assert the
API's PRESENCE first, so the RED stayed trustworthy.

The measured REDs are quoted in the commit messages of the RED commits.

---

## F. PRODUCTION CHANGES

| File | Change |
|---|---|
| `core/progression/run_controller.gd` | the save report, the meta retry, the discovery, the outcome pending state and its retry, the equipment persistence, the phase policy, the terminal latch, the map checkpoint order, the merchant persistence and the exit guard, the discount reset |
| `core/progression/run_save_report.gd` | NEW: the structured result of a checkpoint attempt |
| `core/save/run_save_repository.gd` | the save counter moves after the commit; the discovery seam |
| `core/progression/shop_screen.gd` | the discount reset |
| `core/battle_ecs/battle_setup_builder.gd` | the inventory trust boundary |
| `scenes/battle/battle_scene.gd` | the stale visual context |

**NOT touched:** shipping content, `.tres` resources, the balance, the
gameplay RNG algorithm and its sequence, the Battle ECS combat
semantics, the Clock Policy, the v4/v5 checkpoint structures, the
public signatures of the existing commands.

---

## G. SAVE TRANSACTION CONTRACT

```
save result SUCCESS            -> save_count delta = +1
save result ERROR              -> save_count delta = 0
```

The counter moves after `_commit_verified_temp()` -- the whole
transaction: the swap, the post-commit validation and the cleanup of
the previous generation. A single successful `rename()` is not a
committed checkpoint. Covered for v4 AND v5, and across the fault
matrix: the temp write, the temp verification, the rename, the cleanup
and the post-commit read. A failed save leaves the previous generation
intact and the slot loadable.

---

## H. OUTCOME RETRY STATE MACHINE

```
OUTCOME_NOT_APPLIED              the latch is false
OUTCOME_APPLIED_PENDING_PERSIST  the outcome is applied, the write failed
OUTCOME_PERSISTED                the outcome is applied AND written
```

The retry writes the CURRENT live state, which already holds the
applied outcome, so it cannot re-apply anything: no second win counter,
no second gold, no second round advance, no second loot, no second
reward offer, no extra gameplay RNG draw and no repeated gameplay
event.

The retry is REACHABLE: `tick_battle` performs it, so the pending
outcome is recovered by the ordinary game loop. It is RATE LIMITED to
one attempt per second, so a persistent filesystem failure does not
become a write on every frame.

---

## I. META PARTIAL-SUCCESS RECOVERY

```
checkpoint success + meta success -> complete success
checkpoint success + meta failure -> a PARTIAL success:
                                     the checkpoint stays VALID,
                                     the status reports the partial
                                     failure,
                                     no false run_saved success,
                                     only the META is retried
checkpoint failure               -> no claim of a persisted checkpoint
```

The outcome latch is bound to the CHECKPOINT commit, NOT to the
complete success. Binding it to the complete success would make the
outcome reapplicable when the meta pointer failed -- and a second
application repeats the win counter, the gold, the round, the loot and
the reward offer.

`retry_meta_publication()` writes ONLY the meta. The discovery path
(`recoverable_checkpoints()`) goes through the SAME seam as the save and
the load, and the controller does NOT choose one of several candidates
silently.

---

## J. MAP / CHECKPOINT CONSISTENCY

```
choose valid COMBAT
  -> update the map state
  -> transition to PREP
  -> persist the PREP checkpoint
```

```
valid node selection
  -> apply the service effect exactly once
  -> determine the final stable phase
  -> persist the authoritative checkpoint
```

The save moved AFTER the transition. The service path persists ONE
checkpoint. The RNG draw sequence of a successful pass is unchanged:
the saves do not draw.

A service dead end is a CONTROLLED FAILURE, not a victory:
`available_next_ids.is_empty()` does NOT imply "the boss was defeated",
so `EncounterMap.is_valid()` decides. A corrupted map produces an
explicit error, no victory, no meta unlock and no checkpoint deletion.

---

## K. MERCHANT / EQUIPMENT DURABILITY

The purchase and the exit are persisted after a REAL mutation, and the
exit requires a REAL merchant context -- the phase alone is not enough.

The equipment is persisted after a REAL mutation, in the phases where
the checkpoint is stable (PREP, MAP, REWARD, SERVICE). A NO-OP is NOT
persisted: the ownership BEFORE and AFTER the call decides, because
`equip_item()` returns true for an already equipped item WITHOUT
changing anything.

**During BATTLE nothing is written.** The v5 format does not persist the
battle simulation runtime, and `wire_phase_for()` maps the BATTLE phase
to PREP -- so a write there would produce a checkpoint with a FALSE
phase and a stale battle state. The allowed command still changes the
live inventory (the gameplay semantics are NOT changed); the battle
keeps its own snapshot and the new equipment reaches the NEXT correct
checkpoint.

---

## L. NEW-RUN / RESUME ISOLATION

A new run starts from a clean runtime: the map, the reward offer, the
merchant offer, the merchant DISCOUNT, the runner, the context, the
participants and the outcome latch.

A successful resume clears the same runtime BEFORE it installs the
restored state, and the PRESENTATION boundary was fixed too: the battle
view no longer keeps the stale visual context of the previous battle.

A FAILED resume is transactional: the previous runtime is left exactly
as it was.

---

## M. ECS INVENTORY BOUNDARY

`BattleSetupBuilder.build()` refuses to build from an inconsistent
inventory. The check is the FIRST statement, so the rejected build
consumes no RNG, allocates nothing and mutates nothing.

`BattleSetup.validate()` keeps its own job -- it validates the
STRUCTURE of the finished snapshot. The new check validates the DOMAIN
the snapshot is built from.

The previous characterization test asserted the defect as an acceptable
"known boundary" and was REPLACED. All the callsites of `build()` are
tests; the production path is the legacy `start_battle`, so no
production caller changes.

---

## N. v4 / v5 COMPATIBILITY

The v4 path goes through the same `_save_canonical()`, so the H-01 fix
covers both. The v5 checkpoint STRUCTURE was not touched: the mapper,
the schema and the migrator are unchanged. The v4/v5 compatibility
suites are part of the runner and are green.

---

## O. RNG AND DETERMINISM

No new gameplay RNG draw site was introduced. The new code paths
(equipment persistence, the merchant persistence, the outcome retry,
the meta retry) do not draw. The outcome retry writes the state that
already exists; it does not regenerate the reward offer, and the suite
asserts the stream position is unchanged across the retry.

The merchant discount reset does not touch the offer generation.

---

## P. NEGATIVE CONTROLS

The existing NC-01..NC-43 are preserved. The new controls are listed in
`docs/ri_postclosure/HARDENING_LEDGER.md`. Every control mutates ONE
production decision, runs the suite that must catch it, and restores the
original file.

### The controls that found their own gaps

Two of the new controls were MISSED at first, and both misses were real
coverage gaps rather than broken mutations:

- **NC-H09C** (the battle phase guard removed) was MISSED because the
  battle equip case was a NO-OP, and the no-op guard returns BEFORE the
  phase guard -- so the case never reached the contract it claimed to
  cover. The case now makes a REAL mutation.
- **NC-H11B** (the duplicate ownership accepted silently) was SKIPPED
  for a long time because its anchor had drifted, and a SKIP is not
  evidence. Re-aimed, it turned out to be MISSED: TWO units listing
  the same item is ALSO caught by the mirrored ownership check, so
  only the shape where the SAME unit lists the SAME item TWICE is
  caught by the duplicate ownership check alone. The suite gained both
  cases.

A control that cannot fail is not a control. Both of these were found
by RUNNING the controls, not by reading them.

A trustworthy RED is: `rc != 0` AND at least one `[FAIL]` AND 0 parse
errors AND 0 SCRIPT ERROR lines. A mutation that breaks the parsing is
INVALID, not a catch; a missing anchor is a SKIP, and a SKIP is never
evidence. One control (NC-H09A) was INVALID on the first attempt
because the mutation itself broke the parsing -- it was rewritten, and
the rewritten control is RED.

---

## Q. FULL REGRESSION

Measured on the final hardening HEAD:

```
runner       118 suites / 9092 assertions / 0 fail / 0 unparsed   GREEN
CI gates     10/10 clean
lint         0 errors / 5 warnings (baseline)
parse        0 errors
ledger       VALID + 7/7 validator controls RED
NC-H01..NC-H12  14/14 honest RED, 0 SKIP, 0 INVALID
A-H          PASS (8 baseline fixtures rc=0, 8 candidate fixtures rc=0)
```

The pre-existing RI-01..RI-12 and Inventory Integrity suites are
unchanged: 30 of the 31 files are byte-identical to the base, and the
only changed one -- `battle_inventory_boundary_test.gd` -- was
STRENGTHENED (the old version asserted the defect as an acceptable
"known boundary").

**Shipping content, the balance, the gameplay RNG, the Battle ECS
combat semantics, the Clock Policy and the v4/v5 checkpoint structures
are UNCHANGED.** The `Rng.*` call sites in `core/` are 41 at the base
and 41 at HEAD: no new gameplay draw site was introduced.

---

## R. THE INDEPENDENT CRITIC

An independent critic reviewed the whole branch READ-ONLY and returned
**HOLD**: three HIGH, two MAJOR and two MINOR findings. Every one of
them was a real defect or a real contract problem, and every one is
closed.

| ID | Severity | Problem | Fix |
|---|---|---|---|
| R-01 | HIGH | the outcome retry was UNREACHABLE in production: `tick_battle` has exactly one caller and it is guarded by `phase == BATTLE`, so after the outcome the tick stopped and the pending outcome was never retried. The regression called `tick_battle` directly, so it exercised a path the game never takes. | `0cd33fc` — the retry moved to the controller's own `_process`, which runs in EVERY phase. The regression now drives the real per-frame hook and asserts the rate limit. |
| R-02 | HIGH | `build()` returned `null` while the declared return type is non-nullable, and 23 existing callsites dereference the result unguarded -- the failure mode was a SCRIPT ERROR, not a clean refusal. | `014138a` — the refusal is an OBJECT: `BattleSetup.refused()` carries `build_error`, `validate()` reports it, and the refused setup has no units, so no item bonus is applied and no battle can start. The 23 callsites stay untouched. |
| R-03 | HIGH | the ledger validator's negative controls were not run by ANY CI step -- a validator that accepted everything would keep CI green forever, which is exactly the H-10 failure mode. | `1fcbe11` — the controls run in CI, on temporary copies. |
| R-04 | MAJOR | `recoverable_checkpoints()` was dead code: the Continue button was gated on the meta pointer alone, so a stale pointer hid a committed run from the player -- the run file was on the disk and the game said there was nothing to continue. | `f39a742` — the menu resolves the target: the fresh pointer wins, a stale pointer with exactly ONE candidate offers that candidate, and a stale pointer with SEVERAL candidates asks instead of guessing. |
| R-05 | MAJOR | the H-07 guard uses a whole-graph validator, so a legitimate map with a childless node could turn a victory into a soft lock. | `6db36ab` — DISPROVEN: 200 generated maps across 200 seeds, and every one is valid. The suite also proves the guard is reachable. |
| R-06 | MINOR | the public boolean semantics of `save_now()` changed silently: a partial success reported false, so a caller could discard a valid checkpoint. | `9f355d0` — the boolean keeps its historical meaning (true when the checkpoint landed); the structured result distinguishes the complete and the partial success. |
| R-07 | MINOR | two parsers for one filename format, with different directory sources and divergent sorting. | `2cc2576` — one parser, in the repository (which owns the format); the service delegates to it. The dependency points one way. |

The critic verified eighteen hunt items against the code, not asserted
them. The notable confirmations: **no extra gameplay RNG draws**, the
pre-existing RI and Inventory tests were **not weakened**, the v4/v5
migration path is intact, the Inventory identity gates are untouched,
the outcome latch is bound to the checkpoint commit rather than to the
complete success, and a finished run is never resumable.

### What the HOLD taught the process

R-01 is the finding that matters most for the method: the H-05 fix
looked complete because its regression was green -- but the regression
called `tick_battle` DIRECTLY, bypassing the production
`phase == BATTLE` guard. A test that exercises a path the game never
takes proves the method works, not that the game reaches it.

The same class of gap was later found in the H-09 battle case: an
equip that was a NO-OP never reached the phase guard, so the negative
control against that guard was MISSED. Both are closed now, and the
negative control that detects them is executable.

## S. THE CROSS-PACKAGE GAUNTLET

The ten cross-package scenarios (G1..G10) live in
`tests/run_integrity/cross_package_gauntlet_test.gd`, 56 assertions.
They cross the package boundaries: the map, the service, the battle
outcome, the meta pointer, the merchant, the equipment, the new-run
isolation, the boss dead end and the terminal failure.

Every scenario drives the PRODUCTION path and compares the live state,
the persisted checkpoint, the MetaProfile and the restored state.
Comparing two DTOs that are BOTH wrong proves nothing, so each
scenario pins the ABSOLUTE expected outcome as well.

**The gauntlet found H-12**: the terminal outcome was not idempotent.
The idempotence latch was consumed by `_write_outcome()`, and the
terminal branches never write a checkpoint -- so a repeated completion
callback applied the terminal outcome AGAIN: a second `total_runs`, a
second `total_wins`, a second meta unlock.

## T. THE CI LEDGER VALIDATION

`tools/validate_run_integrity_ledger.py` checks that the ledger
exists, is not empty, is valid UTF-8, is valid JSON, has an object
root, has a `findings` array and an `integration` object with the
expected types and the minimal mandatory fields.

It deliberately does NOT require a fixed file size, a fixed findings
count, a fixed commits count or `final_sha == HEAD`: the ledger must
be allowed to grow.

The negative controls run on TEMPORARY COPIES -- the production ledger
is never touched:

```
the valid ledger            PASS
a zero-byte ledger          RED
a malformed JSON ledger     RED
a removed `findings`        RED
a removed `integration`     RED
a wrong `findings` type     RED
a wrong `integration` type  RED
a wrong root type           RED
```

Both the validator and its controls run in CI
(`chore(ci): validate the Run Integrity ledger` and
`chore(ci): run the ledger validator controls in CI`).

The negative controls of the hardening are reproducible from
`tools/negative_controls.py`: every control mutates ONE production
decision, runs the suite that must catch it, and restores the original
file. The current matrix is 14/14 honest RED.

## U. ACTUAL COMMIT GRAPH

38 commits over the base `15628b8`, every package a separate logical
commit, every RED separated from its FIX:

```
test/fix pairs:
  5048c9d / 5695085 / 1084de2   H-01  the save counter
  8a17df2 / 8f4e680             H-02  the merchant discount
  3c85fef / bc3365e             H-03  the map checkpoint
  8a73743 / 022ec47             H-05  the outcome retry
  858cf70 / 4ee9feb             H-06  the merchant durability
  a9635ef / 4a34d93             H-07  the boss dead end
  6ea0bc3 / 88ed22c             H-08  the meta partial success
  e0db30f / b07b209             H-09  the equipment durability
  8633fe4 / 793aebc             H-10  the ledger validator
  c204be3 / a74e58d             H-11  the ECS inventory boundary
  443c49b / 5d380c0             H-04  the resume isolation
  f50d7e0 / 0d147d5             H-12  the terminal idempotence
  d2eebb2 / f39a742             R-04  the stale pointer Continue
the critic fixes:
  0cd33fc                      R-01  the retry reachability
  014138a                      R-02  the refusal as an object
  1fcbe11                      R-03  the controls in CI
  6db36ab                      R-05  the map validity guard
  9f355d0                      R-06  the save boolean
  2cc2576                      R-07  one format parser
the coverage fixes:
  d701405                      the H-09 battle case as a real mutation
```

## V. REMAINING LIMITATIONS

1. **Crash safety across a process termination is NOT claimed.** The
   outcome retry recovers a transient filesystem error within the
   process. It does not make the exactly-once contract survive a kill
   in the middle of the write.
2. **During a battle the equipment cannot be crash-recovered.** The v5
   format does not persist the battle runtime, so the equipment change
   reaches the next correct checkpoint. This is a format limitation,
   documented rather than hidden.
3. **The meta pointer failure leaves the run discoverable but not
   pointed at.** The discovery path lists the candidates and the
   controller does NOT pick one silently; a UI that wants to offer
   "Continue" must resolve the choice explicitly.
4. **The map validation was NOT extended.** The corrupted map is
   detected at the point of use (the service dead end), not at restore.
   A stronger restore-time validation would touch the v5 restore path
   and was out of scope for a hardening pass.

---

## W. FINAL VERDICT

```
RUN INTEGRITY POST-CLOSURE HARDENING
= READY
```

The evidence for the verdict:

- all 11 mission findings are disposed: 10 fixed, 1 (H-04) confirmed
  already fixed in the baseline for the core and fixed here for the
  presentation boundary;
- one NEW finding (H-12) was discovered by the work itself and fixed;
- all 7 findings of the independent critic are closed, including the
  three HIGH ones that the critic proved against the production call
  graph;
- 14/14 new negative controls are honest RED (no SKIP, no INVALID),
  and the 7 ledger-validator controls are 7/7 RED;
- the full standalone regression is GREEN: 118 suites / 9092
  assertions / 0 fail / 0 unparsed, the CI gates are 10/10 clean, and
  the A-H semantic differential is PASS with all 16 fixtures executed
  on both sides;
- the shipping content, the balance, the gameplay RNG, the Battle ECS
  combat semantics, the Clock Policy and the v4/v5 checkpoint
  structures are UNCHANGED;
- the git tree is clean and **nothing was pushed**.

### Actual deliverables

```
actual HEAD             (see the branch tip)
branch                  fix/run-integrity-postclosure-hardening
base commit             15628b885f10b8f5ade0a3e8296878ee7c45d8a9
commits over the base   38
git status              clean
changed production files 9 (+649 / -37)
changed test files      14 (+3659 / -18)
suites                  118
assertions              9092 pass / 0 fail
failures                0
unparsed                0
A-H result              PASS (8 + 8 fixtures, both sides rc=0)
negative controls       14 new (14/14 RED) + 7 ledger controls (7/7 RED)
Godot parse             0 errors / 0 script errors
CI result               not run: the branch is local and NOTHING WAS PUSHED
```

### The remaining accepted risks

1. **Crash safety across a process termination is NOT claimed.** The
   outcome retry recovers a transient filesystem error WITHIN the
   process. It does not make the exactly-once contract survive a kill
   in the middle of the write.
2. **During a battle the equipment cannot be crash-recovered.** The v5
   format does not persist the battle runtime, so the equipment
   change reaches the next correct checkpoint. A documented format
   limitation, not a hidden one.
3. **A stale meta pointer with SEVERAL checkpoints asks the player.**
   The ambiguity is never resolved silently -- an arbitrary choice
   could restore the wrong run.
4. **The map validation was not extended.** The corrupted map is
   detected at the point of use, not at restore. A stronger
   restore-time validation would touch the v5 restore path and was out
   of scope for a hardening pass.
5. **The CI workflow was not executed on a remote runner**, because
   the branch was not pushed -- the mission forbids the push. The
   workflow steps were verified locally with the same commands and the
   same exit codes.
