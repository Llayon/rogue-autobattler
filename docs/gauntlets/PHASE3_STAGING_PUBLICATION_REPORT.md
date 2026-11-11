# PHASE 3 STAGING PUBLICATION REPORT

    The dated supplement to PHASE3_PUBLICATION_RUNBOOK.md.

    This file records TWO staging publications of the same branch.
    The first is historical; the second is the current evidence and
    the one that supersedes the first. They are kept apart on
    purpose: the first publication proved that a staging push does
    NOT publish, and the second publication carries the branch
    authorization fix -- the whole release gate -- so its release
    controls are the ones that matter.

```
Repository:            Llayon/rogue-autobattler
Source branch:         integration/phase3-master-release-rehearsal
Authorized SHA:        12dfcdac0046480267e0e10101080531aeb51937
Remote staging branch: staging/phase3-master-verification
Remote staging SHA:    12dfcdac0046480267e0e10101080531aeb51937
```

## THE TWO PUBLICATIONS

```
    FIRST    f42e68ed8d671a022e3f77b8984fe6e3a4afeec4
             run 42474970253  ->  success
             the release gate was NOT yet fixed: the controls that
             ran were ten of them, and the branch authorization work
             that followed had only run LOCALLY.

    SECOND   0ed62296b123055e2f989064fa04cee354f9d098
             run 42867465947  ->  success
             the release gate IS fixed: thirty-five controls, all of
             them REMOTE VERIFIED on the runner.

    THIRD    40dd321e4a9b6e28b31ef294c589a6c5140c411e
             run 42992906605  ->  success
             the F6 external harness verification: thirty-six
             controls, and the EXTERNAL VERIFIER that proves the
             release controls still refuse a real defect. Both
             REMOTE VERIFIED on the runner.

    FOURTH   12dfcdac0046480267e0e10101080531aeb51937
             run 43024131213  ->  success
             the SETTINGS UI HOTFIX: the main menu's Settings button
             is created, the panel is inside the menu's layout, and
             the speed survives a reload. The new suite ran on the
             runner: 48 pass / 0 fail.
```

    The second publication is a FAST-FORWARD over the first: the
    first staging SHA is an ancestor of the second, so no history was
    rewritten and no force was used.

## THE THIRD PUBLICATION -- THE F6 VERIFICATION

    Authorized SHA   40dd321e4a9b6e28b31ef294c589a6c5140c411e
    Run              42992906605  ->  success
    URL              https://github.com/Llayon/rogue-autobattler/actions/runs/42992906605

    The push was a FAST-FORWARD over the second staging SHA
    b14cdb2 (an ancestor of the local HEAD), so no history was
    rewritten and no --force was used. The protected refs did not
    move: master 02fe83ef and Phase 3 4316a32 are UNCHANGED.

    WHAT THE RUN PROVED, ON THE RUNNER:
      120 of 120 suites, 9174 assertions, 0 fail, 0 unparsed
      release controls: 36, clean: 36, problems: 0
        -- and pyyaml is ABSENT on the runner, so the yaml
           dependency is really gone
      THE EXTERNAL VERIFICATION: PASS
        the harness declares 36 controls
        CLEAN HARNESS      (36, 36, 0)  PASS
        NO-OP HARNESS      DETECTED -- it accepted a defect it
                           must refuse
        FAKE-GREEN HARNESS DETECTED -- it accepted a defect it
                           must refuse
        REAL DEFECT        (36, 29, 7)  DETECTED -- the real
                           harness refuses it
      A-H SEMANTIC DIFFERENTIAL: PASS (8 fixtures)
      CI-01: 13, failed: 0; CI-02: 20, failed: 0
      the ledger validator's controls: 7, clean: 7
      the standalone runner's: 3; the A-H differential's: 5;
      the battle entry's: 5 -- all clean

    Every step of the battle-ecs job is green, including the new
    one: "Verify the release harness from outside".

    WHAT THE RUN DID NOT DO:
      it did not deploy. The release workflow does not react to a
      staging branch, no deployment event carries the staging SHA,
      and the github-pages environment was last updated 2026-08-02
      -- before the push.

## THE FOURTH PUBLICATION -- THE SETTINGS UI HOTFIX

    Authorized SHA   12dfcdac0046480267e0e10101080531aeb51937
    Run              43024131213  ->  success
    URL              https://github.com/Llayon/rogue-autobattler/actions/runs/43024131213

    The push was a FAST-FORWARD over the third staging SHA e71b68e
    (an ancestor of the local HEAD), so no history was rewritten and
    no --force was used. The protected refs did not move: master
    02fe83ef and Phase 3 4316a32 are UNCHANGED.

    WHAT THE RUN PROVED, ON THE RUNNER:
      121 of 121 suites, 9222 assertions, 0 fail, 0 unparsed
      release controls: 36, clean: 36, problems: 0
      THE EXTERNAL VERIFICATION: PASS
      A-H SEMANTIC DIFFERENTIAL: PASS (8 fixtures)
      CI-01: 13, failed: 0; CI-02: 20, failed: 0
      the ledger validator's controls: 7, clean: 7
      the standalone runner's: 3; the A-H differential's: 5;
      the battle entry's: 5 -- all clean
      the SETTINGS suite itself, on the runner:
        [OK] tests/run_domain/main_menu_settings_test.gd
              -- 48 pass / 0 fail

    WHAT THE RUN DID NOT DO:
      it did not deploy. The release workflow does not react to a
      staging branch, no deployment event carries the staging SHA,
      the Pages deployments list is empty, and the github-pages
      environment was last updated 2026-08-02 -- before the push.

## PRE-PUSH

    identity
      the remote `canonical` -> https://github.com/Llayon/rogue-autobattler.git
      the remote `origin`   -> https://github.com/Llayon/rogue-autobattler2.git
      The push used `canonical`. The remote `origin` is a DIFFERENT
      repository and was not touched. Every `gh` call carried
      `-R Llayon/rogue-autobattler`.

    clean tree
      TRACKED_CLEAN / NO_DIFF / DIFF_CHECK_CLEAN
      88 untracked .uid files: the import by-products audited in the
      pre-publication closure. They are not part of the publication
      and are not a dependency of the build.

    ancestry
      merge-base(master, HEAD)   == 02fe83ef378d13965184c6224a512a91ae6263a1
      merge-base(4316a32, HEAD)  == 4316a32e210b8660b77a6eda916fb28c4f3bcb8a
      140 commits over the published Phase 3
      413 commits over master
      0 merge commits in the series

    remote state
      canonical/master   02fe83ef378d13965184c6224a512a91ae6263a1
      canonical/phase3   4316a32e210b8660b77a6eda916fb28c4f3bcb8a
      neither had changed

    fast-forward
      the remote staging SHA was f42e68e, an ancestor of the local
      HEAD: FAST_FORWARD_YES
      ahead 108 / behind 0
      so the push needed no --force and no history rewrite

    staging safety
      test.yml:    on: push (no branch filter) -> it reacts to the
                   staging push
      release.yml: on: push: branches: [master] -> it does NOT react
      the deploy job needs [required-tests, web-build]
      pages: write and id-token: write only on the deploy job
      no always(), no continue-on-error
      workflow_dispatch has no input and runs the same gate

## PUSH

    command
      git push canonical \
        0ed62296b123055e2f989064fa04cee354f9d098:refs/heads/staging/phase3-master-verification

    exit code      0
    output         f42e68e..0ed6229  0ed6229 -> staging/phase3-master-verification
    remote SHA     0ed62296b123055e2f989064fa04cee354f9d098  (identical)
    no --force, no extra refspec, no push to master or Phase 3

    POST-PUSH VERIFICATION
      REMOTE_EQ_LOCAL          the remote SHA equals the local HEAD
      ahead/behind             0 / 0
      TRACKED_CLEAN            the local tree was not touched by the push
      DIFF_CHECK_CLEAN
      canonical/master         02fe83ef... UNCHANGED
      canonical/phase3         4316a32e... UNCHANGED

## REMOTE CI

    run ID          42867465947
    URL             https://github.com/Llayon/rogue-autobattler/actions/runs/42867465947
    head SHA        0ed62296b123055e2f989064fa04cee354f9d098
    branch          staging/phase3-master-verification
    event           push
    status          completed
    conclusion      success

    The run carried the FIXED candidate, so its release controls are
    the ones that matter: thirty-five of them, and every one of them
    RED.

## BATTLE ECS

    the job        battle-ecs | completed | success
    every step     completed | success (16 steps)

    suites         expected 120 / executed 120 / passed 120
                   failed 0 / unparsed 0
    assertions     9174 pass / 0 fail
    runner         RUNNER: GREEN

    A-H            A-H SEMANTIC DIFFERENTIAL: PASS (8 fixtures,
                   legacy-projected traces + world + rng + emitter +
                   result all identical)
                   the baseline is PINNED to 4316a32; the pinned
                   baseline carries the A-H probe, and an unreadable
                   baseline HOLDs instead of skipping.

    CI self-tests  CI-01: 13, failed: 0
                   CI-02: 20, failed: 0
    ledger         the ledger validated; the ledger validator's
                   negative controls: 7, clean: 7, problems: 0
    other NC       the standalone runner's: 3, clean: 3, problems: 0
                   the A-H differential's: 5, clean: 5, problems: 0
                   the battle entry's: 5, clean: 5, problems: 0
    audits         the exit-contract audit: PASS -- every non-zero
                   quit cannot fall through to quit(0)
                   the reachability audit: PASS -- every declared
                   _test_* function is reachable
    release NC     release controls: 35, clean: 35, problems: 0

    The release controls ran on the RUNNER, where pyyaml is absent.
    That is the proof that the yaml dependency is really gone: the
    step would have failed with an ImportError if it were still
    there. The log carries no "No module named 'yaml'" line at all.

    The control COUNT is read from the repository, not written here,
    so it cannot go stale:

        python -c "import sys; sys.path.insert(0, 'tools'); \
          import release_negative_controls as nc; print(len(nc.MUTATIONS))"

## SAVE/BATTLE MIGRATION

    the job        save-battle-migration | completed | success
    every step     completed | success (14 steps)

    Godot parse, lint, the legacy regression suite, the legacy
    characterization suite (3 runs, identical), the legacy save
    fixture loader, the save schema v4 suite, the save schema v4
    byte-for-byte determinism, the production save repository suite,
    the RunSaveFileOps suite and the RunUnit is_alive suite.

    No step failed. Nothing was deleted.

    The runner's own annotations, neither of which blocks anything:
      actions/checkout@v4 targets Node.js 20 and is forced onto
      Node.js 24
      the ubuntu-latest label migrates to Ubuntu 26 on 2026-10-19

## DEPLOYMENT

    the release workflow triggered?          NO
    the GitHub Pages deployment triggered?   NO
    the staging SHA deployed?                NO

    The evidence:
      the only workflow run for the staging SHA is 42867465947, the
      "Save and Battle Migration" workflow
      no deployment event carries the staging SHA
      the github-pages environment was last updated 2026-08-02 --
      BEFORE this push, so the push did not touch it
      the repository's own web-build.yml (still on master) has
      on: push: branches: [master], so the staging push never
      reached it either
      no pull request was created

## PROTECTED REFS

    canonical/master   02fe83ef378d13965184c6224a512a91ae6263a1   UNCHANGED
    canonical/phase3   4316a32e210b8660b77a6eda916fb28c4f3bcb8a   UNCHANGED
    all worktrees      on their previous SHAs
    no pull request was created
    no unplanned commit, merge or push

## KNOWN LIMITATIONS

    Settings UI
      The Settings button is declared and never created, so the panel
      cannot be opened. It is a PRE-EXISTING master defect. The
      setting itself works and is persisted.
      ACCEPTED FOR STAGING / OPEN FOR RELEASE

    A0 crash recovery
      The crash recovery, the atomic MetaProfile and the
      exactly-once terminal awards are not proved. That is A0, and
      A0 was not started.

    Pages production verification
      What the staging run proves is that a staging push does NOT
      publish. It does NOT prove that the future master publication
      is safe: the release pipeline has never run on the real
      runner, and the Pages environment restrictions have never been
      exercised.
      NOT YET REMOTE VERIFIED

    The old publisher on master
      The repository's own .github/workflows/web-build.yml is still
      on master, and it is an UNGATED publisher. The candidate
      deletes it, but the deletion lands only at the merge. Until
      then the hole is open ON MASTER, not on this branch.
      OPEN ON MASTER / CLOSED IN THE CANDIDATE

    The self-certifying harness
      The release controls cannot certify themselves: an edit that
      makes a property return [], drops a property from the registry,
      or calls sys.exit(0) early is invisible from inside them.
      That is INHERENT to a self-certifying harness, not a defect of
      this candidate. It can be closed only EXTERNALLY -- a separate
      script that reads the harness as text and asserts its
      structural invariants, a committed digest compared by CI, or a
      CI job that runs the harness from a pinned ref.
      INHERENT / NOT CLOSED

    Pre-release saves
      The backward compatibility of the old user save formats is not
      a requirement, and nothing was migrated for it.

## FINAL VERDICT

```
PHASE 3 STAGING PUBLICATION
= PUBLISHED / REMOTE CI GREEN

THE RELEASE GATE:
REMOTE VERIFIED -- 35 of 35 release controls RED on the runner,
without pyyaml

MASTER:
UNCHANGED

GITHUB PAGES:
NOT DEPLOYED

READY FOR:
MASTER RELEASE AUTHORIZATION REVIEW
```
