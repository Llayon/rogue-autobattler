# PHASE 3 STAGING PUBLICATION REPORT

    The dated supplement to PHASE3_PUBLICATION_RUNBOOK.md.
    NOT COMMITTED: this file is prepared for the owner to review and
    to decide whether it is committed later.

```
Repository:            Llayon/rogue-autobattler
Source branch:         integration/phase3-master-release-rehearsal
Authorized SHA:        f42e68ed8d671a022e3f77b8984fe6e3a4afeec4
Remote staging branch: staging/phase3-master-verification
Remote staging SHA:    f42e68ed8d671a022e3f77b8984fe6e3a4afeec4
```

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
      32 commits over the published Phase 3
      305 commits over master
      0 merge commits in the series

    remote state
      canonical/master   02fe83ef378d13965184c6224a512a91ae6263a1
      canonical/phase3   4316a32e210b8660b77a6eda916fb28c4f3bcb8a
      neither had changed

    staging safety
      the destination did not exist: refs/heads/staging/* was empty
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
        f42e68ed8d671a022e3f77b8984fe6e3a4afeec4:refs/heads/staging/phase3-master-verification

    exit code      0
    output         * [new branch] f42e68e -> staging/phase3-master-verification
    remote SHA     f42e68ed8d671a022e3f77b8984fe6e3a4afeec4  (identical)
    no --force, no extra refspec, no push to master or Phase 3

## REMOTE CI

    run ID          42474970253
    URL             https://github.com/Llayon/rogue-autobattler/actions/runs/42474970253
    head SHA        f42e68ed8d671a022e3f77b8984fe6e3a4afeec4
    branch          staging/phase3-master-verification
    event           push
    status          completed
    conclusion      success

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
    audits         the exit-contract audit: PASS -- every non-zero
                   quit cannot fall through to quit(0)
                   the reachability audit: PASS -- every declared
                   _test_* function is reachable
    release NC     NC-REL-01 .. NC-REL-10: 10 of 10 semantic RED
                   0 SKIP, 0 INVALID
                   release controls: 10, clean: 10, problems: 0

    The release controls ran on the RUNNER, where pyyaml is absent.
    That is the proof that the yaml dependency is really gone: the
    step would have failed with an ImportError if it were still
    there.

    NOTE: the run above is the REAL REMOTE EVIDENCE for the staging
    candidate f42e68e, and it ran the controls AS THEY WERE AT THAT
    SHA -- ten of them. The branch authorization work that followed
    added seventeen more, and those twenty seven have run LOCALLY only. A
    republication of the fixed candidate is what would make them
    REMOTE VERIFIED.

## SAVE/BATTLE MIGRATION

    the job        save-battle-migration | completed | success
    every step     completed | success (14 steps)

    Godot parse, lint, the legacy regression suite, the legacy
    characterization suite (3 runs, identical), the legacy save
    fixture loader, the save schema v4 suite, the save schema v4
    byte-for-byte determinism, the production save repository suite,
    the RunSaveFileOps suite and the RunUnit is_alive suite.

    No step failed. Nothing was deleted.

## DEPLOYMENT

    the release workflow triggered?          NO
    the GitHub Pages deployment triggered?   NO
    the staging SHA deployed?                NO

    The evidence:
      the only workflow run for the staging SHA is 42474970253, the
      "Save and Battle Migration" workflow
      no deployment event carries the staging SHA: every deployment
      on the repository is from master, the newest from 2026-09-11
      the github-pages environment was last updated 2026-08-02
      the repository's own web-build.yml (still on master) has
      on: push: branches: [master], so the staging push never
      reached it either

## PROTECTED REFS

    canonical/master   02fe83ef378d13965184c6224a512a91ae6263a1   UNCHANGED
    canonical/phase3   4316a32e210b8660b77a6eda916fb28c4f3bcb8a   UNCHANGED
    all 20 worktrees   on their previous SHAs
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

    Pre-release saves
      The backward compatibility of the old user save formats is not
      a requirement, and nothing was migrated for it.

## FINAL VERDICT

```
PHASE 3 STAGING PUBLICATION
= PUBLISHED / REMOTE CI GREEN

MASTER:
UNCHANGED

GITHUB PAGES:
NOT DEPLOYED

READY FOR:
MASTER RELEASE AUTHORIZATION REVIEW
```
