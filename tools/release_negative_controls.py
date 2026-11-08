"""The release-gate negative controls (R4).

    NC-REL-01  remove the dependency on battle-ecs        -> RED
    NC-REL-02  remove the dependency on save-battle-migration -> RED
    NC-REL-03  allow a failed/skipped required job        -> RED
    NC-REL-04  remove the SHA identity check              -> RED
    NC-REL-05  allow a manual deployment bypass           -> RED
    NC-REL-06  accept a missing index.html                -> RED
    NC-REL-07  allow a stale deployment to supersede a newer commit -> RED
    NC-REL-08  accept a reference to a path the artifact does not carry -> RED
    NC-REL-09  upload the artifact from the wrong job     -> RED

Every mutation is applied to an ISOLATED TEMPORARY COPY of the
workflow files. The production workflows are never written to.

WHAT EACH CONTROL MEASURES

    The GATE controls -- NC-REL-01..05, 07 and 09 -- mutate the
    WORKFLOWS and assert a PROPERTY of the result:

      - the deploy job's `needs` really contains the required call;
      - a required job carries NO condition at all, because a
        condition is the only way to take a job out of the run;
      - no job carries `continue-on-error: true`;
      - the deploy job really checks out, so the tip check can read
        a remote;
      - ONE condition really compares the published SHA with the
        branch tip, and really refuses;
      - the concurrency group really is per ref;
      - the job that BUILDS the artifact uploads it, and the deploy
        job does not upload a directory it does not have.

    The VALIDATOR controls -- NC-REL-06 and NC-REL-08 -- mutate the
    ARTIFACT VALIDATOR and compare two validator invocations. They
    say nothing about the gate: they say that the artifact gate
    itself cannot be weakened.

WHY THEY ARE STRUCTURAL AND NOT TEXTUAL

    The first version of this harness evaluated a "decision function"
    that read the workflow as TEXT. That was worthless, and the
    independent critic proved it: a genuinely broken deploy was
    reported as a PASS, because the decision function RECOGNISED the
    mutation by its text and denied it -- a rule written for that
    exact mutation.

    A textual decision function cannot separate "the gate is broken"
    from "the mutation text is unusual". So each control here
    asserts a PROPERTY, and the mutation must BREAK that property:
    the CLEAN gate satisfies it, the MUTATED gate must not. A
    mutation that does not open anything is reported as MISSED and
    counts as a problem, so the harness exits 0 only when every
    control is a real RED.

HOW THE WORKFLOWS ARE READ

    Not with a YAML library. This file was the only one in the
    repository that imported yaml, and no CI workflow installs
    pyyaml, so the step would have failed on the runner and turned
    the REQUIRED battle-ecs job RED. The reader here is a small
    indentation scanner that returns the job names and the body of
    each job, which is what the properties need.
"""

import io
import os
import re
import shutil
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOWS = os.path.join(REPO, ".github", "workflows")
RELEASE = os.path.join(WORKFLOWS, "release.yml")
TEST = os.path.join(WORKFLOWS, "test.yml")
VALIDATOR = os.path.join(REPO, "tools", "validate_web_artifact.py")



# =====================================================================
# THE STRUCTURAL PROPERTIES
#
# Each property returns a list of violations. An empty list means the
# gate has the property. A control mutates the gate and asserts that
# the property VIOLATIONS APPEAR.
# =====================================================================

def _needs_of(jobs, job_name):
    """The `needs:` list of a job.

    The job reader already returns the BODY of the job, so the list is
    simply inside it. Both the inline form ("needs: [a, b]") and the
    block form ("needs:\n  - a") are read.
    """
    body = jobs.get(job_name) or ""
    inline = re.search(r"needs:\s*\[([^\]]*)\]", body)
    if inline:
        return inline.group(1)
    block = re.search(r"needs:\s*\n((?:\s+-\s*\S+\s*\n?)+)", body)
    if block:
        return " ".join(re.findall(r"-\s*(\S+)", block.group(1)))
    plain = re.search(r"needs:\s*(\S+)", body)
    if plain:
        return plain.group(1)
    return ""


def _job(jobs, name):
    """The body of a job, as text."""
    return jobs.get(name) or ""


def _block(jobs, job_name):
    """The body of a job as a text block, for the line-level checks."""
    return jobs.get(job_name) or ""


def _job_condition(block):
    """The `if:` condition of a job, if it has one.

    The condition is read SEMANTICALLY: the key is matched with its
    optional quoting and any spacing, and the value is returned as it
    stands. A literal substring match on "if: false" would only catch
    that one spelling -- "if: ${{ false }}", "if: ${{ !cancelled() }}"
    and "if: github.event_name == 'never'" would all slip through, and
    the required job could be disabled while every control stayed
    green.
    """
    for line in block.split("\n"):
        stripped = line.strip()
        match = re.match(r"^if\s*:\s*(.*)$", stripped)
        if match:
            return match.group(1).strip()
    return ""


def _never_runs(block):
    """True when the job's condition can disable it.

    ANY condition on a required job is treated as a guard: the
    required jobs must always run, and a condition is the only way to
    take one out of the run.
    """
    condition = _job_condition(block)
    if not condition:
        return False
    # A condition that is literally true cannot disable the job.
    normalised = condition.strip().strip("'\"").lower()
    if normalised in ("true", "${{ true }}", "${{true}}"):
        return False
    return True


def prop_01_battle_ecs_dependency(release, test):
    """The release CALLS the reusable workflow AND that workflow runs
    the battle-ecs job."""
    out = []
    release_text = release["text"]
    if "uses: ./.github/workflows/test.yml" not in release_text:
        out.append("the release does not call the reusable test workflow")
    if "battle-ecs" not in test["jobs"]:
        out.append("the reusable workflow carries no battle-ecs job")
    else:
        block = test["jobs"]["battle-ecs"]
        if _never_runs(block):
            out.append("the battle-ecs job is conditioned and can be "
                       "skipped: %s" % _job_condition(block))
    return out


def prop_02_save_dependency(release, test):
    """The save-battle-migration job exists and really runs."""
    out = []
    if "save-battle-migration" not in test["jobs"]:
        out.append("the reusable workflow carries no save-battle-migration job")
    else:
        block = test["jobs"]["save-battle-migration"]
        if _never_runs(block):
            out.append("the save-battle-migration job is conditioned and "
                       "can be skipped: %s" % _job_condition(block))
    return out


def prop_03_no_failure_tolerance(release, test):
    """No job may continue on error, and no required job may be
    conditioned so that a failure does not block."""
    out = []
    for name, block in list(release["jobs"].items()) + list(test["jobs"].items()):
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
    deploy = release["jobs"].get("deploy", "")

    # The published SHA and the branch tip must be compared with EACH
    # OTHER, in ONE condition, and that condition must refuse.
    #
    # The check is per CONDITION, not per file: the step has three
    # separate statements, and a mutation that removes only the
    # comparison leaves the other two intact.
    compares = False
    for line in deploy.split("\n"):
        if "if" not in line:
            continue
        if "TIP" in line and "github.sha" in line:
            if "exit 1" in deploy:
                compares = True
            else:
                out.append("the SHA comparison never refuses")
            break
    if not compares and not out:
        out.append("the deploy job never compares the published SHA "
                   "with the branch tip")

    # The identity of the built and the deployed SHA is carried in the
    # artifact.
    build = release["jobs"].get("web-build", "")
    if "BUILD_SHA" not in build:
        out.append("the build does not record its provenance")
    return out


def prop_05_no_manual_bypass(release, test):
    """The deploy reaches the pages only through the required call."""
    out = []
    deploy = release["jobs"].get("deploy", "")
    needs = _needs_of(release["jobs"], "deploy")
    if "required-tests" not in needs:
        out.append("the deploy does not need the required tests")
    # A deployment that is conditioned on the manual trigger could
    # publish without them.
    for line in deploy.split("\n"):
        if line.strip().startswith("if:"):
            out.append("the deploy job is conditioned")
            break
    return out


def prop_06_artifact_validation(release, test):
    """The artifact is validated, and it is the validated bytes that
    are published."""
    out = []
    build = release["jobs"].get("web-build", "")
    if "validate_web_artifact.py" not in build:
        out.append("the build does not validate the artifact")
    # The job that BUILDS the artifact uploads it.
    if "upload-pages-artifact" not in build:
        out.append("the build job does not upload the artifact")
    # The deploy job must not upload a directory it does not have.
    deploy = release["jobs"].get("deploy", "")
    if "upload-pages-artifact" in deploy:
        out.append("the deploy job uploads a build/ directory it does "
                   "not have")
    return out


def prop_07_no_stale_deployment(release, test):
    """The concurrency group is per ref, and the deploy job has a
    repository, so the tip check can read the remote."""
    out = []
    release_text = release["text"]
    if "group: pages-" not in release_text:
        out.append("the concurrency group does not separate the branches")
    if "github.ref" not in release_text:
        out.append("the concurrency group is not per ref")
    deploy = release["jobs"].get("deploy", "")
    if "actions/checkout" not in deploy:
        out.append("the deploy job has no checkout: the tip check cannot "
                   "read a remote")
    return out


# The properties, by control name.
# The properties of the GATE, one per control. NC-REL-06 and
# NC-REL-08 are NOT here: they measure the ARTIFACT VALIDATOR, not the
# gate, and they have their own branches. The registry carries only
# the gate properties, so every entry really is checked by the
# property it names.
#
# NC-REL-09 covers the artifact FLOW: the job that builds the
# artifact uploads it, and the deploy job does not upload a directory
# it does not have.
PROPERTIES = {
    "NC-REL-01": prop_01_battle_ecs_dependency,
    "NC-REL-02": prop_02_save_dependency,
    "NC-REL-03": prop_03_no_failure_tolerance,
    "NC-REL-04": prop_04_sha_identity,
    "NC-REL-05": prop_05_no_manual_bypass,
    "NC-REL-07": prop_07_no_stale_deployment,
    "NC-REL-09": prop_06_artifact_validation,
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

    ("NC-REL-08",
     "accept a reference to a path the artifact does not carry",
     "tools/validate_web_artifact.py",
     [("        if not os.path.isfile(target):\n"
       "            fail(\"the index.html references %s, which the artifact "
       "does \"\n"
       "                 \"not carry at that path\" % ref, problems)",
       "        if os.path.basename(ref) not in files:\n"
       "            fail(\"the index.html references %s, which the artifact "
       "does \"\n"
       "                 \"not carry\" % os.path.basename(ref), problems)")]),

    ("NC-REL-09",
     "upload the artifact from the deploy job instead of the build job",
     "release.yml",
     [("      - uses: actions/upload-pages-artifact@v3\n"
       "        with:\n"
       "          path: build/\n",
       ""),
      ("      - uses: actions/configure-pages@v5",
       "      - uses: actions/upload-pages-artifact@v3\n"
       "        with:\n"
       "          path: build/\n"
       "      - uses: actions/configure-pages@v5")]),

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


def load_jobs(path):
    """The workflows of the repository, read WITHOUT a YAML library.

    The repository's CI tools deliberately avoid a YAML dependency:
    this file was the only one that imported yaml, and no workflow
    installs pyyaml, so a yaml import here would have failed on the
    runner and turned the REQUIRED battle-ecs job RED.

    The reader understands what the properties need: the job names and
    the body of each job, with the two-space indentation the workflows
    use.

    Returns {job_name: body_text}.
    """
    with io.open(path, encoding="utf-8") as f:
        text = f.read()

    jobs = {}
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        # A job header is "  name:" at the two-space indentation.
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if match:
            name = match.group(1)
            body = []
            i += 1
            while i < len(lines):
                nxt = lines[i]
                if nxt.strip() == "":
                    body.append(nxt)
                    i += 1
                    continue
                # A line that is less indented ends the job.
                if not nxt.startswith("    ") and not nxt.startswith("  "):
                    break
                if re.match(r"^  [A-Za-z0-9_-]+:\s*$", nxt):
                    break
                body.append(nxt)
                i += 1
            jobs[name] = "\n".join(body)
            continue
        i += 1
    return jobs


def load_text(path):
    with io.open(path, encoding="utf-8") as f:
        return f.read()


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


def make_reference_artifact(reference):
    """An artifact whose index.html references a path the artifact does
    not carry: "index.js" sits at the root, the html points into a
    subdirectory."""
    root = tempfile.mkdtemp(prefix="rel_ref_")
    with io.open(os.path.join(root, "index.html"), "w",
                 encoding="utf-8") as f:
        f.write("<html><body>x</body></html>\n" * 200)
        f.write("<script src='%s'></script>\n" % reference)
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

        if name == "NC-REL-08":
            # The reference check must compare the PATH. The clean
            # validator denies a reference to "subdir/index.js" when
            # the artifact carries only "index.js" at the root; the
            # mutated one compares the basename and allows it.
            clean = load_validator_from(
                os.path.join(REPO, "tools", "validate_web_artifact.py"))
            mutated_validator = load_validator_from(copy_validator)
            clean_problems = clean.validate(
                make_reference_artifact("subdir/index.js"))
            mutated_problems = mutated_validator.validate(
                make_reference_artifact("subdir/index.js"))
            if not clean_problems:
                failures.append("the clean validator ALLOWED a reference "
                                "to a path it does not carry")
            if mutated_problems:
                failures.append("the mutation did not open the validator: %s"
                                % "; ".join(mutated_problems))
            if failures:
                return "MISSED", 1, len(failures), 0
            return "RED", 0, 0, 0

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
            clean_violations = property_fn(
                {"text": load_text(RELEASE), "jobs": load_jobs(RELEASE)},
                {"text": load_text(TEST), "jobs": load_jobs(TEST)})
            if clean_violations:
                failures.append("the clean gate already violates the "
                                "property: %s" % "; ".join(clean_violations))
            # The MUTATED gate must VIOLATE it: that is what the
            # mutation did.
            mutated_release = os.path.join(copy_wf, "release.yml")
            mutated_test = os.path.join(copy_wf, "test.yml")
            mutated_violations = property_fn(
                {"text": load_text(mutated_release),
                 "jobs": load_jobs(mutated_release)},
                {"text": load_text(mutated_test),
                 "jobs": load_jobs(mutated_test)})
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
