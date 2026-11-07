"""The negative controls of the CI-01 hardening.

    NC-CI01-A  remove the empty-discovery guard      -> semantic RED
    NC-CI01-B  remove the positive-assertion guard   -> semantic RED
    NC-CI01-C  remove the unmatched --only guard     -> semantic RED

Each control mutates ONE production decision in
`tools/run_battle_ecs_suites.py`, runs the self-tests that must catch
it, and restores the original file.

The trustworthy RED is:

    rc != 0  AND  the self-tests report a failure  AND  0 Python
    syntax errors

A mutation that breaks the PARSING is INVALID, not a catch. A
missing anchor is a SKIP, and a SKIP is never evidence.

Usage:
    python tools/ci_negative_controls.py
"""

import io
import os
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    ".."))
RUNNER = os.path.join(REPO, "tools", "run_battle_ecs_suites.py")
SELFTEST = os.path.join(REPO, "tests", "ci", "standalone_runner_test.py")

MUTATIONS = [
    ("NC-CI01-A", "the empty-discovery guard is removed",
     [("    if not suites:\n",
       "    if False:\n")]),

    ("NC-CI01-B", "the positive-assertion guard is removed",
     [("        if summary[0] <= 0:\n"
       "            problems.append(\"the suite asserted nothing (0 passing assertions)\")\n",
       "        if False:\n"
       "            problems.append(\"the suite asserted nothing (0 passing assertions)\")\n")]),

    ("NC-CI01-C", "the unmatched --only filter is ignored",
     [("    if args.only:\n"
       "        suites = [s for s in suites if args.only in s.replace(\"\\\\\", \"/\")]\n",
       "    if args.only:\n"
       "        # MUTATED: the filter is ignored, so an unmatched filter\n"
       "        # runs EVERYTHING and never proves that it matched nothing.\n"
       "        pass\n")]),
]


def read(path):
    with io.open(path, encoding="utf-8", newline="") as f:
        raw = f.read()
    return raw, raw.replace("\r\n", "\n")


def write(path, text):
    with io.open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def run_selftest():
    proc = subprocess.run([sys.executable, SELFTEST], capture_output=True,
                          text=True, cwd=REPO, timeout=600)
    out = proc.stdout + proc.stderr
    # The self-tests report their own verdict.
    failed = 0
    for line in out.splitlines():
        if line.startswith("the CI-01 self-tests:"):
            parts = line.replace(",", "").split()
            failed = int(parts[-1])
    return proc.returncode, failed, out


def main():
    results = []
    original, original_lf = read(RUNNER)

    for name, title, edits in MUTATIONS:
        mutated = original_lf
        ok = True
        for old, new in edits:
            if old not in mutated:
                print("%-12s SKIP: the anchor is missing" % name)
                ok = False
                break
            if mutated.count(old) != 1:
                print("%-12s SKIP: the anchor is not unique" % name)
                ok = False
                break
            mutated = mutated.replace(old, new, 1)
        if not ok:
            results.append((name, "SKIP", 0, 0))
            continue

        write(RUNNER, mutated.replace("\n", "\r\n")
              if "\r\n" in original else mutated)
        try:
            # The mutated file must still PARSE: a parse error is an
            # INVALID verdict, not a catch.
            compile(mutated, RUNNER, "exec")
            rc, failed, out = run_selftest()
            if failed > 0:
                verdict = "RED"
            elif "SyntaxError" in out or "IndentationError" in out:
                verdict = "INVALID"
            else:
                verdict = "MISSED"
            results.append((name, verdict, rc, failed))
        finally:
            write(RUNNER, original)

    rc, failed, out = run_selftest()
    if rc != 0 or failed != 0:
        results.append(("RESTORE", "NOT-GREEN", rc, failed))
    else:
        results.append(("RESTORE", "GREEN", rc, failed))

    print("")
    print("%-12s %-10s %5s %8s" % ("MUTATION", "VERDICT", "rc", "failed"))
    for name, verdict, rc, failed in results:
        print("%-12s %-10s %5d %8d" % (name, verdict, rc, failed))

    # The RESTORE row is not a control: it is the proof that the
    # original file came back and the self-tests are green again.
    bad = [r for r in results if r[1] not in ("RED",) and r[0] != "RESTORE"]
    total = len([r for r in results if r[0] != "RESTORE"])
    clean = len([r for r in results if r[1] == "RED"])
    print("")
    print("negative controls: %d, clean: %d, problems: %d"
          % (total, clean, len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
