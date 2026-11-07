#!/usr/bin/env python3
"""CI-01: the standalone runner must be FAIL-CLOSED.

The baseline runner reported `RUNNER: GREEN` and exit code 0 when
`discover()` returned an EMPTY list, when `--only` matched nothing,
and when a suite printed `0 pass / 0 fail`. A test runner that cannot
prove it ran anything is a runner that lies.

These are the SELF-TESTS of the runner, and they are the RED matrix of
the finding. The baseline runner ACCEPTED the first, the second, the
third and the seventh scenario, so they were RED before the fix:

  1. discover() returned an empty list;
  2. --only matched no suite;
  3. a suite exited rc=0 and printed `0 pass / 0 fail`;
  4. a suite printed `0 pass / 0 fail` and then exited rc=1;
  5. a suite exited rc=0 and printed no summary at all;
  6. a suite printed a successful summary AND a SCRIPT ERROR;
  7. several suites: one good, one empty;
  8. an ordinary suite with positive assertions.

Every incorrect scenario must give a NON-ZERO exit code and a readable
diagnostic. The eighth must stay GREEN.

The tests never touch the production tree: every case gets its OWN
temporary root, and a FAKE godot executable stands in for the real one.

Usage:
    python tests/ci/standalone_runner_test.py
"""

import io
import os
import shutil
import stat
import subprocess
import sys
import tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", ".."))
RUNNER = os.path.join(REPO, "tools", "run_battle_ecs_suites.py")

if not os.path.isfile(RUNNER):
    print("the runner is missing: %s" % RUNNER)
    sys.exit(2)


# ---------------------------------------------------------------------
# The fake godot: it prints what the test says and exits with the code
# the test says.
#
# On Windows a `.py` file is NOT an executable, so the fake godot is a
# `.bat` that calls the interpreter. On POSIX it is a shell script with
# a shebang. The test therefore runs on both the CI runner and the
# development machine.
# ---------------------------------------------------------------------
FAKE_GODOT_PY = '''#!/usr/bin/env python3
import os
import sys

root = os.environ.get("FAKE_GODOT_ROOT", "")
script = ""
for a in sys.argv:
    if a.startswith("res://"):
        script = a[6:]

marker = os.path.join(root, "fake_output", script.replace("/", "_"))
if os.path.isfile(marker):
    with open(marker, "r", encoding="utf-8") as f:
        sys.stdout.write(f.read())

rc_file = os.path.join(root, "fake_rc", script.replace("/", "_"))
if os.path.isfile(rc_file):
    with open(rc_file, "r", encoding="utf-8") as f:
        sys.exit(int(f.read().strip() or "0"))
sys.exit(0)
'''

FAKE_GODOT_BAT = '''@echo off
python "%~dp0fake_godot.py" %*
'''


def write_fake_godot(root):
    """Writes the fake godot and returns its path."""
    py_path = os.path.join(root, "fake_godot.py")
    with io.open(py_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(FAKE_GODOT_PY)
    if os.name == "nt":
        bat_path = os.path.join(root, "fake_godot.bat")
        with io.open(bat_path, "w", encoding="utf-8", newline="\r\n") as f:
            f.write(FAKE_GODOT_BAT)
        return bat_path
    sh_path = os.path.join(root, "fake_godot.sh")
    launcher = "#!/bin/sh\nexec python3 " + py_path + " \"$@\"\n"
    with io.open(sh_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(launcher)
    os.chmod(sh_path, os.stat(sh_path).st_mode | stat.S_IEXEC | stat.S_IXGRP
             | stat.S_IXOTH)
    return sh_path


def make_suite(root, suite_rel, output, rc=0):
    """A fake suite: the output it prints and the code it exits with."""
    out_dir = os.path.join(root, "fake_output")
    rc_dir = os.path.join(root, "fake_rc")
    os.makedirs(out_dir, exist_ok=True)
    os.makedirs(rc_dir, exist_ok=True)
    key = suite_rel.replace("/", "_")
    with io.open(os.path.join(out_dir, key), "w", encoding="utf-8",
                 newline="\n") as f:
        f.write(output)
    with io.open(os.path.join(rc_dir, key), "w", encoding="utf-8",
                 newline="\n") as f:
        f.write(str(rc))
    suite_path = os.path.join(root, suite_rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(suite_path), exist_ok=True)
    with io.open(suite_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("extends SceneTree\n")


class Harness:
    def __init__(self):
        self.results = []
        self.roots = []

    def cleanup(self):
        for root in self.roots:
            shutil.rmtree(root, ignore_errors=True)

    def check(self, name, cond, detail=""):
        self.results.append((name, bool(cond), detail))
        print("  %s %s%s" % ("PASS" if cond else "FAIL", name,
                             (" — " + detail) if detail and not cond else ""))

    def case(self, name, suites, extra=None, expect_zero=False):
        """Runs the runner against the fake suites, in a FRESH root."""
        root = tempfile.mkdtemp(prefix="ci01_")
        self.roots.append(root)
        godot = write_fake_godot(root)
        for suite_rel, output, rc in suites:
            make_suite(root, suite_rel, output, rc)
        env = dict(os.environ)
        env["FAKE_GODOT_ROOT"] = root
        cmd = [sys.executable, RUNNER, "--godot", godot, "--root", root]
        if extra:
            cmd += extra
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env,
                              cwd=root, timeout=300)
        out = proc.stdout + proc.stderr
        if expect_zero:
            self.check(name, proc.returncode == 0,
                       "expected exit 0, got %d; the output was:\n%s"
                       % (proc.returncode, out[-1200:]))
        else:
            self.check(name, proc.returncode != 0,
                       "expected a non-zero exit, got 0; the output was:\n%s"
                       % out[-1200:])
        return proc.returncode, out


def main():
    h = Harness()
    try:
        print("=== CI-01: the standalone runner is fail-closed ===")

        # 1. discover() returned an empty list.
        code, out = h.case("an empty discovery is RED", [])
        h.check("the empty discovery is diagnosed",
                "RUNNER: RED" in out, "the output was:\n%s" % out[-800:])

        # 2. --only matched no suite.
        code, out = h.case(
            "an unmatched --only is RED",
            [("tests/battle_ecs/a_test.gd", "=== A: 1 pass / 0 fail ===\n", 0)],
            extra=["--only", "no_such_suite"])
        h.check("the unmatched filter is diagnosed",
                "RUNNER: RED" in out, "the output was:\n%s" % out[-800:])

        # 3. a suite with 0 pass / 0 fail and rc=0.
        code, out = h.case("a suite with zero assertions is RED",
                           [("tests/battle_ecs/zero_test.gd",
                             "=== ZERO: 0 pass / 0 fail ===\n", 0)])
        h.check("the zero-assertion suite is diagnosed",
                "RUNNER: RED" in out, "the output was:\n%s" % out[-800:])

        # 4. a suite with 0 pass / 0 fail and rc=1.
        code, out = h.case("a zero-assertion suite with rc=1 is RED",
                           [("tests/battle_ecs/zero_rc_test.gd",
                             "=== ZERO: 0 pass / 0 fail ===\n", 1)])

        # 5. a suite with rc=0 and no summary.
        code, out = h.case("a suite with no summary is RED",
                           [("tests/battle_ecs/silent_test.gd",
                             "the suite printed nothing useful\n", 0)])

        # 6. a suite with a successful summary AND a SCRIPT ERROR.
        code, out = h.case("a suite with a SCRIPT ERROR is RED",
                           [("tests/battle_ecs/error_test.gd",
                             "=== ERR: 3 pass / 0 fail ===\n"
                             "SCRIPT ERROR: something broke\n", 0)])

        # 7. several suites: one good, one empty.
        #
        # Without --keep-going the runner stops at the FIRST failure --
        # that is the intended behaviour -- so the check runs with
        # --keep-going, where BOTH suites are executed and the good
        # one is still reported as OK.
        code, out = h.case("a good suite beside an empty one is RED",
                           [("tests/battle_ecs/good_test.gd",
                             "=== GOOD: 5 pass / 0 fail ===\n", 0),
                            ("tests/battle_ecs/empty_test.gd",
                             "=== EMPTY: 0 pass / 0 fail ===\n", 0)],
                           extra=["--keep-going"])
        h.check("the good suite is still reported",
                "good_test.gd" in out and "5 pass / 0 fail" in out,
                "the output was:\n%s" % out[-800:])

        # 8. an ordinary suite with positive assertions.
        code, out = h.case("an ordinary suite stays GREEN",
                           [("tests/battle_ecs/ordinary_test.gd",
                             "=== ORDINARY: 7 pass / 0 fail ===\n", 0)],
                           expect_zero=True)
        h.check("the ordinary suite is reported as GREEN",
                "RUNNER: GREEN" in out, "the output was:\n%s" % out[-800:])

        print("")
        failed = [r for r in h.results if not r[1]]
        print("the CI-01 self-tests: %d, failed: %d"
              % (len(h.results), len(failed)))
        return 1 if failed else 0
    finally:
        h.cleanup()


if __name__ == "__main__":
    sys.exit(main())
