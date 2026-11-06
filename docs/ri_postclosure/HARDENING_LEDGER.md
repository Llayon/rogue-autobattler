# RUN INTEGRITY POST-CLOSURE HARDENING — LEDGER

**Branch:** `fix/run-integrity-postclosure-hardening`
**Baseline:** `8642de541da88c7d76fe7f083997360a143c355f` (published integration)
**Base commit:** `15628b885f10b8f5ade0a3e8296878ee7c45d8a9` (the publication-ledger commit, a verified descendant of the published SHA)
**Worktree:** `%LOCALAPPDATA%\Temp\ri-hardening`
**Published integration CI:** https://github.com/Llayon/rogue-autobattler/actions/runs/42258689657

The base is the published integration plus the unpublished publication-ledger
commit `15628b8`. That commit only records the facts of the publication in
`.hermes/plans/run_integrity_ledger.json`; it touches no production code. It is
kept, not cherry-picked, because it IS the base of this branch.

The RI-01..RI-12 findings are FROZEN. They are not rewritten here. The eleven
new findings below are tracked separately.

---

## FINDINGS

### H-01 — Save Repository: `_save_count` counts attempts, not commits
**[FIXED]** — `5048c9d` (RED) → `5695085` (FIX) → `1084de2` (v4 coverage)

- **Area:** `core/save/run_save_repository.gd`
- **Baseline behavior:** `_save_count += 1` at line 194, BEFORE
  `write_bytes_and_flush`, `_verify_temp` and `_commit_verified_temp`. A failed
  save therefore increments the counter of successful saves.
- **Root cause:** the counter was moved to satisfy the "a REJECTED write is not
  counted" contract, but it was placed before the temp write instead of after
  the commit. The doc comment at line 1135 claims "the counter moves only where
  the checkpoint actually lands" — the code contradicts its own comment.
- **Severity:** MEDIUM. The counter is the observable that the RI-09 and RI-10
  suites use for "no checkpoint was written". A failed save inflates it, so a
  test that relies on it can read a failed write as a write.
- **Production impact:** no gameplay impact; a weakened test observable.
- **Test gap:** the fault-injection matrix does not assert the counter delta
  across the failure points.
- **Status:** CONFIRMED IN BASELINE — to fix.

### H-02 — Merchant: the discount leaks between independent runs
**[FIXED]** — `8a17df2` (RED) → `8f4e680` (FIX)

- **Area:** `core/progression/shop_screen.gd`, `core/progression/run_controller.gd`
- **Baseline behavior:** `reset_offer()` (line 23) clears ONLY
  `_offered_item_ids`. The comment says "the discount is the balance constant,
  so it stays" — but the discount is RESTORED from the checkpoint
  (`restore_snapshot` line 83 sets `_discount = discount`), so it is NOT always
  the balance constant.
- **Root cause:** the discount became run-scoped when the v5 checkpoint began
  persisting it, but the reset was not updated to match.
- **Severity:** MEDIUM. A resumed run with a non-default discount followed by
  an independent new run leaves the old discount in the new run's merchant.
- **Production impact:** the new run's merchant prices are wrong.
- **Test gap:** no test covers "resume with discount X, then start a new run".
- **Status:** CONFIRMED IN BASELINE — to fix.

### H-03 — Map checkpoint: COMBAT persists as MAP; the service path saves twice
**[FIXED]** — `3c85fef` (RED) → `bc3365e` (FIX)

- **Area:** `core/progression/run_controller.gd`
- **Baseline behavior:**
  - COMBAT: `_on_node_selected` calls `save_now()` at line 1377 while the phase
    is still MAP, and only then transitions to PREP at line 1379. The
    checkpoint therefore records a MAP phase with the combat node already
    selected.
  - SERVICE: the same function saves at 1377 (before the effect), the service
    handler saves at 1411 (inside the effect), and `_on_node_selected` saves
    again at 1383 (after the effect). Three writes describe one transaction.
- **Root cause:** the save points were added ad hoc around the map flow.
- **Severity:** HIGH for COMBAT. After Continue, the run is in the MAP phase
  with the combat already selected — the player can select the NEXT node and
  skip the battle.
- **Production impact:** a battle can be skipped through Continue.
- **Test gap:** no test drives `_on_node_selected()` for a COMBAT node and then
  resumes.
- **Status:** CONFIRMED IN BASELINE — to fix.

### H-04 — Runtime isolation: a stale battle runtime across `resume_run`

- **Area:** `core/progression/run_controller.gd`, `scenes/battle/battle_scene.gd`
- **Baseline behavior:** the CORE was already fixed by the published
  integration: `resume_run` calls `_reset_transient_runtime()` before it
  installs the restored state, so the runner, the participants, the context
  and the outcome latch do not survive the resume.
- **Root cause:** N/A for the core. The PRESENTATION boundary was not
  covered: `battle_scene.gd` refreshed the battle view only when the
  controller's context was NOT null, so a NULL context -- the state after a
  successful resume -- did NOT clear the stale visual context of the
  previous battle.
- **Severity:** MEDIUM for the presentation leak: the view kept drawing
  the combatants of a battle that no longer existed.
- **Status:** **ALREADY FIXED IN BASELINE** for the core, **FIXED HERE** for
  the presentation boundary — `443c49b` (RED) → `5d380c0` (FIX).
  The suite `tests/run_integrity/resume_isolation_test.gd` confirms the
  core clear, the FAILED-resume transactionality, the exact RNG parity
  and the visual context.

### H-05 — Outcome transaction: a failed outcome write has no safe retry
**[FIXED]** — `8a73743` (RED) → `022ec47` (FIX). The third state
`OUTCOME_APPLIED_PENDING_PERSIST` was introduced. The retry writes the
CURRENT live state, so it cannot re-apply anything. It is reachable
from `tick_battle` and rate limited to one attempt per second.

- **Area:** `core/progression/run_controller.gd`
- **Baseline behavior:** `_write_outcome()` (line 1017) calls `save_now()` and
  consumes the `_battle_outcome_applied` latch ONLY when the write succeeded.
  A failed write leaves the outcome applied in memory with the latch false.
  The normal tick cannot retry it (the runner is no longer ENDED), and a direct
  `_on_battle_ended()` call would re-apply the outcome.
- **Root cause:** the latch conflates "the outcome was applied" with "the
  outcome was persisted".
- **Severity:** HIGH. The outcome is applied exactly once in memory but has no
  reachable persistence retry, and the only manual retry path re-applies the
  gameplay mutation.
- **Production impact:** a transient filesystem error loses the battle result
  permanently, or a manual retry double-applies it.
- **Test gap:** no test drives a failed outcome write and then a retry.
- **Status:** CONFIRMED IN BASELINE — to fix.

### H-06 — Merchant persistence: the purchase and the exit are not saved
**[FIXED]** — `858cf70` (RED) → `4ee9feb` (FIX). The purchase and the exit
are persisted after the mutation, and the exit now requires a REAL
merchant context (`just_visited_merchant`), not merely the PREP phase.

- **Area:** `core/progression/run_controller.gd`
- **Baseline behavior:**
  - `buy_item` (line 510) grants the item and spends the gold, and never
    calls `save_now()`.
  - `exit_shop_to_map` (line 535) clears `just_visited_merchant` and sets the
    phase to MAP, and never calls `save_now()`.
  - `exit_shop_to_map` accepts ANY PREP phase as a merchant context — it does
    not require a merchant visit.
- **Root cause:** the merchant flow predates the checkpoint contract.
- **Severity:** HIGH. A purchase or an exit is lost on Continue.
- **Test gap:** no test buys in the merchant and then resumes.
- **Status:** CONFIRMED IN BASELINE — to fix.

### H-07 — Boss termination: a service dead end gives a false victory
**[FIXED]** — `a9635ef` (RED) → `4a34d93` (FIX). The measured RED:
`the phase is 3`, `run_ended [true]`, the total runs and wins changed,
and a meta unit was unlocked. The fix uses `EncounterMap.is_valid()`,
so a corrupted map becomes a CONTROLLED FAILURE.

- **Area:** `core/progression/run_controller.gd`,
  `tests/run_integrity/boss_reachability_test.gd`
- **Baseline behavior:** `_apply_service_effect` (lines 1417-1422) ends the run
  with `_end_run(true)` when `encounter_map.get_available_next_ids()` is empty.
  An empty list of next moves does NOT mean the boss was defeated: a malformed
  graph with no path to the boss reaches the same branch.
- **Root cause:** the run termination was derived from the map's topology
  instead of from a confirmed BOSS outcome. The RI-08 fix made the boss the
  terminator for the BATTLE path, but the SERVICE path still ends the run on
  an empty successor list.
- **Severity:** HIGH. A malformed map yields a false victory: `run_ended(true)`,
  a meta unlock, and the checkpoint is deleted.
- **Test gap:** `boss_reachability_test.gd` case D disconnects the boss and
  sets the current encounter id to BOSS directly — it does NOT drive the real
  `_on_node_selected()` with a malformed graph, so it does not cover this.
- **Status:** CONFIRMED IN BASELINE — to fix.

### H-08 — Meta persistence: a `_save_meta()` failure is ignored
**[FIXED]** — `6ea0bc3` (RED) → `88ed22c` (FIX). The checkpoint commit and
the meta pointer commit are reported separately. The outcome latch is
bound to the CHECKPOINT, not to the complete success, so a meta failure
can never make the outcome reapplicable.

- **Area:** `core/progression/run_controller.gd`
- **Baseline behavior:** `save_now()` (lines 976-981) sets
  `profile.current_run_seed = state.seed`, calls `_save_meta(profile)` and
  IGNORES its boolean result, then emits `run_saved` and returns true.
- **Root cause:** the checkpoint commit and the meta pointer are two separate
  writes, but the result reports only the first.
- **Severity:** HIGH. The checkpoint is on the disk, so the run IS persisted,
  but the meta pointer that makes Continue discoverable was not written — and
  the caller is told the save succeeded.
- **Test gap:** no test injects a meta write failure.
- **Status:** CONFIRMED IN BASELINE — to fix.

### H-09 — Equipment persistence: equip/unequip are not saved
**[FIXED]** — `e0db30f` (RED) → `b07b209` (FIX). A REAL mutation is
persisted in the stable phases; a NO-OP is not (the ownership before
and after the call decides); the BATTLE phase writes NOTHING, because
the v5 format does not persist the battle runtime and `wire_phase_for()`
maps BATTLE to PREP. The index pair now routes through the by-id path.

- **Area:** `core/progression/run_controller.gd`
- **Baseline behavior:** `equip_item_by_id` (line 328), `unequip_item_by_id`
  (line 342), `equip_item_at` (line 428) and `unequip_item_at` (line 442) all
  mutate the live state and never call `save_now()`.
- **Root cause:** the equipment commands were hardened for the RI-09 phase
  guards but never given a persistence contract.
- **Severity:** HIGH. Equipment is lost on Continue.
- **Test gap:** no test equips and then resumes.
- **Note:** `RunDomainState.equip_item()` returns true for an ALREADY equipped
  item without changing anything, so a naive save-after-return would write a
  redundant checkpoint on every no-op. The fix must distinguish a real
  mutation from an idempotent repeat.
- **Status:** CONFIRMED IN BASELINE — to fix.

### H-10 — Ledger integrity: CI does not detect a destroyed ledger
**[FIXED]** — `8633fe4` (the validator and the negative controls) →
`793aebc` (the CI step). The validator checks the structure and the
minimal mandatory fields, and deliberately does NOT require a fixed
size, a fixed findings count or `final_sha == HEAD`. The controls run
on temporary copies: 7/7 RED.

- **Area:** `.github/workflows/test.yml`, `.hermes/plans/run_integrity_ledger.json`
- **Baseline behavior:** the workflow has no step that validates the ledger.
  The ledger was emptied once during this effort by a truncation bug in the
  implementer's own normalization step, and EVERY gate stayed green:
  `git status` was clean, `diff --check` was clean and the runner was GREEN,
  because the ledger is not part of any test.
- **Root cause:** the ledger is a documentation artifact with no structural
  guard.
- **Severity:** MEDIUM. The ledger is the evidence of the whole series; it can
  be destroyed silently.
- **Test gap:** no validator exists.
- **Status:** CONFIRMED IN BASELINE — to fix.

### H-11 — ECS boundary: `BattleSetupBuilder` accepts an inconsistent inventory
**[FIXED]** — `c204be3` (RED) → `a74e58d` (FIX). The previous
characterization test asserted the defect as an acceptable "known
boundary" and was REPLACED. The builder now refuses an invalid
inventory, and the check is the FIRST statement: no RNG, no
allocation, no mutation.

- **Area:** `core/battle_ecs/battle_setup_builder.gd`,
  `tests/inventory_integrity/battle_inventory_boundary_test.gd`
- **Baseline behavior:** `build()` reads
  `p_state.get_equipped_items(String(u.instance_id))` (line 72) and never
  checks `p_state.is_inventory_valid()`. The existing characterization test
  ASSERTS the defect at line 29: "known boundary: setup validation does not
  validate dangling inventory references".
- **Root cause:** the builder trusts the owner projection.
- **Severity:** MEDIUM. A future ECS BattleBackend could start a battle from
  an inconsistent inventory and apply an item bonus twice or to the wrong
  unit. The current production path uses the legacy `start_battle`, so there
  is no live gameplay impact today.
- **Test gap:** the existing test encodes the defect as the expectation.
- **Status:** CONFIRMED IN BASELINE — to fix. All the callsites of `build()`
  are tests; the production path is the legacy `start_battle`, so the public
  signature can be made fail-closed without breaking a production caller.

### H-12 — Terminal outcome: a repeated completion callback duplicates the rewards

- **Area:** `core/progression/run_controller.gd`
- **DISCOVERED BY:** the cross-package gauntlet (G10), not by the original
  eleven findings.
- **Baseline behavior:** the idempotence latch is consumed by
  `_write_outcome()`. The TERMINAL branches never write a checkpoint -- a
  finished run must not be resumable -- so they never consumed the latch
  either. A repeated completion callback therefore applied the terminal
  outcome AGAIN: a second `total_runs`, a second `total_wins`, a second
  meta unlock and a second set of terminal rewards.
- **Root cause:** the latch was the one-shot of the WRITE, not of the
  OUTCOME. The terminal paths have no write.
- **Severity:** HIGH. A duplicate meta unlock and a duplicate win count are
  permanent progression errors in the player's profile.
- **Status:** **FIXED** — `f50d7e0` (the gauntlet, RED) → `0d147d5` (FIX).
  The latch is now consumed by the terminal branches as well, BEFORE the
  terminal cleanup, so a failure in the cleanup does not make the outcome
  reapplicable.

---

## NEGATIVE CONTROL MATRIX

The existing NC-01..NC-43 are preserved. The new controls are added per
finding as the packages land.

| Control | Mutation | Finding | Expectation |
|---|---|---|---|
| NC-H01 | move the counter back before the temp write | H-01 | semantic RED |
| NC-H03 | restore the save-before-PREP | H-03 | semantic RED |
| NC-H07A | restore the service dead-end = victory | H-07 | semantic RED |
| NC-H07B | restore the save-after-GAMEOVER | H-07 | semantic RED |
| NC-H05A | remove the retry | H-05 | semantic RED |
| NC-H05B | re-apply the outcome | H-05 | semantic RED |
| NC-H08A | ignore the meta failure | H-08 | semantic RED |
| NC-H08B | replay the outcome on the meta retry | H-08 | semantic RED |
| NC-H06A | remove the purchase save | H-06 | semantic RED |
| NC-H06B | remove the exit save | H-06 | semantic RED |
| NC-H06C | remove the exit guard | H-06 | semantic RED |
| NC-H09A | remove the equip save | H-09 | semantic RED |
| NC-H09B | remove the unequip save | H-09 | semantic RED |
| NC-H09C | force a fake PREP save during a battle | H-09 | semantic RED |
| NC-H09D | save on a no-op | H-09 | semantic RED |
| NC-H02 | let the old discount survive `start_run` | H-02 | semantic RED |
| NC-H04 | let the stale battle runtime survive the resume | H-04 | semantic RED |
| NC-H10A | a zero-byte ledger | H-10 | semantic RED |
| NC-H10B | a malformed JSON ledger | H-10 | semantic RED |
| NC-H10C | a removed mandatory section | H-10 | semantic RED |
| NC-H11A | remove the inventory validation | H-11 | semantic RED |
| NC-H11B | accept a duplicate ownership silently | H-11 | semantic RED |
| NC-H12 | the terminal outcome does not consume the latch | H-12 | semantic RED |
| NC-H03 | restore the save-before-PREP | H-03 | semantic RED |
| NC-H05A | remove the outcome retry | H-05 | semantic RED |
| NC-H05B | re-apply the outcome on a retry | H-05 | semantic RED |
| NC-H06A | remove the purchase save | H-06 | semantic RED |
| NC-H06C | remove the merchant exit guard | H-06 | semantic RED |
| NC-H07A | restore the service dead-end = victory | H-07 | semantic RED |
| NC-H09A | remove the equip no-op guard | H-09 | semantic RED |
| NC-H10A | a zero-byte ledger | H-10 | semantic RED |
| NC-H10B | a malformed JSON ledger | H-10 | semantic RED |
| NC-H10C | a removed mandatory section | H-10 | semantic RED |

---

## STATUS

| ID | Disposition | Commits |
|---|---|---|
| H-01 | FIXED | `5048c9d` `5695085` `1084de2` |
| H-02 | FIXED | `8a17df2` `8f4e680` |
| H-03 | FIXED | `3c85fef` `bc3365e` |
| H-04 | ALREADY FIXED (core) + FIXED (presentation) | `443c49b` `5d380c0` |
| H-05 | FIXED | `8a73743` `022ec47` |
| H-06 | FIXED | `858cf70` `4ee9feb` |
| H-07 | FIXED | `a9635ef` `4a34d93` |
| H-08 | FIXED | `6ea0bc3` `88ed22c` |
| H-09 | FIXED | `e0db30f` `b07b209` |
| H-10 | FIXED | `8633fe4` `793aebc` |
| H-11 | FIXED | `c204be3` `a74e58d` |

**Progress: 11 of 11 fixed, plus one NEW finding (H-12) that the
cross-package gauntlet discovered.**

**Runner after the fixed packages:** 115 suites / 8992 assertions /
0 fail / 0 unparsed, CI gates 10/10 clean.
