#!/usr/bin/env python3
"""The EXTERNAL verification of the release negative-control harness.

The release controls prove that the RELEASE GATE refuses a red CI, a
skipped job, a different SHA, a stale deployment and a manual bypass.
But a harness that certifies itself cannot prove that it is still
running: an edit that replaces its main path with an unconditional
success is invisible from inside it -- the harness's own properties
would report the tree as clean, because the properties are what the
edit disabled.

So the trust boundary is drawn HERE, and it is drawn BEHAVIOURALLY:

    REAL RELEASE HARNESS
            |
            v
    EXTERNAL BEHAVIOURAL VERIFICATION      <- this file
            |
            v
    PASS / FAIL

This verifier does NOT import the harness. It does not use the
harness's parser, its table of properties, or its verdict logic. It
does not decide whether the harness worked by reading the harness's
own output. It runs the harness as an executable, against a fixture
it controls, and looks at what the harness DID.

THE FOUR SCENARIOS:

    1. CLEAN HARNESS        the untouched harness, against the
                            untouched workflows: it must PASS.
    2. NO-OP HARNESS        the harness's main path replaced by an
                            unconditional success: it must be
                            DETECTED.
    3. FAKE-GREEN HARNESS   the harness that runs the controls and
                            throws the verdicts away, printing a
                            plausible summary: it must be DETECTED.
    4. REAL DEFECT          a real release defect in an isolated
                            workflow fixture: the REAL harness must
                            REJECT it.

Why scenario 4 is the load-bearing one: the no-op and the fake-green
harness are INDISTINGUISHABLE from the real one by their exit code
and their summary line. Both print "release controls: 35, clean: 35,
problems: 0" and exit 0. A verifier that only checked the exit code
and the summary would certify a harness that checks nothing.

So the verifier asks a question the summary cannot answer: does the
harness REFUSE a defect it is supposed to refuse? A harness that
cannot refuse anything is not a harness.

Every fixture is written into a temporary directory and removed
afterwards. The repository's own files are never written to.
"""

import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

# This file lives in tests/ci/, so the repository root is three levels
# up. The harness resolves its own paths from its own __file__, and so
# does this file -- the two never depend on the working directory.
REPO = os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))))
HARNESS = os.path.join(REPO, "tools", "release_negative_controls.py")
VALIDATOR = os.path.join(REPO, "tools", "validate_web_artifact.py")
WORKFLOWS = os.path.join(REPO, ".github", "workflows")
RELEASE = os.path.join(WORKFLOWS, "release.yml")

# The summary the harness prints when it is satisfied. It is matched
# as TEXT and never trusted: the fake-green harness prints exactly
# this, which is the whole point of scenario 3.
SUMMARY = re.compile(r"release controls:\s*(\d+),\s*clean:\s*(\d+),\s*"
                     r"problems:\s*(\d+)")

# The defect injected into the workflow fixture: the master-tip
# comparison inverted, so the gate would publish a commit that is NOT
# the tip of master. The real harness rejects it -- that is what the
# eighteenth reviewer proved, and what the harness has a property for.
DEFECT_OLD = '          if [ "$MASTER_SHA" != "${{ github.sha }}" ]; then'
DEFECT_NEW = '          if [ "$MASTER_SHA" == "${{ github.sha }}" ]; then'


def _read(path):
    with io.open(path, encoding="utf-8-sig") as handle:
        return handle.read().replace("\r\n", "\n")


def _write(path, text):
    with io.open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def _build_tree(harness_text=None, with_defect=False):
    """An isolated tree the harness can run in.

    The harness resolves every path from its own __file__, so a copy
    placed in <tmp>/tools/ reads <tmp>/.github/workflows/ -- the
    fixture -- and never the repository's workflows. That is the
    seam: no line of the harness is changed to point it at a
    fixture.
    """
    tmp = tempfile.mkdtemp(prefix="release_harness_external_")
    for rel in ("tools", os.path.join(".github", "workflows")):
        os.makedirs(os.path.join(tmp, rel))
    source = harness_text if harness_text is not None else _read(HARNESS)
    _write(os.path.join(tmp, "tools", "release_negative_controls.py"), source)
    shutil.copyfile(VALIDATOR,
                    os.path.join(tmp, "tools", "validate_web_artifact.py"))
    for name in ("release.yml", "test.yml"):
        path = os.path.join(WORKFLOWS, name)
        if not os.path.isfile(path):
            continue
        text = _read(path)
        if with_defect and name == "release.yml":
            text = text.replace(DEFECT_OLD, DEFECT_NEW)
        _write(os.path.join(tmp, ".github", "workflows", name), text)
    return tmp


def _run(tree):
    """Run the harness in the tree. Returns (returncode, stdout)."""
    completed = subprocess.run(
        [sys.executable,
         os.path.join(tree, "tools", "release_negative_controls.py")],
        capture_output=True, text=True, cwd=tree, timeout=600)
    return completed.returncode, completed.stdout


def _summary(stdout):
    match = SUMMARY.search(stdout)
    if not match:
        return None
    return tuple(int(group) for group in match.groups())


def _no_op(harness_text):
    """The harness whose main path is an unconditional success.

    The whole entry point is replaced by "return 0": no mutation is
    applied, no property is evaluated, no verdict is produced. The
    harness does no work at all.
    """
    start = harness_text.find("def main():")
    if start < 0:
        raise AssertionError("the harness has no main()")
    end = harness_text.find("\nif __name__ ==", start)
    if end < 0:
        raise AssertionError("the harness's entry point is not where it was")
    return (harness_text[:start] + "def main():\n"
            '    print("")\n'
            '    print("release controls: 35, clean: 35, problems: 0")\n'
            "    return 0\n\n" + harness_text[end:])


def _fake_green(harness_text):
    """The harness that runs the controls and throws the verdicts away.

    This is the dangerous one: the mutation loop still runs, the
    controls still execute, and the output looks exactly right -- but
    the verdicts are discarded, so a control that missed is never
    noticed. The summary is a plausible one, and the exit code is 0.
    """
    anchor = '    problems = [r for r in results if r[1] != "RED"]'
    start = harness_text.find(anchor)
    if start < 0:
        raise AssertionError("the harness's main path is not where it was")
    end = harness_text.find("    return 1 if problems else 0", start)
    if end < 0:
        raise AssertionError("the harness's exit code is not where it was")
    end += len("    return 1 if problems else 0")
    return (harness_text[:start] + '    print("")\n'
            '    print("release controls: 35, clean: 35, problems: 0")\n'
            "    return 0" + harness_text[end:])


def _run_in_tree(harness_text=None, with_defect=False):
    """The exit code of the harness, on a tree that is thrown away."""
    tree = _build_tree(harness_text, with_defect)
    try:
        return _run(tree)
    finally:
        shutil.rmtree(tree, ignore_errors=True)


def _check_disabled(label, harness_text, failures):
    """A harness that must be caught accepting a defect it must refuse.

    Both the no-op and the fake-green harness report success whatever
    the fixture says. So they are caught by the question the summary
    cannot answer: does the harness REFUSE a defect?

    Only the defect run is needed: the summary it prints there is the
    one the verifier compares against, and running the full suite
    twice per scenario would double the CI time for no extra
    evidence.
    """
    print("")
    print(label)
    defect_code, defect_out = _run_in_tree(harness_text, with_defect=True)
    print("   the exit code:      %s" % defect_code)
    print("   the summary:        %s" % (_summary(defect_out),))
    if defect_code == 0:
        print("   DETECTED -- it accepted a defect it must refuse")
    else:
        failures.append("%s refused the defect: the mutation did not "
                        "disable it" % label)
        print("   NOT DETECTED -- the mutation is wrong")


def main():
    failures = []
    print("the external verification of the release harness")
    print("")

    # ---- 1. the CLEAN harness ----
    print("CLEAN HARNESS")
    code, out = _run_in_tree()
    summary = _summary(out)
    print("   the exit code:      %s" % code)
    print("   the summary:        %s" % (summary,))
    if code != 0:
        failures.append("the clean harness did not pass: exit %s" % code)
    elif summary is None:
        failures.append("the clean harness printed no summary")
    elif summary[2] != 0:
        failures.append("the clean harness reported %d problems"
                        % summary[2])
    elif summary[0] == 0:
        failures.append("the clean harness checked nothing")
    else:
        print("   PASS")

    # ---- 2 and 3: the harnesses that must be caught ----
    harness_text = _read(HARNESS)
    _check_disabled("NO-OP HARNESS", _no_op(harness_text), failures)
    _check_disabled("FAKE-GREEN HARNESS", _fake_green(harness_text), failures)

    # ---- 4. the REAL defect, and the REAL harness ----
    print("")
    print("REAL DEFECT")
    code, out = _run_in_tree(with_defect=True)
    summary = _summary(out)
    print("   the exit code:      %s" % code)
    print("   the summary:        %s" % (summary,))
    if code == 0:
        failures.append("the real harness accepted a real defect")
        print("   NOT DETECTED -- the harness is broken")
    else:
        print("   DETECTED -- the real harness refuses it")

    print("")
    if failures:
        print("THE EXTERNAL VERIFICATION FAILED:")
        for failure in failures:
            print("   ", failure)
        return 1
    print("THE EXTERNAL VERIFICATION: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
