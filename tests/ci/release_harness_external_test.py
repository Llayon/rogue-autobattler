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
and their summary line. On the clean tree all three print the same
"release controls: N, clean: N, problems: 0" -- N read from the
harness's own declaration, so it cannot go stale -- and all three
exit 0. A verifier that only checked the exit code and the summary
would certify a harness that checks nothing.

The independent critic found the earlier form of this claim stale:
the mutants printed 35 while the harness printed 36, so they were
distinguishable by a number, and the proof was overstated. A fake
that can be told apart by a number is not the dangerous fake.

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

# The number of controls the release harness DECLARES. It is counted
# from the harness's own text -- the entries of its MUTATIONS
# registry -- and NOT imported, so the verifier stays independent of
# the harness's code. A harness that runs a single control and
# reports "(1, 1, 0)" is caught against this number.
CONTROL_COUNT = re.compile(r'^    \("NC-[A-Z]+-\d+",', re.MULTILINE)


def _declared_controls(harness_text):
    """How many controls the harness's own text declares."""
    return len(CONTROL_COUNT.findall(harness_text))


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
    # The fixture must be INDISTINGUISHABLE from the repository in
    # the ways a harness can look.
    #
    # The independent critic found three ways to tell them apart:
    # by the fixture's PREFIX, by the ABSENCE of a .git directory,
    # and by the tree's BASENAME. Each was a real bypass, because
    # the verifier only ever looked at the fixture -- so a harness
    # that behaved correctly there and was a no-op everywhere else
    # was certified.
    #
    # There is no name that is safe by being unusual: being unusual
    # IS the signal. So the fixture is given the repository's OWN
    # name, inside a generic temporary parent. A harness that
    # compares the basename finds the same answer in both; one that
    # walks up finds a generic parent in both; one that looks for
    # .git finds it in both.
    parent = tempfile.mkdtemp(prefix="gate_probe_")
    tmp = os.path.join(parent, os.path.basename(REPO))
    os.makedirs(tmp)
    # The PARENT must not carry a signal either: the critic's next
    # attack recognised the fixture by the name of its parent. So the
    # fixture's parent is given the repository's OWN parent's name --
    # the same answer a harness finds by walking up from the
    # repository.
    repo_parent = os.path.basename(os.path.dirname(REPO))
    if repo_parent:
        hidden = os.path.join(parent, repo_parent)
        os.rename(tmp, hidden)
        tmp = hidden
    for rel in ("tools", os.path.join(".github", "workflows")):
        os.makedirs(os.path.join(tmp, rel))
    # The fixture must be indistinguishable from the repository in
    # the ways a harness can look. The independent critic's E2 attack
    # recognised the fixture by the ABSENCE of a .git directory --
    # so the fixture gets one. It is an empty directory, not a
    # repository: it holds no history and the harness never reads it.
    # It exists only so that "is this a git tree?" has the same
    # answer in the fixture and in the repository.
    os.makedirs(os.path.join(tmp, ".git"))
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

    The summary it prints carries the SAME control count as the real
    harness -- read from the harness's own declaration, so it cannot
    go stale. The independent critic found this: with a different
    number, the mutants were distinguishable by their summary alone,
    and the "indistinguishable by exit code and summary" claim was
    overstated. A fake that can be told apart by a number is not the
    dangerous fake.
    """
    count = _declared_controls(harness_text)
    start = harness_text.find("def main():")
    if start < 0:
        raise AssertionError("the harness has no main()")
    end = harness_text.find("\nif __name__ ==", start)
    if end < 0:
        raise AssertionError("the harness's entry point is not where it was")
    return (harness_text[:start] + "def main():\n"
            '    print("")\n'
            '    print("release controls: %d, clean: %d, problems: 0")\n'
            "    return 0\n\n" % (count, count) + harness_text[end:])


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
    count = _declared_controls(harness_text)
    return (harness_text[:start] + '    print("")\n'
            '    print("release controls: %d, clean: %d, problems: 0")\n'
            "    return 0" % (count, count) + harness_text[end:])


def _remove(tree):
    """Remove a temporary tree, and REPORT a failure to remove it.

    shutil.rmtree(..., ignore_errors=True) swallows the error, and on
    Windows a file the harness has just written can still be locked --
    so the tree silently survived, and the verifier left a temporary
    tree behind on every run. That is litter in the CI workspace, and
    it is worse than litter: the tree holds a COPY of the harness and
    of the workflows, and a later reader would not know it was a
    throwaway.

    So the removal is checked, and a leftover is a failure of the
    verifier -- not a silent no-op.
    """
    shutil.rmtree(tree, ignore_errors=True)
    if os.path.isdir(tree):
        return False
    # The generic parent goes too.
    parent = os.path.dirname(tree)
    shutil.rmtree(parent, ignore_errors=True)
    if os.path.isdir(parent):
        return False
    return True


def _run_in_tree(harness_text=None, with_defect=False):
    """The exit code of the harness, on a tree that is thrown away.

    Returns (exitcode, stdout, removed_cleanly).
    """
    tree = _build_tree(harness_text, with_defect)
    try:
        code, out = _run(tree)
    finally:
        removed = _remove(tree)
    return code, out, removed


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
    defect_code, defect_out, removed = _run_in_tree(harness_text,
                                                    with_defect=True)
    print("   the exit code:      %s" % defect_code)
    print("   the summary:        %s" % (_summary(defect_out),))
    if not removed:
        failures.append("%s left a temporary tree behind" % label)
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

    # The floor for the control count, from the PRODUCTION harness's
    # own declaration. A mutated copy cannot lower it: the floor is
    # read from the repository's file, not from the copy under test.
    declared = _declared_controls(_read(HARNESS))
    print("   the harness declares %d controls" % declared)

    # ---- 1. the CLEAN harness ----
    print("CLEAN HARNESS")
    code, out, removed = _run_in_tree()
    summary = _summary(out)
    print("   the exit code:      %s" % code)
    print("   the summary:        %s" % (summary,))
    if not removed:
        failures.append("the clean harness run left a temporary tree "
                        "behind")
    if code != 0:
        failures.append("the clean harness did not pass: exit %s" % code)
    elif summary is None:
        failures.append("the clean harness printed no summary")
    elif summary[2] != 0:
        failures.append("the clean harness reported %d problems"
                        % summary[2])
    elif summary[0] == 0:
        failures.append("the clean harness checked nothing")
    elif summary[0] < declared:
        # A harness that runs ONE control and honestly reports
        # "(1, 1, 0)" is caught HERE. The independent critic found it:
        # the verifier asked only "did the harness refuse the
        # defect", and a harness that runs a single control can do
        # that while checking almost nothing. So the clean run must
        # also show that the harness checked a SUFFICIENT number of
        # controls -- and the number is compared with the count the
        # harness itself declares, so it cannot go stale.
        failures.append("the clean harness checked only %d controls: a "
                        "harness that checks almost nothing can still "
                        "refuse one defect" % summary[0])
    else:
        print("   PASS")

    # ---- 2 and 3: the harnesses that must be caught ----
    harness_text = _read(HARNESS)
    _check_disabled("NO-OP HARNESS", _no_op(harness_text), failures)
    _check_disabled("FAKE-GREEN HARNESS", _fake_green(harness_text), failures)

    # ---- 4. the REAL defect, and the REAL harness ----
    print("")
    print("REAL DEFECT")
    code, out, removed = _run_in_tree(with_defect=True)
    summary = _summary(out)
    print("   the exit code:      %s" % code)
    print("   the summary:        %s" % (summary,))
    if not removed:
        failures.append("the real-defect run left a temporary tree behind")
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
