# PHASE 3 RELEASE RISK REGISTER

    Every entry states WHAT was proven, HOW it was proven and what is
    still unproven. A proven defect and a theoretical risk are never
    mixed: the PROVEN column says which one it is.

## BLOCKER

### B-01 — the Pages deployment did not depend on the required CI

    Status:  PROVEN DEFECT — FIXED
    Found:   .github/workflows/web-build.yml, the `deploy` job needed
             only `build`. The required jobs live in a separate
             workflow (test.yml) whose success was not a precondition
             of the publication, so a RED test run never stopped a
             deploy.
    Fix:     test.yml became reusable (workflow_call) and the new
             release.yml calls it. The deploy job needs the required
             tests AND the build. The old workflow was deleted, because
             its presence would have published without the gate.
    Proof:   tools/release_negative_controls.py — NC-REL-01..10 and NC-RB-01..07, all
             semantic RED; the clean gate ALLOWs the good scenario
             only.
             EIGHT of the TWENTY FIVE are GATE controls: they mutate the
             workflows and assert a property of the parsed result.
             NC-REL-06 and NC-REL-08 are VALIDATOR controls: they
             mutate the validator itself and compare two validator
             invocations. NC-REL-09 covers the artifact FLOW: the job
             that builds the artifact uploads it, and the deploy job
             does not upload a directory it does not have.
    Residual: the GitHub Pages environment restrictions are NOT
              verified locally: NOT VERIFIED UNTIL REMOTE CI /
              DEPLOYMENT.

## HIGH

### H-09 — the deployment could be authorized from any ref by a manual dispatch

    Status:  PROVEN DEFECT — FIXED
    Found:   the release workflow had "on: push: branches: [master]" AND
             "workflow_dispatch:", and the deploy job carried NO
             job-level condition. A manual dispatch runs the workflow
             file of the SELECTED ref, and github.ref is then that
             ref. So a dispatch of staging, phase3, a feature branch
             or a tag would build, validate and PUBLISH that SHA to
             GitHub Pages, as long as the tests of the same ref were
             green.
             The tip-check did not close it: it compares the SHA with
             the tip of the DISPATCHED ref, so for a dispatch on
             staging the dispatched SHA IS the tip and the check
             passes. It guards against staleness, not against the
             wrong branch.
    Fix:     the deploy job carries the authorization explicitly:
             success() AND github.ref == 'refs/heads/master' AND the
             event is push or workflow_dispatch. The full ref is
             compared EXACTLY, so a tag and a branch whose name merely
             ends with master are both refused.
    Residual: the github-pages environment is NOT confirmed to be
              restricted to master. That is a repository setting and
              it was NOT changed by this series, so there is no
              independent environment-level protection yet:
              ENVIRONMENT BRANCH RESTRICTION:
              NOT VERIFIED / OWNER ACTION REQUIRED.
              The only protection is the deploy job's condition.
    Proof:   the branch authorization is checked by EVALUATING the
             deploy job's condition, not by searching for a string.
             Seven new controls, NC-RB-01..07, and the property
             asserts BOTH sides: the forbidden refs and events are
             refused AND the legitimate master push is still allowed.
             25 of 25 controls are RED.
             The matrix: push master ALLOW, manual master ALLOW,
             manual staging/phase3/feature/tag/pull_request/schedule
             DENY, a failed required job DENY.

### H-18 — the fourth review: eleven classes of mutation, and two false REDs

    Status:  PROVEN DEFECT — FIXED
    Found:   the fourth independent reviewer built an INDEPENDENT
             68-case adversarial battery and an INDEPENDENT GitHub
             Actions expression evaluator -- not the repo's -- and
             found eleven classes of mutation the harness reported
             GREEN while the gate was open or broken, plus TWO FALSE
             REDS that would have broken the CI on a legitimate edit.
             The workflow itself was never found broken, across four
             passes: the gate is sound, the proof was not.

               F1  the step conditions were matched against a LIST OF
                   SPELLINGS, so any composition evaded it. In GitHub
                   Actions ANY status function drops the implicit
                   success(), so "success() || failure()" is true
                   after the previous step failed -- a
                   publish-after-HOLD
               F2  prop_11 stripped whole-line comments only, so the
                   tip check's remote read could be replaced by a
                   TRAILING comment
               F3  the permissions spellings: the flow mapping
                   "{pages: write}" and the quoted scalars
               F4  the WORKFLOW-LEVEL permissions block was never
                   read, so a top-level elevation plus a deleted job
                   block would elevate that job
               F5  the forbidden-ref list was a SAMPLE, not a rule: a
                   mutation that opened ONE other ref passed every
                   control
               F6  FALSE RED: the needs block form lost the second
                   item, so the deploy job rewritten in the standard
                   block form would report "the deploy does not need
                   the web build" and BLOCK the publication
               F7  FALSE RED: a quoted job condition is valid YAML
                   and valid GHA, and the harness raised a TypeError
                   that run_control swallowed as INVALID -- a red CI

    Fix:     the step conditions are EVALUATED with the harness's own
             evaluator against a failed previous step; the code
             reader is used everywhere; the permissions are read as a
             block, at the workflow level and per job; the
             authorization set is asserted over a generated corpus;
             the needs and the condition are read in every valid
             spelling.
    Proof:   the controls are 25 of 25 RED, with and without pyyaml,
             and the legitimate edits -- the needs in the block form,
             the condition in quotes -- still pass.

### H-15 — the third review: seven HIGH, all in the harness

    Status:  PROVEN DEFECT — FIXED
    Found:   the third independent reviewer built its own mutation
             battery and found seven HIGH findings. Every one was in
             the EVIDENCE HARNESS, not in the workflow: the gate was
             never found broken, but the controls could not see a
             mutation that genuinely opens it. The distinction
             matters -- "the workflow is sound; the proof is not".

               H-1  the model mapped cancelled() to "the needs did not
                    succeed", which made !cancelled() equivalent to
                    success(). The platform says otherwise, and the
                    difference is the dangerous one: a deploy job
                    guarded by !cancelled() runs on a RED CI and
                    publishes the artifact of a SHA whose tests
                    failed
               H-2  the fail-closed refusals could be neutered: the
                    master refusal lost its OWN exit 1 and a global
                    search matched the COMPARISON's exit; the
                    tip-check's unreadable refusal was not covered at
                    all; the comparison's refusal could be deleted
                    while its "if" stayed
               H-3  a folded or literal block scalar hid a step-level
                    bypass, and the guard was narrower than the risk
                    class: in GitHub Actions a step with an "if"
                    OVERRIDES the implicit success(), so
                    "if: failure()" and "if: !cancelled()" on the
                    publish step are publish-after-HOLD
               H-4  a TRAILING comment carried the tokens:
                    'MASTER_SHA="" # git ls-remote origin
                    refs/heads/master' mentions the whole policy and
                    reads nothing

    Fix:     the refusals must belong to THEIR OWN condition; the
             step conditions are expanded before they are judged and
             the class is widened to every overriding condition; the
             code reader cuts the trailing comments off, with the
             quotes tracked; the model reproduces the platform
             exactly.
    Proof:   the controls are 25 of 25 RED, with and without pyyaml,
             and every scenario of the reviewer is detected.

### H-16 — the publication could come before the checks

    Status:  PROVEN DEFECT — FIXED
    Found:   the third reviewer found a REAL bypass: a deploy-pages
             step placed BEFORE the two fail-closed checks. The checks
             would then HOLD the job -- but the pages had ALREADY
             been published. The refusal was theatre.
    Fix:     the property requires the ORDER: exactly ONE
             publication, it is the LAST step, and both fail-closed
             checks come BEFORE it.

### H-17 — the permissions sweep was a list of spellings

    Status:  PROVEN DEFECT — FIXED
    Found:   the property refused "pages: write" and "id-token:
             write" on the other jobs, so every OTHER elevated scope
             passed: write-all, contents: write, actions: write.
    Fix:     the permissions are read as the BLOCK they are. The
             scalar form "permissions: write-all" is elevated by
             itself, and the block form lists one scope per line.

### H-13 — the model was stricter than the platform it models

    Status:  PROVEN DEFECT — FIXED
    Found:   the model mapped cancelled() to "the needs did not
             succeed", which made !cancelled() equivalent to
             success(). The platform says otherwise: !cancelled() is
             TRUE even when a needed job FAILED -- it is the
             documented way to run a job "regardless of its success
             or failure". So the model was STRICTER than the platform
             and reported a policy the platform does not enforce: a
             deploy job guarded by !cancelled() was reported as safe
             while the platform would run it on a red CI and publish
             the artifact of a SHA whose tests failed.
             Found by the independent critic.
    Fix:     the model now reproduces the platform exactly:
             success() with a RED need is False, !cancelled() with a
             RED need is True, cancelled() with a RED need is False.
    Proof:   the same rule is applied everywhere the model touches
             the platform: it must be neither stricter nor looser.
             The case folding was already made LOOSER on purpose,
             for exactly the same reason.

### H-14 — a second publication step and a comparison in an echo

    Status:  PROVEN DEFECT — FIXED
    Found:   two more ways to break the release gate that every
             control missed, found by building adversarial mutations
             directly:
               a SECOND deploy-pages step was invisible -- the checks
               look at the deploy job's body, so one guarded
               publication plus one unguarded publication is an
               unguarded publication
               the comparison could be moved into an echo: a check
               that merely MENTIONS a comparison is not a check, it
               prints a message and continues
    Fix:     the property requires EXACTLY ONE publication step and
             nothing after it, and the comparisons must be
             CONDITIONS -- in the tip-check and in the master check
             alike.

### H-12 — the controls asserted a FRAGMENT of a mechanism

    Status:  PROVEN DEFECT — FIXED
    Found:   the independent critic found four more ways to break the
             release gate that every control missed. Each time the
             cause was the same: a control asserted ONE FRAGMENT of a
             mechanism, and the fragment it asserted was satisfied by
             something else.

               F-01  the master check could be reduced to READING the
                     tip of master and doing nothing with it
               F-04  the fail-closed refusal for an UNREADABLE tip
                     could be deleted: a global search for "exit 1"
                     was satisfied by the OTHER refusal in the same
                     step -- the comparison
               F-05  prop_04 scanned every line, COMMENTS included,
                     so a commented out comparison satisfied it
               F-06  the permissions scope was asserted NOWHERE:
                     pages: write could be added to the build job

    Fix:     the properties now assert the WHOLE mechanism -- the
             read, the comparison and the refusal -- and the step's
             own block is parsed with its INDENTATION kept, because
             the indentation is what delimits a step from the next
             one. A mechanism's refusal must be inside its own step.
    Proof:   NC-RB-11 is the new control for the permissions. All of
             the critic's scenarios are detected, and the controls are
             25 of 25 RED.

### H-11 — four bypasses were invisible to the controls

    Status:  PROVEN DEFECT — FIXED
    Found:   the independent critic ran adversarial mutations against
             the controls and four of them passed, so the harness
             reported GREEN for workflows that carried a real bypass:

               X1/X5  the SHA checks were neutered: a check that
                      compares the published SHA with ITSELF always
                      succeeds, so it proved nothing while the stale
                      publication would pass it
               X2     a step-level "if: always()" -- in both the
                      mapping form and the list form -- was invisible.
                      It is the shape of a bypass: the deploy job would
                      be skipped when a need failed, but the workflow
                      still carried a step that runs no matter what
               X3     a job-level "if: !cancelled()" instead of
                      "success()". The two are NOT equivalent:
                      !cancelled() is true even when a required job
                      FAILED, so the deploy job would publish the
                      artifact of a SHA whose tests failed
               X4     the fail-closed refusal was removable, so an
                      unreadable tip would not have been a HOLD

             The lesson repeated itself: the workflow's own COMMENTS
             contain the text "git ls-remote origin refs/heads/master",
             so a search over the whole body matched the COMMENT and
             the control reported GREEN while the check it protects
             was gone. The checks read CODE, never comments.
    Fix:     the properties now require that the SHA checks READ THE
             REMOTE, that the deploy job's condition carries
             success() and refuses the other status functions, that no
             step of the deploy job is conditioned to run regardless,
             and that the checks fail closed.
    Proof:   NC-RB-09 and NC-RB-10 are the new controls. All eight of
             the critic's adversarial mutations are now detected, and
             the controls are 25 of 25 RED.

### H-10 — the string comparison of the ref is case insensitive

    Status:  PROVEN DEFECT — FIXED
    Found:   GitHub Actions compares strings with == IGNORING THE CASE.
             So `github.ref == 'refs/heads/master'` is also true for a
             branch named "Master" or "MASTER", and such a branch is a
             DISTINCT branch on a case-sensitive repository. The string
             comparison alone was therefore NOT a sufficient guard.
             Found by the independent critic.
    Fix:     the deploy job carries a SECOND, case-INDEPENDENT guard:
             it reads the tip of master from the remote -- whose ref
             path is case sensitive -- and compares the SHA with the
             SHA being published. The question it asks, "is this the
             same COMMIT as master?", cannot be changed by the case.
             The check is fail-closed.
    Proof:   NC-RB-08 removes that check and the control is RED. The
             model reproduces the platform: the string comparison folds
             the case, so the model reports exactly what Actions would
             do.

### H-08 — the concurrency comment described a cancellation that did not happen

    Status:  PROVEN DEFECT — FIXED
    Found:   the comment said "a newer commit on the same branch
             cancels the older run". With cancel-in-progress: false
             the older run finishes FIRST and the newer one QUEUES
             behind it. A reader would have believed there were no
             ordering guarantee, and would not have looked for the
             mechanism that actually provides it.
    Fix:     the comment now states what the group does, what it does
             NOT do, that the tip-check is the real protection, and
             that the guarantee is NOT atomic: the tip-check and the
             publication are two separate steps, so a commit pushed
             between them is not seen. The window is small, the
             concurrency group bounds the outcome, and the older
             publication did happen briefly.
    Residual: closing that window would need a protocol that
             re-checks the tip at the moment of the publication. That
             is a substantially more complex protocol and is recorded
             here rather than built in a hardening pass.

### H-07 — the "the job never runs" check was a literal substring match

    Status:  PROVEN DEFECT — FIXED
    Found:   the check looked for the exact text "if: false". A
             required job that KEPT its name and carried any other
             guard -- "if: ${{ false }}", "if: ${{ !cancelled() }}",
             "if: github.event_name == 'never'", "if: 'false'",
             "if:false" -- was invisible to EVERY control, so the
             required job could be disabled while the harness still
             reported green and exited 0. That is precisely the
             BLOCKER (B-01) the series exists to close.
             Found by the independent critic.
    Fix:     the check is SEMANTIC. A required job must have NO
             condition at all: a condition is the only way to take a
             job out of the run, so any condition on a required job is
             a guard.
    Proof:   all six spellings, on both required jobs, are caught:
             battle-ecs by NC-REL-01, save-battle-migration by
             NC-REL-02.

### H-08 — the artifact flow had no control at all

    Status:  PROVEN DEFECT — FIXED
    Found:   prop_06_artifact_validation was DEFINED and never
             REGISTERED. NC-REL-06 and NC-REL-08 measure the
             VALIDATOR, so nothing checked that the job which builds
             the artifact uploads it, or that the deploy job does not
             upload a directory it does not have -- the exact defect
             that was fixed earlier in the series. Removing the
             validation step from the workflow left every control
             green.
             Found by the independent critic.
    Fix:     the property is registered, and NC-REL-09 moves the
             upload from the build job to the deploy job, so the
             property really breaks.
    Proof:   9 of 9 controls are RED, and the registry carries only
             the gate properties, so every entry is really checked by
             the property it names.

### H-06 — the release controls imported yaml, and the CI installs no yaml

    Status:  PROVEN DEFECT — FIXED
    Found:   tools/release_negative_controls.py was the ONLY file in the
             repository that imported yaml, and NO workflow installs
             pyyaml. The step "Run the release negative controls"
             would have failed with an ImportError on the runner,
             which would have turned the REQUIRED battle-ecs job RED
             -- and a RED required job blocks the deployment. The
             defect would only have appeared on the real CI, never
             locally, because the development machine has pyyaml.
             Found by the independent critic.
    Fix:     the controls read the workflows with their own text
             reader, exactly like every other CI tool of the
             repository (the ledger validator, the exit-contract
             audit, the reachability audit and the three other
             negative-control harnesses all avoid yaml).
    Proof:   the controls were run under a python where importing yaml
             raises ImportError, exactly as on a bare runner: 25 of 25
             RED, exit 0. There is no "import yaml" anywhere in the
             repository now.

### H-05 — the settings UI is unreachable

    Status:  PROVEN DEFECT — NOT FIXED HERE (out of scope)
    Found:   `_settings_button` is DECLARED in
             scenes/main_menu/main_menu.gd and never created, so the
             "Battle Speed" panel cannot be opened. The commit that
             introduced the feature (ebb304c) claimed in its message
             that the Settings button opens the panel and never wrote
             that button.
    Scope:   this is a PRE-EXISTING defect, NOT a regression of this
             series: the same is true on master, and the panel is
             never exercised by any test, which is why it survived.
    Impact:  the setting itself WORKS -- `_set_speed()` writes
             `MetaProfile.battle_speed` through
             `SaveService.save_meta()`, and `battle_scene.gd` reads
             `profile.battle_speed` for the battle speed -- but the
             PLAYER cannot reach it.
    Verified: in the real browser the main menu carries only "New
             Run" and "Continue"; clicking every plausible spot opens
             no panel.
    Decision: adding the missing button is a UI FEATURE change, and
             this closure is an integration and staging-readiness
             pass, not a feature sprint. It is recorded here as an
             ACCEPTED RISK for the staging run and named as a
             separate follow-up.

### H-03 — the release negative controls proved nothing

    Status:  PROVEN DEFECT — FIXED
    Found:   the controls evaluated a decision function that read the
             workflow as TEXT. Every "RED" came from a rule that
             RECOGNISED the exact mutation text, so a genuinely broken
             deploy was reported as a PASS. The harness exited 0
             exactly when the controls were vacuous.
             Found by the independent critic, and it is the most
             important finding of this gauntlet.
    Fix:     the controls are STRUCTURAL: the workflows are parsed as
             data and each control asserts a property of the parsed
             graph. The accounting is inverted to the honest
             direction: a mutation that does NOT open the gate is a
             MISSED control and counts as a problem.
    Proof:   a genuinely broken deploy is now caught (RED), where the
             old harness reported a PASS.

### H-04 — the artifact validator accepted an incomplete export

    Status:  PROVEN DEFECT — FIXED
    Found:   a 4-byte WASM passed, and an artifact with no resource
             bundle passed. The WASM check only asked whether a
             filename contained ".wasm".
    Fix:     the WASM must be at least a megabyte with the
             WebAssembly magic bytes, and the resource bundle must
             exist and be at least 64 KB.
    Proof:   the measured verdicts: the full artifact PASS, and every
             incomplete variant DENY.

### H-02 — the release decision did not read the concurrency protection

    Status:  PROVEN DEFECT — FIXED
    Found:   the release DECISION FUNCTION never read the CONCURRENCY
             block. The stale protection had only ONE mechanism in the
             decision (the tip check), while the workflow has TWO (the
             per-branch concurrency group and the tip check). The
             NC-REL-07 mutation changed `cancel-in-progress`, so it
             could not change the verdict through that path -- and a
             control that cannot fail proves nothing.
             Found by the independent critic.
    Fix:     the decision derives both mechanisms: the group must be
             per ref, and a cancelled run must never reach the deploy
             job. The NC-REL-07 mutation removes the tip check as
             well, so the stale publication is really possible, and
             the control proves the mutated gate ALLOWs it while the
             clean gate denies it.
    Proof:   NC-REL-07 is RED. What it proves is exactly what its
             mutation breaks: the deploy job loses the checkout, so
             the tip check has no remote to read and the deployment
             HALDS instead of publishing. The tip check itself
             survives the mutation -- so the control does NOT claim
             that a stale publication becomes possible; it claims
             that the mechanism which refuses one cannot be removed
             unnoticed.

### H-01 — the A-H baseline would have compared nothing after the merge

    Status:  PROVEN DEFECT — FIXED
    Found:   the A-H differential took its baseline from HEAD^. After
             Phase 3 is merged into master, HEAD^ is the previous
             MASTER commit, and master carries NO A-H probe at all
             (verified: the probe file does not exist on master). The
             comparison would have been empty, and an empty
             comparison passes.
    Fix:     the baseline is PINNED to the published Phase 3 commit
             4316a32. The step verifies that the baseline carries the
             probe, and HOLDs (exit 1) when the baseline cannot be
             fetched. It never skips and never passes.
    Residual: the pinned baseline must stay reachable. It is a
              published commit, so it stays reachable.

## MEDIUM

### M-01 — the export path was relative

    Status:  PROVEN DEFECT — FIXED
    Found:   the web build exported to "build/index.html". On Windows
             Godot resolves a relative path against the editor's
             working directory, not against the project, and the
             export fails with "the target folder does not exist or is
             not accessible". The Linux CI could not see it.
    Fix:     the release workflow exports to an ABSOLUTE path.
    Proof:   a local clean export produced the full artifact.

### M-02 — a corrupt save is dropped, but the drop is not proved on every platform

    Status:  PROVEN BEHAVIOUR — CHARACTERIZATION ONLY
    Found:   the web build keeps user:// in IndexedDB. A corrupt
             meta.tres and run file were written there; after the
             reload the application loaded normally, the "Continue"
             button was gone and "New Run" still worked, with zero
             page errors.
    Residual: only the WEB runtime was exercised. The desktop and the
              headless runtimes are covered by the save suites, not
              by a browser. NOT VERIFIED UNTIL A REAL DEPLOYMENT.

### M-04 — the 88 .gd files without a tracked .uid

    Status:  OBSERVATION — NOT A BUILD DEPENDENCY
    Found:   the repository tracks 174 .uid files and every one of
             them has its source file. 88 .gd files have NO tracked
             .uid, and the 88 untracked .uid files in the working
             tree are exactly those files -- the comparison is empty
             in both directions.

             They are NOT all under core/battle_ecs/: 63 are under
             tests/, 19 under core/battle_ecs/ and 6 under other
             core/. And 13 of the 88 pre-date Phase 3 -- they were
             already missing a .uid on master.

             The shipping content references no uid:// path at all.
    Proof:   the CLEAN checkout -- tracked files only, no untracked
             .uid, no .godot, no build -- imported with ZERO errors
             and exported a complete artifact. index.html, index.js
             and index.wasm are byte-for-byte identical to the build
             of the working tree.
    Decision: the .uid files are a by-product of the import, not a
             dependency of the build. Adding the 88 would be a
             deliberate change to the repository's convention, and it
             is not done in a closure pass.

### M-03 — the local browser smoke did not reach two scenarios

    Status:  PARTIALLY CLOSED
    WEB-14 (TREASURE) is now VERIFIED in the real browser with the
    real WASM build: the production route was walked, the production
    handler applied the effect exactly once, the gold rose by the
    production constant (31 -> 36), the inventory gained one item, the
    meta profile gained one unlock, the checkpoint recorded the stable
    phase, and a reload restored everything. Re-selecting the
    treasure granted nothing twice.
    WEB-15 (settings) remains NOT VERIFIED: the UI is unreachable --
    see H-05.

## LOW

### L-01 — the build output was not ignored

    Status:  PROVEN DEFECT — FIXED
    The root build/ directory was untracked but not ignored, and the
    .gitignore comment claimed that docs/build/** is committed -- it
    was not. A committed Pages artifact could only ever be a stale
    one. Both directories are ignored now.

### L-02 — the html references were compared by basename

    Status:  PROVEN DEFECT — FIXED
    Found:   a reference to "subdir/index.js" passed when "index.js"
             sat at the root, so a broken reference would 404 in
             production while the validator reported PASS.
    Fix:     the check resolves the reference against the deployment
             root and refuses an absolute or an escaping reference.
    Proof:   the critic's exact scenario is DENY, and NC-REL-08 keeps
             it that way.

### L-03 — the reusable trigger had been reverted

    Status:  PROVEN DEFECT — FIXED
    Found:   a strict YAML audit (parse the workflows, assert the
             trigger block, the needs graph, the permissions and the
             concurrency) found that test.yml had lost its
             `workflow_call` trigger and its `contents: read`
             permission. The release workflow was calling a workflow
             that could not be called, and the CI would have failed.
             The cause was a `git reset --hard` from an earlier series,
             which reverted that change together with the unrelated
             restoration.
    Fix:     the trigger and the permission are restored and the YAML
             is parsed and asserted afterwards.

### L-04 — the .uid coverage of the repository is incomplete

    Status:  OBSERVATION — NOT A BUILD DEPENDENCY
    The MEASURED facts, which correct an earlier version of this
    register:

```
master            114 .uid over 128 .gd
phase 3           174 .uid over 262 .gd
the candidate     174 .uid over 262 .gd

the .gd files with NO tracked .uid at the candidate   88
  of those, ADDED by Phase 3                          75
  of those, already missing on master                  13
  where they are:  tests/ 63, core/battle_ecs/ 19, other core/ 6

the untracked .uid files in the working tree          88
  the same set as the 88, in both directions
```

    So the repository DOES track .uid files, and 59 of the 134
    scripts Phase 3 added came with one. The gap is 75 of them plus
    the 13 that were already missing on master.

    It is NOT a build dependency: the shipping content references no
    uid:// path (every .tres references its script by PATH), and the
    CLEAN checkout -- tracked files only, no untracked .uid, no
    .godot, no build -- imported with ZERO errors and exported a
    complete artifact whose html, js and wasm are byte-for-byte
    identical to the working tree build.

    Adding the 88 would be a deliberate change to the repository's
    convention, and it is not done in a closure pass.

## ACCEPTED

### A-01 — the historical NC matrix count differs from the published number

    The matrix declares 42 named controls and a run prints 44 result
    lines (the RNG pair is reported under two names). Measured against
    the base tree and the candidate tree with the SAME twelve scripts:
    the declared set is identical, nothing was lost, and the
    candidate has 44 RED with 0 SKIP and 0 INVALID. The base had
    three SKIPs because of drifted anchors, which the candidate
    resolves. This is an improvement, not a loss.

### A-02 — the A-H differential compares against a pinned baseline, not HEAD^

    A pinned baseline is stable: every release compares against the
    same known-good reference instead of drifting with the branch.
    The cost is that the baseline must be refreshed deliberately when
    the ECS semantics change. The release runbook names that step.

### A-03 — the legacy and the ECS combat systems both carry Shield Block

    The legacy view has its own id ("shield_block_legacy") and its own
    trigger name ("unit_attacked"); the ECS path resolves
    "shield_block" through the unit's reaction_ids and uses the
    Phase-3 event types. The two systems therefore cannot select the
    same reaction object, and neither path can apply the effect
    twice. The legacy "unit_move_start" AoO trigger was never polled
    by any legacy code, so the AoO was already dead on master: the
    Phase-3 resource is not a regression but the removal of a zombie
    registration.

### A-04 — the crash recovery, the exactly-once terminal awards and the atomic MetaProfile are still unproven

    They belong to the A0 Persistence Transaction Gauntlet, which this
    gauntlet does not start. If a public release needs them, that is a
    separate decision with its own gate.
