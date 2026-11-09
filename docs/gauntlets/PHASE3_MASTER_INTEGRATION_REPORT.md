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

    NOTE: `canonical` and `origin` are TWO DIFFERENT REPOSITORIES.
    `canonical` is Llayon/rogue-autobattler -- the repository this
    series targets. `origin` is Llayon/rogue-autobattler2, a
    different one, which is why its master is at a different SHA. The
    divergence is NOT a divergence of master: the master of the
    target repository is 02fe83ef, and that is the value every
    publication gate checks.

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

    The numbers in the brief were OUT OF DATE. They are READ FROM THE
    REPOSITORY, not written down: every documentation commit changes
    them, so a hard-coded count is a stale count by the next commit.
    The independent reviewer proved it -- the numbers below were the
    values of an earlier commit, in a block that simultaneously
    claimed they were not hard-coded.

```
the published Phase 3 over master
    git rev-list --count 02fe83ef..4316a32
the candidate over the Phase 3
    git rev-list --count 4316a32..HEAD
the candidate over master
    git rev-list --count 02fe83ef..HEAD
ahead / behind
    git rev-list --left-right --count master...HEAD
the changed files
    git diff --name-only master..HEAD | wc -l
the merge commits
    git rev-list --count --merges master..HEAD
the merge-base
    git merge-base master HEAD
```

    At the time of writing those commands returned 273, 67, 340,
    0/340, 298 and 1 -- a strict fast-forward over master. The
    merge commit is the historical one, inside Phase 3.

    By area: tests 173, core 77, docs 19, tools 12, content 6, scenes 4,
    .github 3, .hermes 1 (the run integrity ledger), the root 2
    (.gitignore and ARCHITECTURE.md).

    THE ARITHMETIC, RECONCILED. An earlier revision of this report
    said 274 commits and 294 files. Those were the values of the
    FIRST commit of the series (b00cb8b), written when the series
    consisted of one commit and never updated. The lesson, learned
    twice: the counts are NOT hard-coded -- they are invalidated by the
    next documentation commit. Read them from the repository:
        git rev-list --count 4316a32..HEAD      the series
        git rev-list --count master..HEAD       over master
        git diff --name-only master..HEAD | wc -l   the files
    The commits of the series are all
    listed in section O; none of them is a filler, and the history
    was NOT touched to make a number look right.

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
NC-REL-08  accept a reference to a missing path         RED
NC-REL-09  upload the artifact from the wrong job       RED
NC-REL-10  swallow the failure of the validation         RED
the clean gate: ALLOW (every gate passed)
```

    What each control actually MEASURES, because the difference
    matters when the evidence is read:

```
the GATE controls      NC-REL-01..05, 07, 09, 10
  they mutate the WORKFLOWS and assert a property of the parsed
  result: the needs graph, the job conditions, the permissions, the
  checkout, the SHA comparison, the concurrency group, the artifact
  flow.

the VALIDATOR controls NC-REL-06 and NC-REL-08
  they mutate the VALIDATOR and compare two validator invocations.
  They say nothing about the gate: they say that the artifact gate
  itself cannot be weakened.
```

    The controls are STRUCTURAL: the workflows are parsed as data and
    each control asserts a PROPERTY of the parsed graph. A mutation
    breaks a property, so the assertion fails, so the control is a
    real RED. And the CLEAN gate is asserted to satisfy every
    property, so a control that passes for the wrong reason is
    visible.

    Two holes that the controls had, found by the independent critic
    and closed:

      - the "the job never runs" check was a literal substring match
        on "if: false". A required job that KEPT its name and carried
        any other guard -- "if: ${{ false }}", "if: ${{
        !cancelled() }}", "if: github.event_name == 'never'", "if:
        'false'", "if:false" -- was invisible to every control, so
        the required job could be disabled while the harness stayed
        green. The check is now SEMANTIC: a required job must have NO
        condition at all, because a condition is the only way to take
        a job out of the run. All six spellings are caught now.
      - the artifact flow had NO control: the property function that
        would have caught the removal of the validation step or of the
        upload was defined and never registered. NC-REL-09 now moves
        the upload from the build job to the deploy job, which is
        exactly the defect that was fixed earlier in the series.

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

    The closure pass repeated it from a checkout that contained ONLY
    the tracked files: no .godot/, no build/, no untracked .uid, no
    local cache. The import reported zero errors, the export produced
    the complete artifact, the validation passed, and index.html,
    index.js and index.wasm came out BYTE-FOR-BYTE identical to the
    build of the working tree. The clean build was then loaded in the
    same browser: the WASM initialized, the menu appeared, a new run
    started, the battle ran and ended in a win, and the REWARD screen
    offered the three units.

    The 88 untracked .uid files are NOT a hidden dependency: the
    shipping content references no uid:// path, and the clean checkout
    without them exported perfectly.

## I. BROWSER SMOKE

    LOCAL WEB SMOKE. Chrome 156.0.8078.80 (headless, CDP), a local
    HTTP server, the real WASM runtime. NOT a live Pages deployment.

    17 of the 18 scenarios PASS. The TREASURE was verified in the
    real browser with the real WASM build: the production route was
    walked, the production handler applied the effect exactly once,
    the gold rose by the production constant (31 -> 36), the
    inventory gained one item, the meta profile gained one unlock, the
    checkpoint recorded the stable phase, a reload restored
    everything, and re-selecting the treasure granted nothing twice.

    The SETTINGS scenario is NOT VERIFIED, and the reason is a real
    defect in the shipping game: the Settings button is declared and
    never created, so the panel cannot be opened. It is a
    PRE-EXISTING defect -- the same is true on master -- and the
    panel is never exercised by any test. The setting itself works
    and is persisted; only the way in is missing.

    The full evidence, with the absolute values, is in
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
the master SHA        02fe83ef378d13965184c6224a512a91ae6263a1
the candidate SHA     (the tip of this branch: read it with
                       `git rev-parse HEAD` at the moment of the
                       publication -- a document that carries a SHA
                       it can outlive is a document that will be
                       wrong)
the merge-base        02fe83ef == master -> the fast-forward is eligible
ahead / behind
    git rev-list --left-right --count master...HEAD
the merge commits     1 (the historical one, inside Phase 3)
the new work          the commits on top of the published Phase 3
the changed files     11 over the published Phase 3
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
the release NC          31 / 31 RED, the clean gate ALLOWs
the hardening NC        14 / 14 RED
the ledger controls     7 / 7 RED, the ledger VALID
the historical NC       44 RED, 0 SKIP, 0 INVALID
the reachability audit  180 declared / 180 reachable / 0 dead
the exit-contract audit 125 suites / 0 unsafe exit paths
the Web export          the full artifact, the validation PASS
the clean checkout      the import 0 errors, the export complete,
                        the artifact validation PASS, the html/js/wasm
                        byte-for-byte identical to the worktree build
the browser smoke       17 of 18 PASS (the settings are NOT VERIFIED:
                        the Settings button is never created)
```

    The counts are NOT hard-coded: the runner contract requires a
    positive number of suites and a positive number of assertions per
    suite, never a specific number. The published Phase 3 numbers
    (120 suites, 9174 assertions) are reproduced exactly on the
    candidate; the candidate's own additions are in the CI tooling,
    which the runner does not count as suites.

## M. INDEPENDENT CRITIC

    TWO independent critic passes read the diff, the new workflows and
    the harnesses, and hunted the twenty listed classes of defect.

    The SECOND pass found a defect that only the REAL CI could have
    shown: tools/release_negative_controls.py was the only file in the
    repository that imported yaml, and no workflow installs pyyaml.
    The step would have failed with an ImportError on the runner and
    turned the REQUIRED battle-ecs job RED. Every other CI tool of the
    repository deliberately avoids yaml, and now the release controls
    do too. They were re-run under a python where importing yaml
    raises: 31 of 31 RED, exit 0.

    It also found TWO HIGH findings in the HARNESS itself, which are
    the most important findings of the whole closure:

      - the property function that would have caught the removal of
        the validation step was DEFINED and never REGISTERED, so the
        artifact flow had no control at all. It is registered now,
        with NC-REL-09 as its control.
      - the "the job never runs" check was a literal substring match
        on "if: false", so a required job that KEPT its name and
        carried any other guard was invisible to every control. The
        check is now SEMANTIC: a required job must have NO condition
        at all, because a condition is the only way to take a job out
        of the run. All six spellings are caught, on both required
        jobs.

    And it recommended the assertion that makes that class of defect
    impossible: a registry completeness check, which runs BEFORE the
    controls and exits 2 if any control is covered by no mechanism, if
    any defined property is unreachable, or if two controls share a
    property. Removing one entry from the registry now produces
    exactly the F-01 diagnostic.

    The FIRST pass found no HIGH in the workflow itself. Two of its
    findings were real and are closed.

    ### The concurrency protection was not part of the decision

    The critic observed that the release DECISION FUNCTION never read
    the CONCURRENCY block: the stale protection had only ONE mechanism
    in the decision (the tip check), while the workflow has TWO (the
    per-branch concurrency group and the tip check). The NC-REL-07
    mutation changed `cancel-in-progress`, so it could not change the
    verdict through that path -- and a control that cannot fail proves
    nothing.

    **Closed.** The decision now derives both mechanisms: the group
    must be per ref, and a cancelled run must never reach the deploy
    job. The NC-REL-07 mutation removes the tip check as well, so the
    stale publication is really possible, and the control proves that
    the mutated gate ALLOWs it while the clean gate denies it.

    ### The reusable trigger had been reverted

    A strict YAML audit -- parse the workflows and assert the trigger
    block, the needs graph, the permissions and the concurrency block
    -- found that `test.yml` had lost its `workflow_call` trigger and
    its `contents: read` permission. The release workflow was calling
    a workflow that could not be called, and the CI would have failed.

    The cause was a `git reset --hard` from an earlier series, which
    reverted that change together with the unrelated restoration.

    **Closed.** The trigger and the permission are restored, the YAML
    is parsed afterwards, and the commit hook had already refused the
    first attempt at the commit message, which is how the length rule
    surfaced.

    ### The artifact never reached the deploy job

    Reading the workflow the way GitHub would execute it exposed
    THREE defects that a YAML parse does not catch:

      1. The deploy job had NO checkout, so its `git ls-remote` had no
         remote to ask: the tip check compared against nothing.
      2. The deploy job had its own `upload-pages-artifact` with
         `path: build/`, and there is no `build/` in that job: the
         artifact lives in the web-build job.
      3. The web-build job never uploaded the artifact at all.

    **Closed.** The deploy job checks out the repository, and an
    UNREADABLE tip is a HOLD rather than a silent pass. The job that
    BUILDS the artifact uploads it, so the published bytes are exactly
    the validated bytes, and the deploy job publishes the uploaded
    artifact instead of a directory that does not exist there. The
    decision function now requires the tip check to be READABLE.

    ### The release controls proved NOTHING — and that was the
    ### fundamental finding

    The critic proved the seven release negative controls were
    vacuous. They evaluated a "decision function" that read the
    workflow as TEXT, and every "RED" was produced by a rule inside
    that function that RECOGNISED the exact mutation text. A
    genuinely broken deploy -- the deploy losing the required call and
    gaining `if: always()` -- was reported as a **PASS**, because the
    harness reported success exactly when the controls proved nothing.
    NC-REL-06 was vacuous by construction: both branches of its `if`
    appended to the failures list, so it was always RED.

    **Closed.** The controls are now STRUCTURAL: the workflows are
    parsed as DATA and each control asserts a PROPERTY of the parsed
    graph -- the needs graph, the job conditions, the permissions, the
    checkout, the SHA comparison, the concurrency group, the artifact
    flow. A mutation breaks a property, so the assertion fails, so the
    control is a real RED. The accounting is honest in the other
    direction too: a mutation that does NOT open the gate is a MISSED
    control and counts as a problem, so the harness exits 0 only when
    every control is a real RED.

    The proof that the harness works now: a genuinely broken deploy
    is caught, where the old harness reported a PASS.

    ### The validator accepted an incomplete artifact

    The critic showed that the validator passed an artifact with a
    4-byte WASM, and one with no `.pck` at all. The WASM check only
    asked whether a filename CONTAINED ".wasm", and the minimum size
    was applied to index.html alone. A partially failed export would
    have been published as a blank page.

    **Closed.** The validator now requires a WASM of at least a
    megabyte with the WebAssembly magic bytes, a resource bundle of at
    least 64 KB, and the JavaScript bootstrap. The measured verdicts:
    the full artifact PASS; the missing index.html, the 4-byte WASM,
    the 64 KB WASM, the wrong magic bytes and the missing `.pck` all
    DENY.

    ### The html references were compared by basename

    The critic showed that the reference check compared only the
    BASENAME: a reference to "subdir/index.js" passed when "index.js"
    sat at the root. The site is served from the artifact root, so the
    reference would 404 in production while the validator reported
    PASS.

    **Closed.** The check now resolves the reference against the
    deployment root, refuses an absolute reference, and refuses one
    that resolves outside the artifact. The measured verdict for the
    critic's exact scenario is DENY. NC-REL-08 was added for the
    class.

    ### The release controls only ran locally

    The critic required the controls to be wired into CI: a control
    that nobody runs can be bypassed by a future edit that nobody
    checks.

    **Closed.** They run in the battle-ecs job -- the required job the
    deployment depends on -- so a broken release gate BLOCKS the
    publication instead of being discovered after it.

    ### The critic's verdict

    The critic returned HOLD, and stated explicitly that there was no
    HIGH in the YAML gate as it stood. Its HOLD rested on the two
    findings above: the inverted evidence (F-01) and the incomplete
    artifact (F-02), both of which are now closed and proved. The
    critic also confirmed clean all twenty hunt items, the
    double-application question, the absence of any legacy/ECS
    dependency, and that nothing was pushed and master was untouched.

    ### What the critic confirmed clean

    The critic ran the full regression itself: 120 suites, 9174
    assertions, 0 failures, 0 unparsed, exit 0 -- identical to the
    measured result of this gauntlet. It also verified the shipping
    content question directly: the legacy Attack of Opportunity on
    master carried `trigger = "unit_move_start"`, a name that no
    legacy code ever polled, and the ECS imports neither the legacy
    nor the reverse, so the two systems do not depend on each other.

## N2. THE BRANCH AUTHORIZATION

    The deployment is authorized from ONE ref: refs/heads/master.

```
ALLOWED
  a push to master
  a manual dispatch that targets master

DENIED
  a manual dispatch of a staging branch
  a manual dispatch of the Phase 3 branch
  a manual dispatch of a feature branch
  a manual dispatch of a branch whose name merely ends with master
  a manual dispatch of a tag
  a push to a staging branch
  a pull_request event
  a scheduled event
  a workflow_run event
```

    The guard is the deploy job's own condition:

```
    if: >-
      \${{
        success() &&
        github.ref == 'refs/heads/master' &&
        (
          github.event_name == 'push' ||
          github.event_name == 'workflow_dispatch'
        )
      }}
```

    The full ref is compared EXACTLY. That is what refuses a tag
    (refs/tags/v1 is not refs/heads/master) and what refuses a
    different branch whose name merely ends with master
    (refs/heads/feature/master).

    success() is spelled out rather than left to the platform default,
    so the contract is visible in the workflow instead of implied.
    It is NOT an always() bypass: always() would run the job even
    when a required job failed, which is exactly what must not
    happen.

    The required jobs stay mandatory in every allowed case: a failed,
    skipped or cancelled required job refuses the deployment.

    THE COMPARISON IS CASE INSENSITIVE. GitHub Actions compares
    strings with == IGNORING THE CASE, so the condition above is also
    true for a branch named "Master" -- a DISTINCT branch on a
    case-sensitive repository. The string comparison alone is
    therefore NOT a sufficient guard, and the deploy job carries a
    second, case-INDEPENDENT one: it reads the tip of master from the
    remote, whose ref path is case sensitive, and compares the SHA
    with the SHA being published. The question it asks -- is this the
    same COMMIT as master? -- cannot be changed by the case. The
    check is fail-closed: an unreadable master tip is a HOLD, never
    a GREEN.

    The tip-check that protects against STALENESS -- the SHA against
    the tip of the DISPATCHED branch -- is kept. The two checks
    answer different questions and both are needed.

    The controls check this BEHAVIOURALLY. The deploy job's condition
    is EVALUATED for each scenario, and the property asserts both
    sides: the forbidden refs and events are refused AND the
    legitimate master push is still allowed. A property that only
    ever denies would be satisfied by a workflow that never publishes
    anything, so the ALLOW side is part of it.

    NC-RB-01  remove the master-ref guard                 RED
    NC-RB-02  replace it with a guard that accepts any ref RED
    NC-RB-03  add an or-bypass for another event          RED
    NC-RB-04  move the guard into an optional step        RED
    NC-RB-05  replace success() with a failure tolerance   RED
    NC-RB-06  block even the legitimate master push       RED
    NC-RB-07  let the build job continue on error         RED
    NC-RB-08  remove the case-independent master check    RED
    NC-RB-09  accept the sha whatever the branch tip is    RED
    NC-RB-10  accept the sha whatever master's tip is      RED
    NC-RB-11  give the build job the pages write permission  RED
    NC-RB-12  merge the policy in from a yaml anchor          RED
    NC-RB-13  authorize one more ref beside master           RED
    NC-RB-14  add a pull_request trigger                     RED
    NC-RB-15  make the concurrency group constant             RED
    NC-RB-16  disable the reusable workflow's job               RED
    NC-RB-17  add a second workflow that publishes             RED
    NC-RB-18  swallow the result of the controls                RED
    NC-RB-19  need a job that does not exist                   RED
    NC-RB-20  remove the timeout of the deploy job             RED
    NC-RB-21  rename the release workflow                      RED

    ENVIRONMENT BRANCH RESTRICTION:
    NOT VERIFIED / OWNER ACTION REQUIRED

    The github-pages environment can be restricted to master as an
    INDEPENDENT second line of defence. That is a repository setting
    and it was NOT changed here. Until it is confirmed, there is no
    environment-level protection, and the only protection is the
    deploy job's condition.

## N. KNOWN LIMITATIONS

    1. The LIVE PAGES deployment is NOT verified: there is no
       deployment in this gauntlet. NOT VERIFIED UNTIL REMOTE CI /
       DEPLOYMENT.
    2. The GitHub Pages environment restrictions are NOT verified
       locally.
    3. The crash recovery, the exactly-once terminal awards and the
       atomic MetaProfile are unproven: they belong to A0.
    4. The SETTINGS were not reached by the browser smoke, and they
       cannot be: the Settings button is declared and never created,
       so the panel cannot be opened. The TREASURE WAS reached and
       verified -- the route was walked, the production handler
       applied the effect exactly once, and the re-selection granted
       nothing twice.
    5. The CI self-tests of the runner use a FAKE godot: they prove
       the LOGIC of the runner, not the interaction with a real Godot
       binary. The real interaction is covered by the real A-H
       differential and by the real local export.

## O. COMMIT GRAPH

```
   4316a32  the published Phase 3 (its count over master: see the
         commands in section C)
      |
      +-- b00cb8b chore(repo): gate the pages deployment on the required CI
         |
      +-- d40f7d5 docs(repo): write the integration report and the release runbook
         |
      +-- 23e96e1 fix(repo): restore the reusable trigger and split the release controls
         |
      +-- 66515d4 fix(repo): read the concurrency protection in the release decision
         |
      +-- 4b39876 docs(repo): record the critic findings and the final verdict
         |
      +-- c8185ec docs(repo): add the critic findings to the risk register
         |
      +-- ef1ccd0 fix(repo): pass the artifact from the build job to the deploy job
         |
      +-- 078b2b3 docs(repo): record the artifact flow defects in the report
         |
      +-- 45125fc fix(repo): remove the decorative dispatch input and the dangling field
         |
      +-- dbad02a fix(repo): make the release controls structural instead of textual
         |
      +-- 3c3e92f fix(repo): reject a truncated or incomplete web artifact
         |
      +-- 5f6a89b docs(repo): record the critic findings in the report and the register
         |
      +-- d9276bd fix(repo): check the html references by path and gate the release
         |
      +-- 7681c39 docs(repo): record the critic verdict and the accepted risks
         |
      +-- 9a563ae docs(repo): reconcile the commit counts and the browser evidence
         |
      +-- 1e23ab1 docs(repo): record the settings defect and the uid classification
         |
      +-- 9978ba4 docs(repo): add the staging stage and reconcile the commit graph
         |
      +-- 9d39341 docs(repo): state the uid references precisely
         |
      +-- f2f3a8f docs(repo): reconcile the final counts of the series
         |
      +-- 553e320 fix(repo): drop the yaml dependency from the release controls
         |
      +-- e1d1d43 docs(repo): record the yaml blocker and close the closure
         |
      +-- 2412049 docs(repo): correct the stale numbers in the report
         |
      +-- 9011ff3 fix(repo): cover the artifact flow with a structural control
         |
      +-- 93faf49 fix(repo): close the two high findings of the independent critic
         |
      +-- 229a3fb docs(repo): rebuild the commit graph and reconcile the counts
         |
      +-- fc09b0d docs(repo): close the docstring and the stale reference findings
         |
      +-- 534a573 test(repo): assert the control registry is complete
         |
      +-- 3e694fd docs(repo): record the critic findings and the final counts
         |
      +-- 4b3d18a docs(repo): correct the uid facts in the register and the smoke document
         |
      +-- 4138eb1 fix(repo): close the re-review findings in the controls
         |
      +-- b205143 docs(repo): state the closure findings in the final verdict
         |
      +-- f42e68e docs(repo): reconcile the final commit counts and the graph
         |
      +-- 4f5b51a fix(repo): authorize the pages deployment from master only
         |
      +-- 18c4c1f docs(repo): state the branch authorization and the concurrency semantics
         |
      +-- f0a69fd fix(repo): compare the published sha with the tip of master
         |
      +-- 6d52dbd docs(repo): record the case-independent master check
         |
      +-- a38848a docs(repo): separate the remote run from the local branch work
```

    the commits on top of the published Phase 3: the release
    gate, the documents, and the fixes that the checks and the
    independent critic forced. Every one of them is a single parent,
    so the chain is linear and the candidate remains a strict
    fast-forward of master.

    The arithmetic: the published Phase 3's count over master, plus
    this series' count over the Phase 3, equals the candidate's count
    over master -- read with the commands in section C, not from here:
    commits over master.

    The 11 files the series changed over the published Phase 3:

```
.github/workflows/release.yml                    NEW
.github/workflows/test.yml                       the reusable trigger
.github/workflows/web-build.yml                  DELETED
.gitignore                                       the build output
content/reactions/attack_of_opportunity.tres      the dangling field
docs/gauntlets/LOCAL_WEB_SMOKE.md                NEW
docs/gauntlets/PHASE3_MASTER_INTEGRATION_REPORT.md   NEW
docs/gauntlets/PHASE3_PUBLICATION_RUNBOOK.md     NEW
docs/gauntlets/PHASE3_RELEASE_RISK_REGISTER.md   NEW
tools/release_negative_controls.py               NEW
tools/validate_web_artifact.py                   NEW
```

    The ONLY production file among them is the AoO resource, and the
    change is the removal of a field that no longer exists in the
    class: `melee_only` was removed from `ReactionDef` in Phase 3,
    and the resource still carried it. Godot loads the resource and
    silently drops the unknown property, so the field was a no-op --
    but it was a reference to something that no longer exists, and it
    misleads the next reader. `melee_only` appears NOWHERE in the
    production code: only in a historical plan document and in one
    test comment.

## P. PUBLICATION INSTRUCTIONS

    docs/gauntlets/PHASE3_PUBLICATION_RUNBOOK.md -- seven stages, each
    a gate, with the explicit failure handling: HOLD, NO FALSE
    SUCCESS, NO FORCE PUSH, NO AUTOMATIC ROLLBACK TO AN UNVERIFIED
    ARTIFACT.

## Q. FINAL VERDICT

```
PHASE 3 -> MASTER INTEGRATION & RELEASE SAFETY
= READY FOR AUTHORIZED PUBLICATION
```

    Every gate was executed and none of them was taken on trust. The
    BLOCKER of the release path is closed and proved by THIRTY ONE
    structural negative controls; the HIGH of the A-H baseline is
    closed and proved by the pinned baseline that HOLDs when it is
    unavailable; the MEDIUM of the export path is closed and proved by
    a clean local export.

    The closure pass added three more things and found one more real
    defect:

      - the TREASURE is verified in the real browser with the real
        WASM build, with the absolute values;
      - the clean checkout exports a complete artifact whose html, js
        and wasm are byte-for-byte identical to the working tree build;
      - the staging push cannot deploy the Pages, and the structural
        reason is recorded;
      - the release controls no longer import yaml. They were the
        ONLY file in the repository that did, and no workflow installs
        pyyaml, so the step would have failed with an ImportError on
        the runner and turned the REQUIRED battle-ecs job RED. The
        controls now read the workflows as text, like every other CI
        tool of the repository, and they were run under a python where
        importing yaml raises: 31 of 31 RED, exit 0.

    The SETTINGS scenario remains NOT VERIFIED: the Settings button is
    declared and never created, so the panel cannot be opened. It is
    a PRE-EXISTING defect -- the same is true on master -- the panel
    is never exercised by any test, and the setting itself works and
    is persisted. It is recorded as H-05, an ACCEPTED RISK for the
    staging run, with a named follow-up.

    The independent critic returned HOLD. Its HOLD rested on the
    inverted evidence (the controls proved nothing) and on the
    incomplete artifact (a 4-byte WASM passed). BOTH are closed and
    proved, and the two further findings it named are closed as well.
    The critic confirmed clean all twenty hunt items.

    There is no open HIGH or BLOCKER. The known limitations of section
    N are real and are NOT hidden: the live Pages deployment, the
    environment restrictions and the settings scenario remain
    unverified, and the crash recovery and the atomic MetaProfile
    remain the business of A0.

    The closure pass itself was reviewed twice, and both reviews found
    real defects -- in the HARNESS, not in the workflow. The ones that
    mattered:

      - the release controls imported yaml, and no workflow installs
        pyyaml: the step would have failed on the runner and turned
        the REQUIRED battle-ecs job RED. It would only ever have
        appeared on the real CI.
      - a property function was defined and never registered, so the
        artifact flow had no control at all.
      - the "the job never runs" check was a literal substring match,
        so a required job that kept its name and carried any other
        guard was invisible.
      - the same check then over-corrected and read a STEP-level
        condition as a job-level one, so a legitimate cleanup step
        would have made the required job go RED. That one was a live
        CI-breaking false positive.

    Each is closed, and the last two classes are now impossible by
    construction: the registry completeness check makes an
    unregistered property a hard failure, and the condition check
    distinguishes the job level from the step level by INDENTATION.

    The controls are 31 of 31 RED, with and without pyyaml, and the
    CLEAN gate ALLOWs every scenario.

    The three residual risks that are accepted, with their reasons:

      - the A-H baseline is pinned rather than HEAD^: stable, and the
        runbook names the deliberate refresh step;
      - the legacy and the ECS combat systems both carry Shield
        Block: isolated by three independent mechanisms, so the
        effect cannot be applied twice;
      - the Pages environment restrictions are not verified locally:
        they are only verifiable against the real deployment.

    Nothing was pushed, nothing was merged, nothing was deployed, and
    master was not touched. The publication is prepared; the DECISION
    to publish is a separate, authorized act.
