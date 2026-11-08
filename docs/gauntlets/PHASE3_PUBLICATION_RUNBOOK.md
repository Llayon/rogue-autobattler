# PHASE 3 PUBLICATION RUNBOOK

    A SEPARATE, AUTHORIZED publication of the Phase 3 work into master.
    Every stage below is a gate: when a stage fails, the publication
    STOPS. Nothing here has been executed yet.

## The candidate

    master            02fe83ef378d13965184c6224a512a91ae6263a1
    phase3            4316a32e210b8660b77a6eda916fb28c4f3bcb8a
    the candidate     1e23ab1
    branch            integration/phase3-master-release-rehearsal
    the merge-base    02fe83ef (== master: a strict fast-forward)
    ahead / behind    0 / 289
    the commits       15 over the published Phase 3, 289 over master

    The candidate SHA moves with every commit of the series. Read it
    from the repository at the moment of the publication; do NOT copy
    it from a document.

## Stage 1 — FREEZE

    1. Record the source SHA:
         git -C <worktree> rev-parse HEAD
       The value MUST equal the SHA named in the authorization.
    2. Verify the worktree is clean:
         git -C <worktree> status --porcelain --untracked-files=no
       The output MUST be empty.
    3. Verify the remote base is UNCHANGED:
         git ls-remote canonical refs/heads/master
       The value MUST be 02fe83ef378d13965184c6224a512a91ae6263a1.
       A different value means master moved: STOP, re-evaluate the
       merge-base, and re-run the whole rehearsal.
    4. Verify there is no unexpected divergence:
         git -C <worktree> rev-list --left-right --count master...HEAD
       The left number MUST be 0.
    5. Verify the protected refs are untouched:
         git ls-remote canonical refs/heads/master
         git ls-remote origin  refs/heads/master
         git worktree list
       Record the values. They must not change during the publication.

## Stage 2 — PRE-MERGE VERIFICATION

    1. Show the diff:
         git -C <worktree> diff --stat 02fe83ef..HEAD
         git -C <worktree> diff 02fe83ef..HEAD -- .github/workflows/
       The workflow diff MUST show the release workflow, the reusable
       test workflow and the removal of the ungated web build.
    2. Verify the required CI on the candidate. The CI must be GREEN on
       the candidate SHA itself:
         python tools/run_battle_ecs_suites.py --godot <godot> --root .
         python tools/release_negative_controls.py
         python tests/ci/standalone_runner_test.py
         python tests/ci/ah_differential_test.py
         python tools/negative_controls.py
         python tests/ci/ledger_validator_test.py
       Every one must exit 0.
    3. Verify the Web export readiness:
         python tools/validate_web_artifact.py <the build directory>
       The validation must PASS.
    4. Verify the Pages restrictions. NOT VERIFIED UNTIL REMOTE CI /
       DEPLOYMENT:
       - the `github-pages` environment exists and its protection rules
         are understood;
       - the environment's deployment branch rule accepts master;
       - the Pages source is set to "GitHub Actions".

## Stage 2b — THE STAGING RUN (the safe first step)

    The staging branch exists so that the REAL GitHub Actions can be
    exercised WITHOUT any risk of a Pages publication.

    The structural guarantee, verified locally:

```
.github/workflows/release.yml   push:  branches: [master]
.github/workflows/test.yml      push:  every branch
                                pull_request, workflow_call
```

    A push to the staging branch therefore starts the test workflow:
    save-battle-migration, battle-ecs and the release negative
    controls. It does NOT start the release workflow, so the Pages
    deployment cannot happen.

    The command, once the owner authorizes it:

         git -C <worktree> push canonical \
             HEAD:refs/heads/staging/phase3-master-release-rehearsal

    A NEW branch, so no force, no rebase and no reset are involved.
    The pre-push gate is the same as the one below: the source SHA,
    the clean worktree, the diff --check, the merge-base and the
    ahead/behind.

    What the run must show, and what it must NOT show:

```
battle-ecs              success
save-battle-migration   success
the standalone runner   GREEN
the A-H differential    PASS
the release controls    8/8 semantic RED
the Pages deployment    NOT TRIGGERED
```

    The Pages deployment NOT being triggered is a POSITIVE result of
    the staging run: it proves the branch filter holds.

## Stage 3 — INTEGRATION

    The strategy is a FAST-FORWARD, because the merge-base IS master:

         git -C <worktree> push canonical HEAD:refs/heads/master

    Rules:
    - NO --force, NO --force-with-lease, NO rebase, NO reset;
    - NO merge commit: the history of Phase 3 stays exactly as it is;
    - the pushed ref is master, and ONLY master;
    - the push happens from the frozen SHA of Stage 1: if HEAD moved,
      STOP and re-freeze.

    Why a fast-forward and not a merge commit: the candidate's
    merge-base is master itself, so a merge would add an empty merge
    commit and hide the fact that the history is linear.

## Stage 4 — POST-MERGE CI

    1. Confirm the master SHA:
         git ls-remote canonical refs/heads/master
       It MUST equal the frozen candidate SHA.
    2. Confirm BOTH required jobs succeeded on that SHA:
         gh run list -R Llayon/rogue-autobattler --branch master --limit 3
       The run must be `completed / success` with BOTH `battle-ecs`
       and `save-battle-migration` successful.
    3. Confirm the release workflow ran on the SAME SHA and that its
       web build succeeded. The A-H baseline must have resolved: if
       the A-H step HOLDs, the publication stops here.
    4. Confirm the other refs are untouched:
         git ls-remote canonical refs/heads/phase3/effect-status-trigger-gauntlet
         git ls-remote origin refs/heads/master

## Stage 5 — DEPLOYMENT

    The deployment is NOT a separate manual action: the release
    workflow performs it after the required jobs succeeded. The gates
    inside the workflow are:

      - both required jobs successful;
      - the artifact validation passed;
      - the built SHA == the deployed SHA;
      - the published SHA == the tip of master.

    Verify after the deployment:
         gh run view <the release run id> -R Llayon/rogue-autobattler
       The deploy job must be successful and must report the Pages URL.
       Fetch that URL and check it answers 200.

## Stage 6 — POST-DEPLOY SMOKE

    Run the browser smoke against the REAL Pages URL, not against a
    local server. The scenarios are the ones in
    docs/gauntlets/LOCAL_WEB_SMOKE.md, minus the two that were not
    reached (WEB-14 TREASURE, WEB-15 settings) and plus them:

      WEB-14  reach a TREASURE node and take the item reward
      WEB-15  reach the settings and change a value
      WEB-01  the page loads, the canvas appears
      WEB-12  the merchant SPACE closes the shop and starts NO battle
      WEB-16  a reload offers Continue and restores the run
      WEB-17  a corrupt save does not trap the application
      WEB-18  zero fatal JavaScript errors

    This is the LIVE PAGES SMOKE. The local smoke does NOT substitute
    for it.

## Stage 7 — FAILURE HANDLING

    On a failed CI or a failed deployment:

        HOLD
        NO FALSE SUCCESS
        NO FORCE PUSH
        NO AUTOMATIC ROLLBACK TO AN UNVERIFIED ARTIFACT

    A rollback is a SEPARATE, CONTROLLED action: it gets its own
    authorization and it re-runs the whole CI. The backward
    compatibility of the old user saves is NOT a condition of such a
    rollback: the pre-release save policy does not guarantee it.

    If the failure is in the A-H baseline, the fix is to re-point the
    pinned baseline -- never to skip the comparison.

## The A-H baseline, deliberately

    The A-H differential compares the candidate against the PINNED
    Phase 3 commit 4316a32, not against HEAD^. After the merge into
    master, HEAD^ is the previous master commit, which carries no A-H
    probe at all: the comparison would have been empty, and an empty
    comparison passes.

    When the ECS semantics change deliberately, refresh the pin in
    .github/workflows/test.yml in the SAME commit as the semantic
    change, and re-run the differential locally before the merge.
