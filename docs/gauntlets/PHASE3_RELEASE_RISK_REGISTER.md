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
             The GATE controls mutate the workflows and assert a
             property of the parsed result; the count is read from the
             repository, not written here:

                 python -c "import sys; sys.path.insert(0, 'tools'); \
                   import release_negative_controls as nc; \
                   print(len(nc.MUTATIONS), len([m for m in nc.MUTATIONS \
                   if m[0] not in ('NC-REL-06', 'NC-REL-08')]))"

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
             every control is RED.
             The matrix: push master ALLOW, manual master ALLOW,
             manual staging/phase3/feature/tag/pull_request/schedule
             DENY, a failed required job DENY.

### H-43 — the self-certifying harness, and its external verification

    Status:  PROVEN LIMITATION — CLOSED EXTERNALLY
    Found:   the fifteenth reviewer named the limit the nineteenth
             confirmed: "the harness cannot certify ITSELF". An edit
             that makes a property return [], drops a property from
             the registry, or calls sys.exit(0) early is INVISIBLE
             from inside the harness — the properties are what the
             edit disabled.

             The nineteenth reviewer accepted the principle as
             inherent, and named the three external shapes that can
             close it. The first one — a separate script that reads
             the harness as TEXT and asserts its structural
             invariants — was chosen, and done BEHAVIOURALLY rather
             than textually.

    Fix:     commit bc150d7 — tests/ci/release_harness_external_test.py.
             The trust boundary is now:

                 REAL RELEASE HARNESS
                         |
                         v
                 EXTERNAL BEHAVIOURAL VERIFICATION
                         |
                         v
                 PASS / FAIL

             The verifier does NOT import the harness, and does not
             use its parser, its table of properties, its verdict
             logic, or its output as the source of truth. It runs the
             harness as an EXECUTABLE, against a fixture it controls.

             The seam needs no change to the harness: the harness
             resolves every path from its own __file__, so a copy
             placed in <tmp>/tools/ reads <tmp>/.github/workflows/ —
             the fixture — and never the repository's workflows.

             The four scenarios:
               CLEAN HARNESS        passes, with a non-empty set
               NO-OP HARNESS        detected — the main path does
                                     no work at all
               FAKE-GREEN HARNESS   detected — the controls run and
                                     the verdicts are discarded, and
                                     a plausible summary is printed
               REAL DEFECT          the real harness refuses an
                                     inverted master-tip comparison

             The last one is the load-bearing. The no-op and the
             fake-green harness are INDISTINGUISHABLE from the real
             one by their exit code and their summary line: both
             print "release controls: 35, clean: 35, problems: 0" and
             exit 0. So a verifier that checked only the exit code
             and the summary would certify a harness that checks
             nothing. The verifier asks the question the summary
             cannot answer: does the harness REFUSE a defect it must
             refuse?

    Proof:   the four scenarios are confirmed by running the
             verifier; the CI step is in battle-ecs, right after the
             release controls, with no condition, no error tolerance
             and no shell escape; and NC-RB-26 proves that the step
             cannot be deleted from the required job.

    LIMIT:   the verifier cannot certify ITSELF either. An edit that
             makes it always pass is invisible from inside it, and
             an edit of the harness AND the verifier AND the workflow
             that runs them is undetectable by any single test. That
             is the accepted limit: the protection is demonstrated
             against the TYPICAL disabling — a neutered or
             always-green harness — not against a coordinated edit of
             the whole trust boundary. A further chain of "a test for
             the test for the test" is explicitly out of scope.

    MEASURED: the verifier's own size is 236 code lines against a
             100-200 target and a 250 hard limit, it imports only the
             standard library, and it touches nothing of the harness's
             internals: its references to PROPERTIES, MUTATIONS,
             load_jobs, load_text, run_control and _tokenize are all
             zero.

             The four scenarios were confirmed by RUNNING the
             verifier against a neutered production harness in an
             isolated copy, and the attacks were confirmed against
             the verifier itself:
               the harness inverts the verdict        -> CAUGHT
               the harness prints to stderr           -> CAUGHT
               the harness recognises the fixture
               tree and behaves there                -> CAUGHT
               the harness runs one control and
               fakes the count                       -> CAUGHT
               the harness behaves only in the
               temporary tree                         -> CAUGHT
             In every case the verifier's exit code was 1, so the CI
             job fails and the deployment does not happen.

    NOTE:   the task's expected figure of "44 RED" for the
             historical negative controls does not match the
             repository. The measured counts are:
               tools/negative_controls.py        14
               tools/ci_negative_controls.py      3
               tools/ah_negative_controls.py      5
               tools/entry_negative_controls.py   5
               ------------------------------------------
               the historical negative controls   27
             and the release controls are 36. The counts are read
             from the repository, never written by hand.

### H-42 — the shell lexer gets a unit test of its own

    Status:  PROVEN DEFECT — FIXED
    Found:   the nineteenth reviewer named the reason three classes of
             hole survived in the lexer: "the lexer has no unit test of
             its own".

             Every rule in this harness is tested by MUTATING the
             workflow -- but the lexer that reads the shell was only
             ever tested through the workflow, so a hole in it was
             invisible. Three classes of hole lived there: the token
             in a quoted string, the backgrounded and the piped
             refusal, and the refusal in the DATA of a here-document
             or a continued string.

    Fix:     commit 73eacea -- the lexer is tested DIRECTLY, against
             a table of seventeen shell snippets with the expected
             verdict for each, and the property also checks that the
             WORKFLOW's own refusals -- every condition of the tip
             check and of the master check -- are read as refusals.
             Every entry of the table was verified with real bash
             under the platform's own shell.
    Proof:   the controls are 35 of 35 RED, with and without pyyaml.

    THE PRINCIPLE, ANSWERED:
      the harness cannot certify ITSELF -- an edit that makes a
      property return [], deletes a property, or calls sys.exit(0)
      early is invisible from inside it. That is INHERENT, and it is
      not a reason to hold the branch. It can be closed only
      EXTERNALLY, and the shapes are:

        * a separate script that reads the harness as TEXT and asserts
          its structural invariants -- every prop_* registered, the
          mutation registry and the property registry equal, MUTATIONS
          covering every property, no sys.exit(0) before the
          summary, and the summary's count matching the registry;
        * a committed DIGEST of the harness, compared by CI, so any
          edit to the harness requires a deliberate, visible update;
        * a CI job that runs the harness from a DIFFERENT file -- a
          copy restored from a pinned ref -- so the harness under
          test cannot rewrite its own judge.

      Without one of these the harness's GREEN is a statement about
      the harness as written, not about the workflow. The first shape
      is the cheapest and the most local.

### H-41 — the nineteenth review: a refusal must be a command the shell RUNS

    Status:  PROVEN DEFECT — FIXED
    Found:   the nineteenth reviewer confirmed every earlier closure
             and then found five more ways to hide a refusal from the
             lexer -- and a sixth, a false red. All six were
             reproduced with real bash under the platform's own shell;
             in the five openings the publication was reached with
             rc=0:

               a HERE-DOCUMENT -- "cat <<'HOLD' ... exit 1 ... HOLD":
                 the body is DATA handed to the command's stdin, and
                 the cat PRINTS it.
               a MULTI-LINE quoted string -- the quote state was
                 reset for every line, so the second line's "exit 1"
                 looked like a command.
               a CONTINUATION line -- "echo \"HOLD\" \\" then
                 "exit 1": the backslash continues the echo, so the
                 exit is an ARGUMENT to it.
               a CONDITIONAL refusal -- "true || exit 1" and "false
                 && exit 1": the exit is only one branch of a list.
               a refusal NESTED in a condition that never holds --
                 "if false; then exit 1; fi".

               and a FALSE RED: the tip was cut on the NEXT line,
                 and the reader required the cut line to mention the
                 same variable -- so a value read into one variable
                 and cut into another was invisible, and the rule
                 rejected a legal edit in the required CI job.

    Fix:     commits cda5753 and db0e87f -- the harness now knows
             what a shell reader must know: which lines are DATA
             (here-documents, continued strings, continued commands,
             the body of a never-true condition), which commands are
             CONDITIONAL (a list's branch, a nested condition), and
             which are merely an ARGUMENT. A refusal must be a
             command the shell RUNS, on the path the shell TAKES.
    Proof:   the controls are 34 of 34 RED, with and without pyyaml;
             six openings are caught and four legitimate forms pass
             clean.

### H-40 — the boolean literal is a YAML boolean

    Status:  PROVEN DEFECT — FIXED
    Found:   the twelfth reviewer's battery, replayed by the
             nineteenth, caught a spelling the harness had not
             learned: "if: False".

             The boolean literal is a YAML boolean, so the capital
             spelling is exactly as disabling as the lower-case one.
             But the tokenizer keeps the spelling and the model
             compared it with the lower-case one -- so the capital
             spelling of the DISABLING boolean was invisible, and a
             step disabled with "if: False" was CERTIFIED.

             The same class as the quoted keys: the value is read as a
             YAML boolean, in every spelling.

    Fix:     commit 2cc6f8b -- the boolean literal is normalised
             before it is evaluated, and all three spellings
             ("false", "False", "FALSE") are caught, at the step
             level and at the job level.
    Proof:   the controls are 34 of 34 RED, with and without pyyaml.

    NOTE:   the other five MISSED cases of that battery are the
             twelfth reviewer's own CONTROL PROBES -- cases the
             author marked as probes, not as openings -- and three
             legitimate forms (the trailing space on the step's name,
             the trailing comment on the tip read, the permissions in
             the flow-mapping and quoted forms) that the harness now
             accepts.

### H-39 — the lexer must see every REAL refusal

    Status:  PROVEN DEFECT — FIXED
    Found:   the new shell lexer recognised the openings but not every
             REAL refusal, so a legal edit was a false red in the
             required CI job. Four forms were verified with real bash
             -- each of them exits non-zero, so each of them IS a
             refusal:

               ( exit 1 )     a subshell: its non-zero status is the
                              parent's.
               { exit 1; }    a brace group: it runs in the current
                              shell, so the exit ends the step.
               exit -1        bash turns a negative code into 255 --
                              still a refusal (exit +1 is the
                              explicit form).
               exec exit 1    replaces the shell with the exit, so the
                              step's status is the exit's.

    Fix:     commit 5684540 -- a GROUP carries the commands of its own
             body, the exit's CODE is read wherever the word sits in
             the command, and a signed code counts.
    Proof:   the controls are 34 of 34 RED, with and without pyyaml;
             four openings fail closed and four legitimate refusals
             pass clean.

### H-38 — the eighteenth review: the token must be a COMMAND

    Status:  PROVEN DEFECT — FIXED
    Found:   the eighteenth reviewer proved that the SEVENTEENTH
             reviewer's class was not closed. The refusal check looked
             for the PRESENCE of the token "exit", and three ways the
             token was there and the refusal was harmless all slipped
             through. All three reproduced with real bash under the
             platform's own shell:

               (a) the token inside a QUOTED STRING:
                 if [ -z "$V" ]; then echo "HOLD: exit 1"; fi
                 -> the shell PRINTS and continues; EXIT=0; the
                    publication is reached. The search was unanchored,
                    so the token inside the quotes satisfied it.

               (b) the refusal BACKGROUNDED: "exit 1 &" -- a
                 backgrounded command's status is discarded; EXIT=0.

               (c) the refusal PIPED: "exit 1 | true" -- the
                 pipeline's status is its last stage's, so EXIT=0
                 unless the block sets pipefail.

               and the refusal could be found in the WRONG
                 CONDITION: the one-line form has no refusal of its
                 own, but the walk went on to the next condition,
                 found ITS exit 1 and attributed it to the first -- so
                 a condition with no refusal at all was certified as
                 refusing.

    Fix:     commit 3d0016a -- the harness now LEXES the shell: the
             commands of a line, their quotes and their tails. A
             refusal must be a COMMAND -- outside the quotes, not
             backgrounded, not swallowed by a pipeline -- it must
             exit non-zero, and it must belong to its own condition.
    Proof:   the controls are 34 of 34 RED, with and without pyyaml;
             six openings are caught and three legitimate forms
             (the one-line "then exit 1; fi", the same-line
             "then echo HOLD; exit 1; fi", the multi-line block) pass
             clean.

    NOTE:   the reviewer also confirmed the whole scope: the game
             code is untouched, the one content/ change is a no-op,
             the workflow itself is sound, and every prior closure
             still holds.

### H-37 — the seventeenth review: the refusal must exit non-zero

    Status:  PROVEN DEFECT — FIXED
    Found:   the seventeenth reviewer reproduced a HIGH with real bash:

               "exit 0" in a refusal is a FAIL-OPEN. "exit 0" reports
               SUCCESS: the step ends, the job continues, and the
               deploy PUBLISHES. Under the platform's own shell:

                 bash -e -c 'set -euo pipefail; MASTER_SHA="";
                   if [ -z "$MASTER_SHA" ]; then echo HOLD; exit 0; fi'
                 -> EXIT=0

               The rule that the master check fails closed used
               _condition_refuses, which only asked whether the block
               contained an "exit " at all -- NOT which exit. So "exit
               0" satisfied it and the harness was silent on a
               workflow that publishes whatever the tip says.

               NOTE: this is NOT the adjudicated "; exit 0" case.
               There, errexit fires FIRST and the script exits 1. Here
               the "exit 0" IS the refusal, so nothing fires before
               it -- the step simply succeeds. The distinction is
               exactly where the reasoning had been too coarse.

    Fix:     commit 0d3e402 -- a refusal must exit NON-ZERO, and all
             four refusals are now checked that way.
    Proof:   the controls are 34 of 34 RED, with and without pyyaml;
             each of the four "exit 0" mutations is now caught.

    NOTE:   the seventeenth reviewer exhausted its iteration budget
             before it could write its verdict, so its reasoning --
             in the live transcript -- and its battery are the
             evidence. Its battery and the sixteenth's are kept at
             r17-work and r16-work.

### H-36 — the sixteenth review: the scope comment and the flow mapping

    Status:  PROVEN DEFECT — FIXED
    Found:   the sixteenth reviewer built its own battery (over 130
             probes) and found two real holes and two false reds:

               a trailing COMMENT on a scope line -- "contents: read
                 # read only" and "pages: write  # needed" are legal
                 YAML, but the pattern's value group ran to the end of
                 the line, so the comment became part of the value
                 and the reader saw a scope called "read  # read
                 only". The rule that the deploy job may hold only
                 three scopes then rejected a LEGAL edit -- a false
                 red in the required CI job, which blocks the
                 publication.

               and "permissions: {contents: write}" is legal YAML and
                 GitHub reads it as the scope map, so it ELEVATES the
                 workflow default. But the workflow-level reader had
                 no flow-mapping branch at all: it returned the whole
                 string as one scope called "{contents: write}" that
                 no rule recognised -- so the elevation was INVISIBLE
                 to every rule. The job-level reader HAD that branch,
                 so the two readers disagreed about the same spelling.
                 The flow mapping is now parsed in ONE place and both
                 readers use it.

    Fix:     both, in commit 7a48075.
    Proof:   the controls are 34 of 34 RED, with and without pyyaml.

    ADJUDICATED by the reviewer itself:
      the deploy's needs as a QUOTED SCALAR ("needs: 'required-tests,
        web-build'") -- GitHub reads a needs as a LIST or a single
        job NAME, so a comma-joined string is one job that does not
        exist: the workflow is invalid and the deploy never runs.
        That is fail closed, not an opening.

      the master's refusal in the ONE-LINE form ("then exit 1; fi")
        and with the exit on the SAME line as the test -- both are
        legal shell and legal YAML, and both PRESERVE the refusal.
        Not openings.

    NOTE:   the reviewer crashed before it could write its verdict,
             so its battery -- not its prose -- is the evidence. The
             battery is kept at r16-work/battery16.py and replays.

### H-35 — the fifteenth review: the operator, the command and the self-certification

    Status:  PROVEN DEFECT — FIXED
    Found:   the fifteenth reviewer read the whole harness and found
             four defects and one principle:

               the "if:" KEY may be QUOTED -- the same class R13-05
                 closed for the job key and R14-01 closed for the
                 permissions key. Both condition readers matched the
                 literal text "if", so a quoted key was INVISIBLE:
                 the guard read as absent, EVERY ref became
                 authorized, and a LEGAL edit was certified as an
                 authorization hole.

               and "!=" was DEAD CODE: the tokenizer's
                 single-character branch ran before the two-character
                 one, so "!" was emitted alone and the following "="
                 failed the word scanner. Fail closed -- but a legal
                 "!=" was a false red, and the detection of an
                 INVERTED comparison was ACCIDENTAL: the model
                 refused to parse it, not because it saw the widened
                 authorization. With the operator read first, the
                 model now SEES that "github.ref != 'staging'"
                 authorizes every other ref -- a real opening it can
                 finally name.

               and the workflow-level permissions block must EXIST:
                 without it a workflow inherits the repository
                 default, whose value the harness cannot know -- and
                 the reusable workflow is a top-level workflow on
                 every push to every branch.

               and the workflow-level reader must take the LAST
                 permissions key, as its own docstring always
                 claimed; it used to BREAK at the first scalar, so
                 the elevation in the block after it was certified.

               and the mandatory steps were certified by NAME only: a
                 step can keep its name and lose its work. "Run
                 legacy regression suite" rewritten to "run: echo ok"
                 satisfies the list, and every property stays
                 silent. The gate step can be DELETED (caught) but
                 NEUTERED (not caught) -- the same class as "a
                 deleted gate is a removed gate", one level down.
                 So a mandatory step must also carry a COMMAND.

    Fix:     all five, in commits f846658 and eda4f21.
    Proof:   the controls are 34 of 34 RED, with and without pyyaml.

    NOTE:   the reviewer named one PRINCIPLE that cannot be closed:
             the harness cannot certify ITSELF. An edit that makes a
             property return [] or calls sys.exit(0) is invisible
             from inside. That is inherent to a self-certifying
             harness, and it is stated here rather than hidden.

### H-34 — the fourteenth review: the quoted key and the implicit success

    Status:  PROVEN DEFECT — FIXED
    Found:   the fourteenth reviewer worked in a clone of its own and
             found the class R13-05 left open, on the NEXT spelling:

               the permissions KEY may be QUOTED. "'permissions':" is
                 legal YAML and resolves to the same key -- exactly
                 like the quoted job key that R13-05 closed. But the
                 permissions reader gated on the literal text
                 "permissions:", so a quoted key was INVISIBLE: the
                 deploy job's quoted key made the reader see NO
                 permissions, and the rule "it may hold only these
                 three" fired -- a FALSE RED on a legal edit, in the
                 required CI job. And the workflow-level quoted key
                 carrying "pages: write" was invisible to EVERY rule,
                 so the harness certified a workflow that publishes
                 from every branch.

               and the model did not implement the IMPLICIT
                 success(). GitHub's own documentation: "A default
                 status check of success() is applied unless you
                 include one of these functions." So a condition with
                 no status function is "success() && <the condition>"
                 -- and the model evaluated the ref and the event on
                 their own, and reported a false assertion about the
                 platform: a FALSE RED on a legal edit.

               and the workflow-level permissions block need not
                 EXIST: a workflow with no block inherits the
                 REPOSITORY default, whose value the harness cannot
                 know -- and the reusable workflow's jobs carry no
                 blocks of their own. And the reader BROKE at the
                 first top-level permissions: whose value was a
                 scalar, so it never met its own documented
                 last-wins contract.

               and the comparison must be a WORKING one: a comparison
                 that refuses EVERY tip is not a guard, it is an
                 outage -- and the rule that checked that it REFUSES
                 could not tell the two apart.

               and the "if:" KEY may be QUOTED too -- the same class
                 R13-05 closed for the job key.

    Fix:     all five, in commits 4edb7eb and c7b1833.
    Proof:   the controls are 34 of 34 RED, with and without pyyaml.

    NOTE:   the reviewer also verified that the WORKFLOW itself is
             sound -- "I did not find an authorization hole in
             release.yml" -- and that the reusable workflow's
             publisher closures, the trigger family, the concurrency
             family and the harness-blindness family all behave.

### H-33 — the thirteenth review's unclosed class: the readers must AGREE

    Status:  PROVEN DEFECT — FIXED
    Found:   the thirteenth reviewer left the deepest finding of the
             series, and it is the ROOT of the series rather than one
             more instance of it:

               there are TWO readers of the deploy's "if:" value --
                 the job-level one and the step-level one -- and they
                 had learned to disagree about the same line THREE
                 times: the trailing comment, the YAML escape of a
                 single-quoted scalar, and the outer quotes of a
                 quoted scalar.

             A disagreement is not a bug in one of them -- it is the
             AGREEMENT that failed. So the disagreement was never
             hunted one spelling at a time; the agreement was the
             thing that had to hold.

             So there is ONE reader now, and both call it. And the
             agreement is a CONTROL: NC-RB-24 checks that the two
                 readers read the same value on every legal spelling
                 of the condition -- the folded block, the literal
                 block, the single-quoted scalar, the double-quoted
                 scalar, each with the trailing comment and the
                 trailing space the formatter may leave on the key.

             And the thirteenth reviewer proved, with PyYAML, that a
             "#" inside a folded block is LITERAL TEXT and not a
             comment -- the platform keeps it. So a rule that
             stripped it was reading a DIFFERENT condition than the
             one the platform sees. The body of a folded block is
             verbatim now; the comment is stripped only from the
             key's own line, where YAML really does treat it as a
             comment.

    Fix:     commit 740deee.
    Proof:   the controls are 34 of 34 RED, with and without pyyaml.

### H-32 — the thirteenth review: the reusable workflow may not publish

    Status:  PROVEN DEFECT — FIXED
    Found:   the thirteenth reviewer worked in a clone of its own and
             found the REST of F-1 -- the same hole on the axis F-1
             did not close -- plus six more:

               the reusable workflow's WORKFLOW-LEVEL permissions were
                 never read: the F-1 fix read the JOB-level scopes of
                 every workflow and the workflow-level scopes only of
                 the release one. So "permissions: {pages: write}" at
                 the workflow level of test.yml -- which every one of
                 its jobs inherits -- was certified.
               and the no-other-publisher rule still exempted
                 test.yml BY NAME, so a deploy-pages step inside it
                 was invisible. It is a TOP-LEVEL workflow: it runs on
                 every push to every branch.
               a TRAILING SPACE on the trigger key -- the most
                 routine formatter artefact there is -- made the
                 whole trigger block invisible, and with it the
                 branch-filter check.
               a QUOTED job key -- "'deploy':" -- is legal YAML and
                 legal GitHub Actions, and the reader required an
                 unquoted key, so the deploy job VANISHED and
                 fourteen properties fired at once on a legal edit.
               the rule that derives the authorization set from the
                 EXPRESSION read only the literals compared against
                 github.ref. A condition on github.ref_name names the
                 same branch in a different spelling, so the text
                 rule saw no ref at all.
               an UPLOAD of the Pages artifact is a publisher too: it
                 stages what the deployment publishes.

    Fix:     all six, in commits 83eaedc and 06b1192.
    Proof:   the controls are 34 of 34 RED, with and without pyyaml.

    NOTE:   the thirteenth reviewer also proved, with PyYAML, that a
             "#" inside a folded block is LITERAL TEXT and not a
             comment -- so the rules that strip it from the block's
             body are stripping something the platform does not
             strip. That is a false red in the making, and the
             thirteenth reviewer reported it as one.

### H-31 — the twelfth review: the reusable workflow is certified too

    Status:  PROVEN DEFECT — FIXED
    Found:   the twelfth reviewer worked in a clone of its own, and it
             found the one HIGH of the series -- plus five more:

               the REUSABLE WORKFLOW was never certified as a
                 publisher. It is a TOP-LEVEL workflow: it has
                 "on: push / pull_request / workflow_call", so it runs
                 on EVERY push to EVERY branch. But the permission
                 rule read the RELEASE workflow's jobs only, and the
                 no-other-publisher rule skipped test.yml by name. So
                 nothing stopped test.yml from gaining pages: write +
                 id-token: write and a deploy-pages step: a SECOND
                 publisher on every branch, with no branch guard, no
                 tip check and no dependency on the required jobs.

                 The rule is a property now: every job of every
                 workflow in the directory may carry an elevated scope
                 only if it is the deploy job of the release
                 workflow.

               the condition as a SINGLE-QUOTED YAML scalar: inside
                 one, '' is the escape for one '. The reader stripped
                 only the outer quotes, so the tokenizer mis-paired
                 them and the rule read an EMPTY literal. The escape
                 is collapsed now -- in BOTH readers of the value,
                 which had learned to disagree about the same line
                 once already.

               a CONTINUATION line of a plain scalar:
                 "run: python tools/x.py \" followed by "|| true".
                 The shell joins them, so the gate's failure is
                 discarded. The block was read by searching BACKWARDS
                 from the gate line for the run: key -- but here the
                 gate line IS the run: line, so the continuation was
                 never examined.

               the FLOW-MAPPING and quoted-key forms of the
                 permissions were not read: the pattern could not
                 match "{pages: write", so the deploy job's scopes
                 read as EMPTY and the two rules about them degraded
                 to no-ops -- a coverage hole in the SECURITY rule.

               the trigger key with a TRAILING COMMENT: the regex
                 required the line to end after the colon, so a legal
                 "on:  # the triggers" made the block invisible.

    Fix:     all six, in commits 23f8523, 8813458 and 31cb653.
    Proof:   the controls are 34 of 34 RED, with and without pyyaml.

    NOTE:   the twelfth reviewer also adjudicated two of the earlier
             batteries' cases as FALSE POSITIVES: "; exit 0" is not an
             opening under "bash -e {0}", and the r9 "R9-08"/"X17"
             mutation is not valid YAML at all.

### H-30 — the eleventh review: the operator, the module, the comment

    Status:  PROVEN DEFECT — FIXED
    Found:   the eleventh reviewer worked in a clone of its own -- the
             isolation finally held -- and found three classes plus
             two adjudicated disagreements:

               the SWALLOW rule found the tail by WHITESPACE, so an
                 operator GLUED to the command was thrown away with
                 it. The shell accepts "cmd| tee log" exactly as it
                 accepts "cmd | tee log". The tail is found by the
                 OPERATOR now.
               the rule did not know the MODULE form of the gate --
                 "python -m tools.release_negative_controls" -- so
                 "|| true" after it was invisible.
               the STEP-CONDITION reader did not strip a trailing
                 comment while the JOB-CONDITION reader did, so the
                 two readers disagreed about the same line. A legal
                 "if: >-  # only master may publish" was read as an
                 unparseable value, which fails closed into "runs
                 regardless": a FALSE RED in the required CI job.

    Fix:     all three, in commit 3d78a25. The ${VAR} spelling and
             the single-line refusal were closed in 5f28f66.
    Proof:   the controls are 34 of 34 RED, with and without pyyaml.

    NOTE:   two of the earlier batteries' cases are FALSE POSITIVES,
             and the eleventh reviewer proved it with real bash:
             "false ; exit 0" exits 1 under the platform's
             "bash -e {0}", because errexit fires before the "; exit
             0" is reached. The real openings are "||", "|" and "&",
             and the controls catch all three in both the spaced and
             the glued spelling. And the ninth reviewer's "I3" case
             is mislabelled: it is filed as a legal edit, but it
             drops the event check -- and the harness correctly flags
             it.

### H-29 — the tenth review's six classes

    Status:  PROVEN DEFECT — FIXED
    Found:   the tenth reviewer's own battery carried about thirty
             cases and found six classes still live:

               the ERREXIT rule knew "set +e" and not the POSIX long
                 form "set +o errexit", which disables the same thing
                 for the whole block.
               a BACKGROUNDED command's status is discarded: the gate
                 could be run with a trailing ampersand and the step
                 would exit 0 whatever it reported.
               the CONCURRENCY group's deny-list named five context
                 fields. It is a property now: the group carries the
                 ref and nothing else, so ref_type, run_attempt and
                 event.number are caught too.
               a PUBLISHER can be a push to ANY branch: the Pages
                 branch of a repository deployed from a branch is
                 whatever the Pages setting names -- gh-pages, site,
                 docs, main -- so any push in the deploy job
                 publishes now.
               the FAIL-CLOSED rule read the readability hold and
                 stopped; it never looked at the COMPARISON that
                 follows it. A comparison guarded by
                 "[ -n \"$VAR\" ] &&" skips an unreadable tip, so the
                 tip is never compared with the published SHA and the
                 deployment proceeds. The comparison is part of the
                 rule now, and the emptiness test is recognised in
                 every spelling -- -z, = "", ! -s, test -z.
               five HELPERS were defined and never called. One of
                 them -- _the_gate_command_is_not_last -- was the
                 implementation of the positional rule, superseded by
                 a rule that misses the class. They are gone, and the
                 registry now FAILS on a helper nobody calls: a rule
                 that does not run.

    Fix:     all six, in commit 9cf59c2.
    Proof:   the controls are 34 of 34 RED, with and without pyyaml,
             and the tenth reviewer's own battery now reports MISSED
             0. Its one remaining disagreement is a case it calls
             legal -- "the gate piped into tee and its output read
             back" -- and the controls flag it. That is the CORRECT
             verdict: without pipefail the pipeline's status is tee's,
             so the gate's RED is lost whatever reads the log.

### H-28 — the tenth review: the pipeline and the platform's shell

    Status:  PROVEN DEFECT — FIXED
    Found:   the tenth reviewer ran against a FROZEN HEAD on a
             separate clone, and it proved the one case the ninth
             review's battery had left uncaught. It had been
             dismissed as "not an opening", and that dismissal was
             WRONG:

               the SWALLOW rule exempted a pipeline that ends in a
                 LOGGER -- "tee" and "cat" -- on the belief that a
                 logger keeps the status of its input. That is true
                 only with pipefail. The platform runs a "run:" step
                 with "bash -e {0}", and that default has NO
                 pipefail: the status of a pipeline is the status of
                 its LAST stage. The reviewer measured it:
                 "false | tee /tmp/x.log" exits 0.

                 So the gate could be piped into a logger and its
                 RED result discarded, and the required job stayed
                 GREEN.

    Fix:     the rule reads the BLOCK now. Without pipefail a
             pipeline discards the gate's status; with "set -euo
             pipefail" -- which the repository's own suite block
             has -- the status is the first failing stage's, which
             is the gate's, so that pipe is legitimate. The stale
             branch that exempted a logger is gone, so the rule is
             one place and not two.
    Proof:   every control is RED, with and without pyyaml,
             and the ninth reviewer's battery now reports 19 of its
             31 cases DETECTED -- the two that remain are not
             openings: one is not valid YAML, and the third is a
             condition that really does admit another branch, so the
             controls catching it is the correct verdict.

    NOTE:   this class was dismissed twice before it was proven.
             The lesson is the one the tenth reviewer's own words
             carry: a dismissal needs a MEASUREMENT, not a
             reasoning about what the shell "should" do.

### H-27 — the ninth review: nine more classes

    Status:  PROVEN DEFECT — FIXED
    Found:   the ninth reviewer's second battery carried thirty-one
             cases and found nine classes still live, five of them
             openings and four false reds:

               the NEEDS were checked with a SUBSTRING on the joined
                 value, so "web-build-extra" satisfied the check for
                 "web-build" -- and the real build was not a
                 dependency of the publication. They are a LIST now,
                 and each item is matched exactly.
               a STEP of the reusable workflow that CONTINUES ON
                 ERROR lets the job stay green on a red suite, and
                 the deploy publishes. Every step is checked now, and
                 the value is read as a YAML boolean.
               a PUBLISHER can be a COMMAND, not only an action: a
                 curl to the Pages API publishes with the token the
                 deploy job already carries, and a push to the Pages
                 branch needs no token at all. The scan is over the
                 whole body, because the URL may be on a
                 continuation line.
               the CONCURRENCY GROUP carried the SHA, so two runs of
                 the SAME ref did not queue behind each other. The
                 group must carry the ref and nothing else that
                 separates two runs of it.
               the RULE that a job may continue on error searched the
                 whole job body for the literal text, so a COMMENT
                 naming the key satisfied it and the real spellings
                 did not. It reads the CODE lines now.
               the CHECK that the deploy can publish searched for the
                 text "pages: write", so the quoted form was
                 reported as a deploy that could not publish. The
                 scope is read as a scope.
               the GATE may be invoked as a MODULE -- "python -m
                 tools.release_negative_controls" -- and the check
                 wanted the script name as the first argument.
               the MODEL did not know two standard GitHub Actions
                 fields -- github.ref_name and contains() -- so a
                 legitimate condition on them failed CLOSED and the
                 harness reported the legitimate master push as
                 REFUSED. The model knows them now, and the master's
                 spellings -- the full ref and the branch name -- are
                 both accepted.
               a JOB HEADER may carry a TRAILING COMMENT -- "deploy:
                 # the deployment" -- and the reader required the
                 header line to END after the colon, so the job
                 became INVISIBLE and fourteen properties reported
                 violations.

    Fix:     all nine, in commits cf01ea6, cc9d187, d808ca2, 7e8dcb7
             and 6dafd7a.
    Proof:   every control is RED, with and without pyyaml,
             and the ninth reviewer's own battery reports 18 of its
             31 cases DETECTED and every legitimate case as
             legal-ok, with no false red left but one.

    NOTE:   three cases of that battery remain MISSED, and NONE of
             them is an opening. A pipeline into "tee" keeps the
             gate's status, so it discards nothing. One case is not
             valid YAML at all, and the reviewer marks it so. The
             third is a condition on contains(github.ref,
             'master'), which really does admit "feature/master" --
             and the controls catch it, which is the correct
             verdict, not a false red.

### H-26 — the ninth review: six more classes

    Status:  PROVEN DEFECT — FIXED
    Found:   the ninth reviewer built a second battery of about
             thirty-five cases and found six classes still live:

               the SWALLOW rule was a list of spellings. It is now
                 POSITIONAL: the gate command must be the last thing
                 whose status decides the step. The run block is read
                 from the "run:" key, a continuation chain belongs to
                 its command, and a command that CHECKS the gate's
                 output -- "grep -q 'RUNNER: GREEN' log" -- is the
                 gate being used, not swallowed.
               the CONCURRENCY flag was the literal text
                 "cancel-in-progress: true". It is read as a YAML
                 boolean now, so True, TRUE and yes are caught.
               the VALIDATED-BYTES rule read only the FIRST upload.
                 Every upload is read now, so a second upload of an
                 unvalidated directory cannot overwrite the artifact.
               the REUSABLE WORKFLOW's triggers were never certified.
                 They are now, by their names. Its own push and
                 pull_request triggers are legitimate -- that is what
                 it is for.
               the PUBLICATION count read the steps that USE an
                 action. A publisher can also be a plain COMMAND:
                 "git push origin HEAD:gh-pages" publishes with no
                 action and no token.
               the NEEDS were checked by their NAME. They are checked
                 by WHAT THEY DO now: the required-tests job must
                 call the reusable workflow that runs the CI, so the
                 CI cannot be decoupled from the publication by
                 renaming a job.

    Fix:     all six, in commit 6656f18.
    Proof:   every control is RED, with and without pyyaml,
             and the ninth reviewer's own battery reports every
             LEGAL case as legal-ok.

    NOTE:   the class is stable across nine rounds: a textual rule
             is defeated by the next spelling. Every rule is now
             structural -- it reads the mechanism, its subject, its
             order and its scope -- and the remaining work is to
             prove that on a FROZEN branch.

### H-25 — the eighth review's battery, replayed

    Status:  PROVEN DEFECT — FIXED
    Found:   the eighth reviewer left its battery in the scratch
             directory, and replaying it against the branch exposed
             THIRTEEN openings and TWO false reds that the review
             itself had not listed:

               S1/S2  (SELF-CONCEALING) the gate commands were
                      certified by the script name as a SUBSTRING, so
                      an echo that mentioned the command satisfied
                      them, and a step could be deleted with its name
                      carried by a string
               S3-S7  the swallow rule listed the commands that
                      swallow; an arbitrary command after the gate and
                      the gate inverted into a conditional were missed
               S8-S11 the authorization set was a list -- a generated
                      one, but still a list -- so authorizing another
                      ref or another event passed
               S12/S13 the trigger keys were read as SUBSTRINGS, so a
                      quoted key or a key with a space before the colon
                      hid a forbidden trigger
               S15/S16 the readability check tested the wrong variable
               S17    the publication count knew one action name
               S18    a second upload of an unvalidated directory
               L-o/L-t  two FALSE REDS: a quoted trigger key and a
                      quoted step name are legal YAML

    Fix:     the gate commands must RUN and the step names are read
             as NAMES; the swallow rule is structural -- the gate
             command must be the LAST thing whose status decides the
             step, and the whole run block is read; the corpus is
             GENERATED over the shapes of a ref and the names of an
             event; the trigger keys are read as KEYS and judged by
             their names; the readability check tests the RIGHT
             variable; a publication is counted by its action's
             CAPABILITY.
    Proof:   every control is RED, with and without pyyaml,
             and the eighth reviewer's own battery now reports zero
             false reds.

### H-24 — the eighth review: the class is still live

    Status:  PROVEN DEFECT — FIXED
    Found:   the eighth reviewer pinned the tree and hunted for the
             CLASS rather than the instance. The class is still live
             in three of the places that matter most:

               R8-01  the harness's own blindness: a further way to
                      switch the controls off, which the rule about
                      the disabled step did not reach
               R8-02  the swallow was a spelling list. The next
                      spellings were missed -- a path to the true
                      command, an explicit success after the gate, and
                      a swallow on a CONTINUATION line of a
                      multi-line run block, because the rule read one
                      line at a time
               R8-03/04  the authorization set is still a list, not a
                      rule: the corpus replaced a hand-written list
                      with a generated one, and it is still a list
               R8-07  the publication count was the count of one
                      action name: a third-party Pages action before
                      the tip checks was a second publication path,
                      invisible to the count

    Fix:     the swallow is SEMANTIC -- the whole run block is read
             and any construct that discards the gate's status is a
             swallow. The publication count is a RULE -- a step that
             publishes is counted by its action's CAPABILITY, so the
             official action, a third-party one and a plain push are
             all seen, and the ordinary actions are not.
    Proof:   every control is RED, with and without pyyaml.

    NOTE:   seven rounds, one class. The pattern is stable: a
             textual rule is defeated by the next spelling, and a
             spelling is always one more. The controls are now
             structural -- they read the mechanism, its subject, its
             order and its scope -- and that is the only shape that
             survives the next round.

### H-23 — the seventh review: three HIGH and four more

    Status:  PROVEN DEFECT — FIXED
    Found:   the seventh reviewer found the same class for the
             seventh time, and three HIGH findings:

               R7-01  the job-level exclusion was TEXTUAL: a step's
                      mapping form "if: false" strips to "if: false",
                      which matched the exclusion and was DROPPED as
                      the job-level guard. The reusable workflow's
                      steps are read ONLY through that filter, so a
                      mapping-form disablement was invisible. The
                      distinction is INDENTATION, not text.
               R7-02  the publisher rule was still a spelling list:
                      "permissions: {contents: write}", quoted keys
                      and a different case were all missed.
               R7-03  the swallow rule read only the literal
                      "|| true": the same swallow has "| true",
                      "||true" and "set +e", which disables the
                      errexit so the step exits 0 on a failing gate.
               R7-04  the named list of the reusable workflow's steps
                      covered 8 of 25, so 16 steps were DELETABLE
                      with the harness green -- including the A-H
                      differential and the ledger validator.
               R7-05  the branch filter check only asked whether
                      "master" was PRESENT, so a widened filter
                      passed.
               R7-06  the deploy's permissions check only rejected a
                      scope that was present and wrong; a MISSING
                      scope was never checked.
               R7-07  the readers used the plain "utf-8", so a BOM
                      became part of the first line -- a FALSE RED
                      on a legitimate commit. A BOM is valid YAML and
                      GitHub accepts it.
               R7-08  the documents quoted the counts' outputs as
                      literals, and the file list missed a file.

    Fix:     the distinction between the job level and the step level
             is the INDENTATION; the scopes are extracted and judged;
             the swallow has three spellings and the run block is
             read; the step list is complete and the rule is a
             difference; the filter must be exactly master; the
             deploy must hold all three scopes; the BOM is stripped.
    Proof:   every control is RED, with and without pyyaml.

### H-22 — the seventh review: two more shapes of the same class

    Status:  PROVEN DEFECT — FIXED
    Found:   probing the seventh reviewer's list directly found two
             more shapes of the hole the whole series has been about:

               1. a workflow that CALLS the release workflow is a
                  second path to the same publication: it would run
                  the release workflow from its own trigger, on its
                  own ref, with its own permissions
               2. the swallowed-gate rule matched only the tools/
                  prefix, so a gate command under tests/ci/ could
                  swallow its exit code:
                  "python tests/ci/standalone_runner_test.py || true"
                  would make the standalone runner contract a no-op
                  that always passes

    Fix:     a workflow that calls the release workflow is refused,
             and the gate rule is now "(tools|tests|scripts)/".

    NOTE:   this is the SEVENTH pass in which the finding was the
             same class. The pattern is stable, and it is the reason
             the controls are structural rather than textual: a
             textual rule is defeated by the next spelling, and a
             spelling is always one more.

### H-21 — the sixth review: nine gaps, the same class again

    Status:  PROVEN DEFECT — FIXED
    Found:   the sixth independent reviewer found the SAME CLASS of
             hole the fifth review called HIGH, re-opened through a
             different spelling, plus five more:

               R6-01  the second-publisher detector was a TWO-TOKEN
                      STRING SEARCH. A publisher that writes to the
                      Pages branch directly carries neither
                      "deploy-pages" nor "pages: write": it pushes to
                      gh-pages with contents: write. So the premise
                      was only certified for the two spellings the
                      rule was written for.
               R6-02  the swallowed-gate check was a list of command
                      NAMES, and six gate commands were outside it.
               R6-03  a mandatory step could be DELETED outright. The
                      harness proved a step cannot be disabled, but
                      not that it cannot be absent -- and deleting the
                      step that runs the controls leaves the deploy
                      publishing with nothing running them.
               R6-04  the deploy job was exempt from the permissions
                      check, so it could hold any elevated scope.
               R6-05  only the release workflow's triggers were
                      certified; a pull_request_target: trigger on
                      the REUSABLE workflow is the classic privilege
                      escalation shape.
               R6-06  the documents carried hard-coded commit counts
                      in the very block that claimed they were not
                      hard-coded.
               R6-07  the job-level condition filter matched "if"
                      and "if " -- but the key is "if:", so the
                      job-level guard came back as a step condition.
               R6-08  cancel-in-progress: true would silently cancel
                      the in-flight older run, contradicting the
                      workflow's own comment.
               R6-09  the upload path was not checked against the
                      validated path.

    Fix:     every rule is now a RULE and not a token list: a
             publisher is any elevated permission, a Pages branch or
             a Pages action; a swallowed gate is any python script
             from the tools directory; a deleted gate is a named list
             of steps that must be present; the deploy job holds
             exactly three scopes; both workflows' triggers are
             certified.
    Proof:   every control is RED, with and without pyyaml.

### H-20 — the sixth review: the gate's result could be swallowed

    Status:  PROVEN DEFECT — FIXED
    Found:   four more gaps, found by probing the sixth reviewer's
             list directly:

               1. "|| true" after the controls made the step succeed
                  whatever they reported: the gate would run, say RED,
                  and the CI would carry on
               2. the deploy's needs could name a job that does not
                  exist -- not an opening, since GitHub fails such a
                  workflow, but the harness must see it
               3. a job's timeout could be removed: the deploy could
                  then hang forever and hold the Pages deployment
                  queue
               4. the release workflow could be renamed: the file the
                  controls read would still be the one that publishes

    Fix:     only the GATE's own commands are checked for a swallowed
             result -- "godot --editor --quit || true" is legitimate
             and is not a gate. The needs are checked against the jobs
             that exist. The timeout is required, except for a job
             that CALLS the reusable workflow: the called workflow
             carries it. The workflow's name is certified.
    Proof:   every control is RED, with and without pyyaml.

### H-19 — the fifth review: the harness could not see its own disablement

    Status:  PROVEN DEFECT — FIXED
    Found:   the fifth independent reviewer found the two most
             valuable holes of the whole series, both in the evidence
             harness, and both real:

               R5-01  SELF-CONCEALING. The harness could not detect
                      its OWN disablement. The step in test.yml that
                      RUNS THE CONTROLS could be disabled with
                      "if: false", and the thing that would have
                      reported it was the thing that was switched off.
                      The harness reported GREEN with the release
                      controls disabled -- byte-identical to the
                      baseline. The same hole covered every mandatory
                      step of the reusable workflow: the A-H
                      differential, the battle-ecs suites, the ledger
                      validator, the lint, the legacy regression.
               R5-02  an UNGATED SECOND PUBLISHER was invisible. The
                      harness resolved its inputs by filename, so a
                      workflow file it did not know about could not
                      be checked -- and one that publishes on every
                      branch with pages: write would pass every
                      control. The premise "the old ungated publish
                      path cannot survive the merge" is true for the
                      DELETED web-build.yml and false for any NEW
                      file.

    Fix:     the reusable workflow is part of the gate: its jobs and
             its step conditions are read, so a disabled job or step
             is seen. The workflow directory is scanned for any other
             publisher.
    Proof:   every control is RED, with and without pyyaml.

    NOTE:   across five passes the WORKFLOW was never found broken.
             Every finding was in the proof. The distinction matters:
             the gate is sound, the proof was not -- and a proof that
             cannot see its own disablement certifies nothing.

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
    Proof:   every control is RED, with and without pyyaml,
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
    Proof:   every control is RED, with and without pyyaml,
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
             34 of 34 RED.

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
             every control is RED -- the count at that commit was
             thirty three, and the CURRENT count is read from the
             repository.

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
    Proof:   every control was RED -- nine of them at that commit --
             and the registry carries only the gate properties, so
             every entry is really checked by the property it names.

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
             raises ImportError, exactly as on a bare runner: 31 of 31
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
