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
    Proof:   tools/release_negative_controls.py — NC-REL-01..07, all
             semantic RED; the clean gate ALLOWs the good scenario
             only.
    Residual: the GitHub Pages environment restrictions are NOT
              verified locally: NOT VERIFIED UNTIL REMOTE CI /
              DEPLOYMENT.

## HIGH

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
    Proof:   NC-REL-07 is RED, and the clean gate denies the stale
             scenario.

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

### M-04 — the 88 .gd files of Phase 3 have no tracked .uid

    Status:  OBSERVATION — NOT A BUILD DEPENDENCY
    Found:   the repository tracks 174 .uid files and every one of
             them has its source file. The 88 .gd files that Phase 3
             added under core/battle_ecs/ have NO tracked .uid, and
             the 88 untracked .uid files in the working tree are
             exactly those files. The shipping content references no
             uid:// path at all.
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

### L-04 — the .uid files are not tracked

    Status:  OBSERVATION — NOT A DEFECT
    The base tracks no .uid file at all (0 of 128 .gd files), and the
    134 .gd files Phase 3 added have no .uid either. They are Godot
    import artifacts, generated on import, and the CI import step
    regenerates them. The 88 that appeared in the worktree were left
    untracked on purpose.

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
