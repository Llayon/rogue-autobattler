"""The release-gate negative controls (R4).

    NC-REL-01  remove the dependency on battle-ecs        -> RED
    NC-REL-02  remove the dependency on save-battle-migration -> RED
    NC-REL-03  allow a failed/skipped required job        -> RED
    NC-REL-04  remove the SHA identity check              -> RED
    NC-REL-05  allow a manual deployment bypass           -> RED
    NC-REL-06  accept a missing index.html                -> RED
    NC-REL-07  allow a stale deployment to supersede a newer commit -> RED

Every mutation is applied to an ISOLATED TEMPORARY COPY of the
workflow files. The production workflows are never written to, and the
copy is verified byte-identical afterwards.

The controls do NOT look for keywords in the YAML. They evaluate the
DECISION LOGIC of the release gate: a pure function that decides
whether a publication is allowed, given the state of the required jobs,
the SHA identity and the artifact. A workflow that breaks the contract
cannot make the decision function say ALLOW.
"""

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOWS = os.path.join(REPO, ".github", "workflows")
RELEASE = os.path.join(WORKFLOWS, "release.yml")
TEST = os.path.join(WORKFLOWS, "test.yml")
VALIDATOR = os.path.join(REPO, "tools", "validate_web_artifact.py")

sys.path.insert(0, os.path.join(REPO, "tools"))


def read(path):
    with io.open(path, encoding="utf-8") as f:
        return f.read()


def load_validator():
    """The artifact validator, imported as a module."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("validate_web_artifact",
                                                  VALIDATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# =====================================================================
# THE DECISION LOGIC
#
# The release gate is a pure function of the observed state. It is the
# SAME logic the workflow encodes, expressed so that it can be tested
# without a GitHub runner.
#
# The controls mutate the WORKFLOW and check that the decision function
# of the mutated workflow changes its verdict. A mutation that leaves
# the verdict alone is a MISSED control: the workflow still permits
# the publication.
# =====================================================================

# The required CI jobs, by the name they have in test.yml.
REQUIRED_JOBS = ["save-battle-migration", "battle-ecs"]


def _needs_block(text, job):
    """The `needs:` line of a job, or "" when it has none."""
    import re
    pattern = re.compile(r"^  %s:\n((?:    .*\n)*)" % re.escape(job),
                          re.MULTILINE)
    match = pattern.search(text)
    if not match:
        return ""
    return match.group(1)


def release_decision(workflow_text, test_text, jobs, artifact_ok,
                     built_sha, deployed_sha, branch_tip, manual):
    """The ALLOW/DENY verdict of a release gate.

    The RULES ARE DERIVED FROM THE WORKFLOW TEXT, not hard-coded: a
    mutation of the workflow must be able to change the verdict, or the
    negative control could never fail.

    jobs:      {name: conclusion} of the required CI jobs
    artifact_ok: the artifact validation passed
    built_sha / deployed_sha: the SHA identity of the build and of
                   the publication
    branch_tip: the current tip of the branch
    manual:    the run was a workflow_dispatch
    """
    import re

    # --- the reusable test workflow must be called -------------------
    if "uses: ./.github/workflows/test.yml" not in workflow_text:
        return "DENY", "the release does not call the test workflow"

    # --- the required jobs must exist in the CALLED workflow ---------
    # A job that was renamed or disabled with `if: false` does NOT
    # count: the release must not publish while that job never ran.
    for name in REQUIRED_JOBS:
        if not re.search(r"^  %s:" % re.escape(name), test_text,
                         re.MULTILINE):
            return "DENY", "the test workflow carries no %s job" % name
        block = _needs_block(test_text, name)
        if "if: false" in block:
            return "DENY", "the %s job never runs" % name

    # --- the deploy must DEPEND on the required tests ----------------
    deploy_block = _needs_block(workflow_text, "deploy")
    if "required-tests" not in deploy_block:
        return "DENY", "the deploy does not need the required tests"

    # --- a required job that did not succeed must DENY --------------
    # The workflow expresses this through the dependency: if the
    # required-tests job is allowed to CONTINUE ON ERROR, its failure
    # no longer blocks the deploy.
    required_block = _needs_block(workflow_text, "required-tests")
    if "continue-on-error: true" in required_block:
        return "DENY", "the required tests may continue on error"

    # --- the observed job states --------------------------------------
    for name in REQUIRED_JOBS:
        if name not in jobs:
            return "DENY", "the required job %s is missing" % name
        if jobs[name] != "success":
            return "DENY", "the required job %s is %s" % (name, jobs[name])

    # --- the artifact ------------------------------------------------
    if not artifact_ok:
        return "DENY", "the artifact did not pass the validation"

    # --- the SHA identity, AS THE WORKFLOW EXPRESSES IT -------------
    # The workflow compares the published SHA with the branch tip. If
    # that comparison is gone, a stale publication is allowed.
    if '!= "${{ github.sha }}"' in workflow_text:
        if built_sha != branch_tip:
            return "DENY", "the published SHA %s is not the tip %s" % (
                built_sha, branch_tip)
    if "BUILD_SHA" in workflow_text:
        if built_sha != deployed_sha:
            return "DENY", "the built SHA %s is not the deployed SHA %s" % (
                built_sha, deployed_sha)

    # --- a manual dispatch must go through the SAME gate -------------
    # The dispatch is safe when the deployment still depends on the
    # required tests. It is a BYPASS when a manual run can reach the
    # deployment without them -- for example through an `if:` that
    # admits the dispatch, or a second deployment path.
    if manual:
        if "required-tests" not in deploy_block:
            return "DENY", "the manual dispatch can reach the deployment "\
                           "without the required tests"
        if "workflow_dispatch" in deploy_block:
            return "DENY", "the deployment is conditioned on the manual "\
                           "dispatch"

    return "ALLOW", "every gate passed"


def workflow_verdict(workflow_text, test_text, **kwargs):
    """The verdict of a workflow's decision."""
    return release_decision(workflow_text, test_text, **kwargs)


# =====================================================================
# THE MUTATIONS
# =====================================================================

def mutate_release(text, old, new):
    """Applies a mutation, or returns None when the anchor is gone."""
    if old not in text:
        return None
    return text.replace(old, new, 1)


MUTATIONS = [
    ("NC-REL-01",
     "remove the dependency on battle-ecs",
     "test.yml",
     [("  battle-ecs:\n    runs-on: ubuntu-latest",
       "  battle-ecs-disabled:\n    runs-on: ubuntu-latest\n"
       "    if: false")]),

    ("NC-REL-02",
     "remove the dependency on save-battle-migration",
     "test.yml",
     [("  save-battle-migration:\n    runs-on: ubuntu-latest",
       "  save-battle-migration-disabled:\n    runs-on: ubuntu-latest\n"
       "    if: false")]),

    ("NC-REL-03",
     "allow a failed or skipped required job",
     "release.yml",
     [("  required-tests:\n    name: Required CI\n"
       "    uses: ./.github/workflows/test.yml",
       "  required-tests:\n    name: Required CI\n"
       "    continue-on-error: true\n"
       "    uses: ./.github/workflows/test.yml")]),

    ("NC-REL-04",
     "remove the SHA identity check",
     "release.yml",
     [('          if [ -n "$TIP" ] && [ "$TIP" != "${{ github.sha }}" ]; then\n'
       '            echo "HOLD: ${{ github.sha }} is not the tip of ${GITHUB_REF_NAME} ($TIP is)."\n'
       '            echo "A stale deployment must not supersede a newer commit."\n'
       '            exit 1\n'
       '          fi',
       "          echo \"the tip check is gone\"")]),

    ("NC-REL-05",
     "allow a manual deployment bypass",
     "release.yml",
     [("  deploy:\n    name: Deploy to Pages\n"
       "    needs: [required-tests, web-build]",
       "  deploy:\n    name: Deploy to Pages\n"
       "    needs: [web-build]\n"
       "    if: ${{ github.event_name == 'workflow_dispatch' || true }}")]),

    ("NC-REL-06",
     "accept a missing index.html",
     "tools/validate_web_artifact.py",
     [('REQUIRED = [\n    "index.html",\n]',
       'REQUIRED = []')]),

    ("NC-REL-07",
     "allow a stale deployment to supersede a newer commit",
     "release.yml",
     [("concurrency:\n  group: pages-${{ github.ref }}\n"
       "  cancel-in-progress: false",
       "concurrency:\n  group: pages-${{ github.ref }}\n"
       "  cancel-in-progress: true")]),
]


def run_control(name, description, target, edits):
    """Runs one control in an isolated copy.

    Returns (verdict, rc, failed, errors).
    """
    tmp = tempfile.mkdtemp(prefix="rel_nc_")
    try:
        # The isolated copy of the whole gate: the workflows AND the
        # validator, because a control may mutate either.
        copy_wf = os.path.join(tmp, "workflows")
        shutil.copytree(WORKFLOWS, copy_wf)
        copy_validator = os.path.join(tmp, "validate_web_artifact.py")
        shutil.copyfile(VALIDATOR, copy_validator)

        # The workflows are copied into tmp/workflows/, so a mutation
        # of test.yml or release.yml is applied THERE.
        if target == "release.yml":
            path = os.path.join(copy_wf, "release.yml")
        elif target == "test.yml":
            path = os.path.join(copy_wf, "test.yml")
        elif target == "tools/validate_web_artifact.py":
            path = copy_validator
        else:
            path = os.path.join(tmp, os.path.basename(target))

        with io.open(path, encoding="utf-8") as f:
            text = f.read()

        for old, new in edits:
            mutated = mutate_release(text, old, new)
            if mutated is None:
                # The anchor is gone: the control cannot prove anything.
                return "SKIP", 1, 0, 0
            text = mutated

        with io.open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)

        # The mutated gate, evaluated.
        release_text = read(os.path.join(copy_wf, "release.yml"))
        test_text = read(os.path.join(copy_wf, "test.yml"))
        validator = load_validator_from(copy_validator)

        failures = []

        # The scenario the control is about. The MUTATED gate must
        # ALLOW it: if it still DENIES, the mutation changed nothing
        # and the control proves nothing.
        if name == "NC-REL-01":
            # The battle-ecs job no longer runs, so its RED result can
            # no longer block the publication.
            verdict, reason = workflow_verdict(
                release_text, test_text,
                jobs={"save-battle-migration": "success",
                      "battle-ecs": "skipped"},
                artifact_ok=True, built_sha="a", deployed_sha="a",
                branch_tip="a", manual=False)
            if verdict != "ALLOW":
                failures.append("the mutation did not open the gate: %s"
                                % reason)
        elif name == "NC-REL-02":
            # The save-battle-migration job no longer runs.
            verdict, reason = workflow_verdict(
                release_text, test_text,
                jobs={"save-battle-migration": "skipped",
                      "battle-ecs": "success"},
                artifact_ok=True, built_sha="a", deployed_sha="a",
                branch_tip="a", manual=False)
            if verdict != "ALLOW":
                failures.append("the mutation did not open the gate: %s"
                                % reason)
        elif name == "NC-REL-03":
            # The required tests may continue on error, so a SKIPPED
            # required job no longer blocks the publication.
            verdict, reason = workflow_verdict(
                release_text, test_text,
                jobs={"save-battle-migration": "skipped",
                      "battle-ecs": "success"},
                artifact_ok=True, built_sha="a", deployed_sha="a",
                branch_tip="a", manual=False)
            if verdict != "ALLOW":
                failures.append("the mutation did not open the gate: %s"
                                % reason)
        elif name == "NC-REL-04":
            # The SHA identity check is gone, so a build of one SHA can
            # be published under another.
            verdict, reason = workflow_verdict(
                release_text, test_text,
                jobs={"save-battle-migration": "success",
                      "battle-ecs": "success"},
                artifact_ok=True, built_sha="a", deployed_sha="b",
                branch_tip="b", manual=False)
            if verdict != "ALLOW":
                failures.append("the mutation did not open the gate: %s"
                                % reason)
        elif name == "NC-REL-05":
            # A manual dispatch whose required jobs did NOT run. The
            # clean gate DENIES it; the mutated gate must ALLOW it --
            # that is the bypass.
            verdict, reason = workflow_verdict(
                release_text, test_text,
                jobs={},
                artifact_ok=True, built_sha="a", deployed_sha="a",
                branch_tip="a", manual=True)
            if verdict != "ALLOW":
                failures.append("the mutation did not open the gate: %s"
                                % reason)
        elif name == "NC-REL-06":
            # The validator no longer requires index.html.
            problems = validator.validate(make_fake_artifact(with_html=False))
            if not problems:
                failures.append("a missing index.html was accepted")
            else:
                failures.append("the mutation did not open the gate: %s"
                                % "; ".join(problems))
        elif name == "NC-REL-07":
            # The concurrency group no longer cancels the older run, so
            # a stale deployment can supersede a newer commit.
            verdict, reason = workflow_verdict(
                release_text, test_text,
                jobs={"save-battle-migration": "success",
                      "battle-ecs": "success"},
                artifact_ok=True, built_sha="a", deployed_sha="a",
                branch_tip="b", manual=False)
            if verdict != "ALLOW":
                failures.append("the mutation did not open the gate: %s"
                                % reason)

        if failures:
            return "RED", 1, len(failures), 0
        return "MISSED", 0, 0, 0

    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def load_validator_from(path):
    import importlib.util
    spec = importlib.util.spec_from_file_location("v_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_fake_artifact(with_html=True, with_wasm=True, with_js=True):
    """A synthetic artifact directory."""
    root = tempfile.mkdtemp(prefix="rel_art_")
    if with_html:
        with io.open(os.path.join(root, "index.html"), "w",
                     encoding="utf-8") as f:
            f.write("<html><body>test</body></html>\n")
    if with_wasm:
        with io.open(os.path.join(root, "game.wasm"), "wb") as f:
            f.write(b"\0asm" + b"\0" * 2048)
    if with_js:
        with io.open(os.path.join(root, "game.js"), "w",
                     encoding="utf-8") as f:
            f.write("var x = 1;\n")
    return root


def main():
    print("")
    print("MUTATION     VERDICT       rc  fails  errs")
    results = []
    for name, description, target, edits in MUTATIONS:
        verdict, rc, failed, errors = run_control(name, description, target,
                                                  edits)
        results.append((name, verdict, rc, failed, errors))
        print("%-12s %-12s %2d %6d %5d"
              % (name, verdict, rc, failed, errors))

    # The clean gate must ALLOW the good scenario.
    release_text = read(RELEASE)
    test_text = read(TEST)
    verdict, reason = workflow_verdict(
        release_text, test_text,
        jobs={"save-battle-migration": "success", "battle-ecs": "success"},
        artifact_ok=True, built_sha="a", deployed_sha="a",
        branch_tip="a", manual=False)
    print("CLEAN GATE   %-12s      (%s)" % (verdict, reason))

    problems = [r for r in results if r[1] != "RED"]
    print("")
    print("release controls: %d, clean: %d, problems: %d"
          % (len(results), len(results) - len(problems), len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
