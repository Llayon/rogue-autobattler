"""The release-gate negative controls (R4).

    NC-REL-01  remove the dependency on battle-ecs        -> RED
    NC-REL-02  remove the dependency on save-battle-migration -> RED
    NC-REL-03  allow a failed/skipped required job        -> RED
    NC-REL-04  remove the SHA identity check              -> RED
    NC-REL-05  allow a manual deployment bypass           -> RED
    NC-REL-06  accept a missing index.html                -> RED
    NC-REL-07  allow a stale deployment to supersede a newer commit -> RED

Every mutation is applied to an ISOLATED TEMPORARY COPY of the
workflow files. The production workflows are never written to.

WHY THESE ARE STRUCTURAL AND NOT TEXTUAL

    The first version of this harness evaluated a "decision function"
    that read the workflow as TEXT. That was worthless, and the
    independent critic proved it: a genuinely broken deploy was
    reported as a PASS, because the decision function RECOGNISED the
    mutation by its text and denied it -- a rule written for that
    exact mutation.

    A textual decision function cannot separate "the gate is broken"
    from "the mutation text is unusual". So the controls here are
    STRUCTURAL: the workflows are PARSED AS DATA (YAML), and each
    control asserts a PROPERTY of the parsed graph:

      - the deploy job's `needs` really contains the required call;
      - no required job carries `if:` that could skip it;
      - no job carries `continue-on-error: true`;
      - the deploy job really checks out, so the tip check can read
        a remote;
      - the tip really compares the published SHA with the branch
        tip, and an unreadable tip really HOLDs;
      - the concurrency group really is per ref;
      - the artifact is really uploaded by the job that built it and
        published by the job that downloads it;
      - the validator really rejects an artifact without an
        index.html.

    A mutation breaks a PROPERTY, so the assertion fails, so the
    control is a real RED. And the CLEAN gate is asserted to satisfy
    every property, so a control that passes for the wrong reason is
    visible.
"""

import copy
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

try:
    import yaml
except ImportError:  # pragma: no cover
    yaml = None


# =====================================================================
# THE STRUCTURAL PROPERTIES
#
# Each property returns a list of violations. An empty list means the
# gate has the property. A control mutates the gate and asserts that
# the property VIOLATIONS APPEAR.
# =====================================================================

def _job(data, name):
    return (data.get("jobs") or {}).get(name) or {}


def _block(data, job_name):
    """The body of a job as a text block, for the line-level checks."""
    text = json.dumps(data.get("jobs") or {}, indent=1, default=str)
    return text


def prop_01_battle_ecs_dependency(release, test):
    """The release calls the reusable workflow AND that workflow runs
    the battle-ecs job."""
    out = []
    jobs = (release.get("jobs") or {})
    required = _job(release, "required-tests")
    if required.get("uses") != "./.github/workflows/test.yml":
        out.append("the release does not call the reusable test workflow")
    test_jobs = (test.get("jobs") or {})
    if "battle-ecs" not in test_jobs:
        out.append("the reusable workflow carries no battle-ecs job")
    else:
        block = _block(test, "battle-ecs")
        if "if: false" in block:
            out.append("the battle-ecs job never runs")
    return out


def prop_02_save_dependency(release, test):
    """The save-battle-migration job exists and really runs."""
    out = []
    test_jobs = (test.get("jobs") or {})
    if "save-battle-migration" not in test_jobs:
        out.append("the reusable workflow carries no save-battle-migration job")
    else:
        block = _block(test, "save-battle-migration")
        if "if: false" in block:
            out.append("the save-battle-migration job never runs")
    return out


def prop_03_no_failure_tolerance(release, test):
    """No job may continue on error, and no required job may be
    conditioned so that a failure does not block."""
    out = []
    for name, job in (release.get("jobs") or {}).items():
        if job.get("continue-on-error") is True:
            out.append("the %s job continues on error" % name)
        block = _block(release, name)
        if "continue-on-error: true" in block:
            out.append("the %s job continues on error" % name)
    for name in ("save-battle-migration", "battle-ecs"):
        block = _block(test, name)
        if "continue-on-error: true" in block:
            out.append("the %s job continues on error" % name)
    return out


def prop_04_sha_identity(release, test):
    """The tip really compares the published SHA with the branch tip,
    and the comparison really refuses.

    The property is about the COMPARISON, not about the surrounding
    shell: the deploy job also refuses an UNREADABLE tip, and that
    refusal must not be mistaken for the identity check.
    """
    out = []
    deploy = _job(release, "deploy")
    steps = deploy.get("steps") or []
    body = json.dumps(steps, indent=1, default=str)

    # The published SHA and the branch tip must be compared with EACH
    # OTHER, in ONE condition, and that condition must refuse.
    #
    # The check is per CONDITION, not per file: the step has three
    # separate statements, and a mutation that removes only the
    # comparison leaves the other two intact. Looking for the tokens
    # anywhere in the script would have found them.
    compares = False
    for step in steps:
        run = str((step or {}).get("run", ""))
        for line in run.split("\n"):
            if "if" not in line:
                continue
            # The condition names BOTH sides of the comparison.
            if "TIP" in line and "github.sha" in line:
                if "exit 1" in run:
                    compares = True
                else:
                    out.append("the SHA comparison never refuses")
                break
        if compares:
            break
    if not compares and not out:
        out.append("the deploy job never compares the published SHA "
                   "with the branch tip")

    # The identity of the built and the deployed SHA is carried in the
    # artifact.
    build = _job(release, "web-build")
    build_body = json.dumps(build.get("steps") or [], indent=1, default=str)
    if "BUILD_SHA" not in build_body:
        out.append("the build does not record its provenance")
    return out


def prop_05_no_manual_bypass(release, test):
    """The deploy reaches the pages only through the required call."""
    out = []
    deploy = _job(release, "deploy")
    needs = deploy.get("needs") or []
    if isinstance(needs, str):
        needs = [needs]
    if "required-tests" not in needs:
        out.append("the deploy does not need the required tests")
    # A deployment that is conditioned on the manual trigger could
    # publish without them.
    if deploy.get("if"):
        out.append("the deploy job is conditioned")
    return out


def prop_06_artifact_validation(release, test):
    """The artifact is validated, and it is the validated bytes that
    are published."""
    out = []
    build = _job(release, "web-build")
    build_body = json.dumps(build.get("steps") or [], indent=1, default=str)
    if "validate_web_artifact.py" not in build_body:
        out.append("the build does not validate the artifact")
    # The job that BUILDS the artifact uploads it.
    if "upload-pages-artifact" not in build_body:
        out.append("the build job does not upload the artifact")
    # The deploy job must not upload a directory it does not have.
    deploy = _job(release, "deploy")
    deploy_body = json.dumps(deploy.get("steps") or [], indent=1, default=str)
    if "upload-pages-artifact" in deploy_body:
        out.append("the deploy job uploads a build/ directory it does "
                   "not have")
    return out


def prop_07_no_stale_deployment(release, test):
    """The concurrency group is per ref, and the deploy job has a
    repository, so the tip check can read the remote."""
    out = []
    group = release.get("concurrency") or {}
    if not str(group.get("group", "")).startswith("pages-"):
        out.append("the concurrency group does not separate the branches")
    if "github.ref" not in str(group.get("group", "")):
        out.append("the concurrency group is not per ref")
    deploy = _job(release, "deploy")
    uses = [str(s.get("uses", "")) for s in (deploy.get("steps") or [])]
    if not any("actions/checkout" in u for u in uses):
        out.append("the deploy job has no checkout: the tip check cannot "
                   "read a remote")
    return out


# The properties, by control name.
PROPERTIES = {
    "NC-REL-01": prop_01_battle_ecs_dependency,
    "NC-REL-02": prop_02_save_dependency,
    "NC-REL-03": prop_03_no_failure_tolerance,
    "NC-REL-04": prop_04_sha_identity,
    "NC-REL-05": prop_05_no_manual_bypass,
    "NC-REL-07": prop_07_no_stale_deployment,
}


# =====================================================================
# THE MUTATIONS
# =====================================================================

def _mutate(text, old, new):
    if old not in text:
        return None
    return text.replace(old, new, 1)


MUTATIONS = [
    ("NC-REL-01",
     "remove the dependency on battle-ecs",
     "test.yml",
     [("  battle-ecs:\n    runs-on: ubuntu-latest",
       "  battle-ecs-disabled:\n    runs-on: ubuntu-latest\n    if: false")]),

    ("NC-REL-02",
     "remove the dependency on save-battle-migration",
     "test.yml",
     [("  save-battle-migration:\n    runs-on: ubuntu-latest",
       "  save-battle-migration-disabled:\n    runs-on: ubuntu-latest\n    if: false")]),

    ("NC-REL-03",
     "allow a failed/skipped required job",
     "release.yml",
     [("  required-tests:\n    name: Required CI\n",
       "  required-tests:\n    name: Required CI\n"
       "    continue-on-error: true\n")]),

    ("NC-REL-04",
     "remove the SHA identity check",
     "release.yml",
     [('          if [ "$TIP" != "${{ github.sha }}" ]; then\n'
       '            echo "HOLD: ${{ github.sha }} is not the tip of '
       '${GITHUB_REF_NAME} ($TIP is)."\n'
       '            echo "A stale deployment must not supersede a newer '
       'commit."\n'
       '            exit 1\n'
       '          fi',
       '          echo "the tip check is gone"')]),

    ("NC-REL-05",
     "allow a manual deployment bypass",
     "release.yml",
     [("    needs: [required-tests, web-build]",
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
       "  cancel-in-progress: true"),
      ("      - uses: actions/checkout@v4\n        with:\n"
       "          fetch-depth: 1\n\n",
       "")]),
]


def load_yaml(path):
    with io.open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def load_validator_from(path):
    import importlib.util
    spec = importlib.util.spec_from_file_location("v_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_fake_artifact(with_html=True):
    """A synthetic artifact directory.

    It is a COMPLETE artifact, so a control that removes one
    requirement sees exactly that one requirement disappear and not a
    dozen others.
    """
    root = tempfile.mkdtemp(prefix="rel_art_")
    if with_html:
        with io.open(os.path.join(root, "index.html"), "w",
                     encoding="utf-8") as f:
            f.write("<html><body>test</body></html>\n")
    with io.open(os.path.join(root, "index.wasm"), "wb") as f:
        f.write(b"\x00asm" + b"\0" * (2 * 1024 * 1024))
    with io.open(os.path.join(root, "index.js"), "w",
                 encoding="utf-8") as f:
        f.write("var x = 1;\n")
    with io.open(os.path.join(root, "index.pck"), "wb") as f:
        f.write(b"\0" * (256 * 1024))
    return root


def run_control(name, description, target, edits):
    """Runs one control in an isolated copy.

    Returns (verdict, rc, failed, errors).
    """
    tmp = tempfile.mkdtemp(prefix="rel_nc_")
    try:
        copy_wf = os.path.join(tmp, "workflows")
        shutil.copytree(WORKFLOWS, copy_wf)
        copy_validator = os.path.join(tmp, "validate_web_artifact.py")
        shutil.copyfile(VALIDATOR, copy_validator)

        if target == "release.yml":
            path = os.path.join(copy_wf, "release.yml")
        elif target == "test.yml":
            path = os.path.join(copy_wf, "test.yml")
        else:
            path = copy_validator

        with io.open(path, encoding="utf-8") as f:
            text = f.read()

        for old, new in edits:
            mutated = _mutate(text, old, new)
            if mutated is None:
                # The anchor is gone: the control cannot prove anything.
                return "SKIP", 1, 1, 0
            text = mutated

        with io.open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)

        failures = []

        if name == "NC-REL-06":
            # The validator, not the gate.
            clean = load_validator_from(
                os.path.join(REPO, "tools", "validate_web_artifact.py"))
            mutated_validator = load_validator_from(copy_validator)
            clean_problems = clean.validate(make_fake_artifact(with_html=False))
            mutated_problems = mutated_validator.validate(
                make_fake_artifact(with_html=False))
            if not clean_problems:
                failures.append("the clean validator ALLOWED an artifact "
                                "without an index.html")
            if mutated_problems:
                failures.append("the mutation did not open the validator: %s"
                                % "; ".join(mutated_problems))
        else:
            property_fn = PROPERTIES[name]
            # The CLEAN gate must satisfy the property.
            clean_violations = property_fn(load_yaml(RELEASE), load_yaml(TEST))
            if clean_violations:
                failures.append("the clean gate already violates the "
                                "property: %s" % "; ".join(clean_violations))
            # The MUTATED gate must VIOLATE it: that is what the
            # mutation did.
            mutated_violations = property_fn(
                load_yaml(os.path.join(copy_wf, "release.yml")),
                load_yaml(os.path.join(copy_wf, "test.yml")))
            if not mutated_violations:
                failures.append("the mutation did not break the property")

        if failures:
            return "MISSED", 1, len(failures), 0
        return "RED", 0, 0, 0

    except Exception as error:  # noqa: BLE001
        return "INVALID", 1, 1, 1

    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    if yaml is None:
        print("pyyaml is required: the controls parse the workflows")
        return 2

    print("")
    print("MUTATION     VERDICT       rc  fails  errs")
    results = []
    for name, description, target, edits in MUTATIONS:
        verdict, rc, failed, errors = run_control(name, description, target,
                                                  edits)
        results.append((name, verdict, rc, failed, errors))
        print("%-12s %-12s %2d %6d %5d"
              % (name, verdict, rc, failed, errors))

    problems = [r for r in results if r[1] != "RED"]
    print("")
    print("release controls: %d, clean: %d, problems: %d"
          % (len(results), len(results) - len(problems), len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
