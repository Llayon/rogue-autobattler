# PHASE 3 -> MASTER INTEGRATION & RELEASE SAFETY — REPORT

    The gauntlet: R0-R9, CI INTEGRITY + INTEGRATION REHEARSAL.
    The mode: NO PUSH, NO MERGE, NO DEPLOY.
    The verdict: see section Q.

## A. BASELINE

```
master (canonical)        02fe83ef378d13965184c6224a512a91ae6263a1
phase3 (canonical)        4316a32e210b8660b77a6eda916fb28c4f3bcb8a
origin/master             ba0fd818f552b47ca7e9db61d2d793ce0a85230d
the Phase 3 CI            https://github.com/Llayon/rogue-autobattler/actions/runs/42397098619
                          battle-ecs: success, save-battle-migration: success
                          120 suites, 9174 assertions, 0 failures, 0 unparsed
```

    The published Phase 3 baseline was verified against the remote
    BEFORE any work: the SHA matched, and both required jobs of the
    published run were green.

    The local documentation commit 2b24147 (the negative-control
    interpretation) exists on the fix/ci-integrity-runflow-entry
    branch. It is NOT part of the integration candidate: it is not
    necessary for the agreed scope.

## B. REPOSITORY ISOLATION

```
the integration worktree  %LOCALAPPDATA%\Temp\ri-integration
the branch                integration/phase3-master-release-rehearsal
the base                  4316a32 (the exact published Phase 3 SHA)
the tracked tree          clean throughout
```

    Not modified at any point: master, phase3/effect-status-trigger-gauntlet,
    the inventory worktree, the ri-hardening worktree, the A-H baseline
    worktree. Verified after the push of the previous series and again
    at the end of this one.

## C. PHASE 3 vs MASTER DIFF

    The numbers in the brief were OUT OF DATE. The measured values:

```
ahead / behind            0 / 274          (the brief said 254)
the changed files         294              (the brief said 278)
the merge commits         1
the merge-base            02fe83ef == master  -> a strict fast-forward
```

    By area: tests 173, core 77, docs 15, tools 10, content 6, scenes 4,
    workflows 2, the root 1.

## D. PRODUCTION RISK AUDIT

    The full production diff was analysed, not only the last commit.

    **RunController.** The run start, the phase transitions, the map
    selection, the merchant, TREASURE, REWARD, the battle preparation
    and start, the exit after a win and a loss, the BOSS completion
    and the Continue are all covered by the 120 suites. The only
    production change of this gauntlet is the battle-entry guard of
    the previous series.

    **Battle ECS.** The new effects, the trigger dispatcher, the
    reaction windows, the status effects, the event chains and the
    damage transactions are covered by the ECS suites and by the A-H
    differential. The ECS is NOT a complete replacement of the legacy
    runtime: the legacy runtime still owns the Shield Block path and
    the legacy unit_attacked poll. The A-H differential compares the
    legacy-projected traces of both, so the parity is measured, not
    assumed.

    **The shipping content.** Six files changed. The reaction defs
    moved to the Phase-3 event schema and the units gained their
    reaction_ids:

```
paladin   -> shield_block
guardian  -> counterattack, shield_block
knight    -> attack_of_opportunity
```

    **No effect can be applied twice.** The three systems are isolated
    in three independent ways:

      - the legacy view carries its OWN id, "shield_block_legacy";
      - the legacy view carries its OWN trigger, "unit_attacked",
        which is the only name the legacy runtime ever polled;
      - the ECS path resolves "shield_block" through the unit's
        reaction_ids and uses the Phase-3 event types.

    The legacy "unit_move_start" trigger of the Attack of Opportunity
    was NEVER polled by any legacy code: the only legacy poll in the
    whole project history is "unit_attacked" in DamageEffect. The AoO
    was therefore already dead on master, and the Phase-3 resource is
    the removal of a zombie registration rather than a behaviour
    change. The code says so at run_controller.gd:863.

## E. SAVE POLICY

    The owner decision of this stage: PRE-RELEASE SAVE COMPATIBILITY
    IS NOT GUARANTEED. This gauntlet did not remove a single
    migration mechanism, did not weaken a single test of the current
    format and did not add a migration for an old user file.

    What was PROVEN in the real browser: a corrupt save is DROPPED,
    not fatal. The meta.tres and the run file were overwritten with
    garbage in the IndexedDB; after the reload the application loaded
    normally, the Continue button was gone and New Run still worked,
    with zero page errors. No crash loop, no endless loading.

    The crash recovery, the exactly-once terminal awards, the atomic
    MetaProfile and the transaction journal remain UNPROVEN: they
    belong to the A0 Persistence Transaction Gauntlet, which this
    gauntlet does not start.

## F. CI/CD ARCHITECTURE

    The BLOCKER was confirmed in the code: web-build.yml deployed
    after `build` alone, and the required jobs of the separate
    test.yml were not a precondition of the publication.

    The architecture now:

```
master commit SHA
          |
          v
    test.yml (workflow_call, reusable)
      /            \
  save-battle    battle-ecs
  migration
      \            /
           |
       BOTH SUCCESS
           |
           v
    web build -> artifact validation -> pages deploy
```

    The test jobs are NOT duplicated: test.yml gains workflow_call and
    release.yml CALLS it. A reusable workflow runs inside the calling
    run, so the `needs:` is a real dependency and not a race between
    two independent workflows that watch the same branch. The old
    workflow was DELETED: its presence would have published without
    the gate.

    The deployment is refused when a required job is missing, failed,
    cancelled or skipped; when the artifact did not pass the
    validation; when the built SHA is not the deployed SHA; when the
    published SHA is not the tip of the branch; or when a manual
    dispatch tries to skip the required jobs.

    The permissions are minimal: `pages: write` and `id-token: write`
    exist ONLY in the deploy job, and the test jobs carry
    `contents: read`. `always()` is not used anywhere, so a skipped or
    a failed required job can never let the deployment through.

    The A-H baseline is PINNED to the published Phase 3 commit. The
    old HEAD^ baseline would have compared against the previous MASTER
    commit after the merge, and master carries NO A-H probe: the
    comparison would have been EMPTY, and an empty comparison passes.
    When the pinned baseline cannot be fetched, the step HOLDs.

## G. RELEASE NEGATIVE CONTROLS

```
NC-REL-01  remove the battle-ecs dependency            RED
NC-REL-02  remove the save-battle-migration dependency  RED
NC-REL-03  allow a failed/skipped required job          RED
NC-REL-04  remove the SHA identity check                RED
NC-REL-05  allow a manual deployment bypass             RED
NC-REL-06  accept a missing index.html                  RED
NC-REL-07  allow a stale deployment to supersede        RED
the clean gate: ALLOW (every gate passed)
```

    The controls evaluate a DECISION FUNCTION whose rules are DERIVED
    FROM THE MUTATED WORKFLOW: the mutation must OPEN the gate for
    the scenario it weakens. The first two versions of the harness
    were worthless -- the decision function checked the scenario
    instead of the workflow, so no mutation could ever change its
    verdict. That was caught and fixed before the controls were
    accepted.

## H. WEB EXPORT

```
the Godot version     4.7.stable.official.5b4e0cb0f
the export preset     "Web (no threads)"
the export target     an ABSOLUTE path (a defect was found and fixed)
the artifact          index.html 5448, index.js 279815,
                      index.wasm 39509339, index.pck 1893188 bytes
                      + the two worklets and the icons (9 files)
the validation        ARTIFACT VALIDATION: PASS
the references        index.html -> index.js / index.wasm / index.pck
the absolute paths    0
```

    The export was made from a CLEAN checkout with the build directory
    removed first. A REAL DEFECT was found this way and not by the CI:
    the relative export path fails on Windows with "the target folder
    does not exist or is not accessible", while the Linux CI resolves
    it. The workflow now exports to an absolute path.

## I. BROWSER SMOKE

    LOCAL WEB SMOKE. Chrome 156.0.8078.80 (headless, CDP), a local
    HTTP server, the real WASM runtime. NOT a live Pages deployment.

    16 of the 18 scenarios PASS, 2 were NOT REACHED (the TREASURE
    route and the settings). The full evidence is in
    docs/gauntlets/LOCAL_WEB_SMOKE.md.

    The three findings that matter:

      1. The battle-entry guard holds in the WEB runtime: the merchant
         SPACE closed the shop and started NO battle.
      2. The save survives a real browser restart: the reload offered
         Continue and the restored map stood on the SAME node.
      3. A corrupt save is dropped, not fatal.

## J. CONTENT AUDIT

    See section D. The shipping content is six files, the reactions
    are isolated from each other by three independent mechanisms, and
    no effect can be applied twice.

## K. INTEGRATION REHEARSAL

    A DRY RUN: nothing was merged and nothing was pushed.

```
the master SHA        02fe83ef
the candidate SHA     b00cb8b
the merge-base        02fe83ef == master -> the fast-forward is eligible
ahead / behind        0 / 274
the merge commits     1 (the historical one)
the new work          ONE commit on top of the published Phase 3
```

    The candidate carries the published Phase 3, the release workflow
    fix, the artifact validator, the release negative controls and the
    documents. It carries NO A0, no new Battle ECS runtime, no new
    economy, no new combat reaction, no new save architecture, no UI
    redesign and no licence decision.

## L. FULL REGRESSION

```
the standalone runner   120 executed / 120 passed
                        9174 assertions pass / 0 fail / 0 unparsed
the legacy characterization  rc=0, identical across 3 runs
the lint                0 errors / 5 warnings
the editor parse        0 parse errors / 0 script errors
the CI gates            10 / 10 clean
the A-H differential    PASS (8 + 8 fixtures, both rc=0)
the CI-01 self-tests    13 / 0 failed
the CI-02 self-tests    20 / 0 failed
the release NC          7 / 7 RED, the clean gate ALLOWs
the hardening NC        14 / 14 RED
the ledger controls     7 / 7 RED, the ledger VALID
the historical NC       44 RED, 0 SKIP, 0 INVALID
the reachability audit  180 declared / 180 reachable / 0 dead
the exit-contract audit 125 suites / 0 unsafe exit paths
the Web export          the full artifact, the validation PASS
the browser smoke       16 of 18 PASS, 2 NOT REACHED
```

    The counts are NOT hard-coded: the runner contract requires a
    positive number of suites and a positive number of assertions per
    suite, never a specific number. The published Phase 3 numbers
    (120 suites, 9174 assertions) are reproduced exactly on the
    candidate; the candidate's own additions are in the CI tooling,
    which the runner does not count as suites.

## M. INDEPENDENT CRITIC

    See the final section of this document after the critic's report
    was processed.

## N. KNOWN LIMITATIONS

    1. The LIVE PAGES deployment is NOT verified: there is no
       deployment in this gauntlet. NOT VERIFIED UNTIL REMOTE CI /
       DEPLOYMENT.
    2. The GitHub Pages environment restrictions are NOT verified
       locally.
    3. The crash recovery, the exactly-once terminal awards and the
       atomic MetaProfile are unproven: they belong to A0.
    4. The TREASURE route and the settings were not reached by the
       browser smoke.
    5. The CI self-tests of the runner use a FAKE godot: they prove
       the LOGIC of the runner, not the interaction with a real Godot
       binary. The real interaction is covered by the real A-H
       differential and by the real local export.

## O. COMMIT GRAPH

```
02fe83ef  master (the base)
   |
   +-- 4316a32  the published Phase 3 (274 commits over master)
   |     |
   |     +-- b00cb8b  chore(repo): gate the pages deployment on the
   |                  required CI
```

    Exactly ONE new commit on top of the published Phase 3. The
    candidate is a strict fast-forward of master.

## P. PUBLICATION INSTRUCTIONS

    docs/gauntlets/PHASE3_PUBLICATION_RUNBOOK.md -- seven stages, each
    a gate, with the explicit failure handling: HOLD, NO FALSE
    SUCCESS, NO FORCE PUSH, NO AUTOMATIC ROLLBACK TO AN UNVERIFIED
    ARTIFACT.

## Q. FINAL VERDICT

    See the final status at the end of this document.
