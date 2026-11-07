"""The negative controls of the A-H differential hardening (CI-02).

    NC-AH-A  ignore the baseline return code      -> semantic RED
    NC-AH-B  accept a missing fixture             -> semantic RED
    NC-AH-C  accept a duplicated fixture name     -> semantic RED
    NC-AH-D  skip a malformed nested JSON         -> semantic RED
    NC-AH-E  ignore a failed import               -> semantic RED

Each control mutates ONE production decision, runs the self-tests that
must catch it, and restores the original file.

The trustworthy RED is:

    rc != 0  AND  the self-tests report a failure  AND  0 Python
    syntax errors

A mutation that breaks the PARSING is INVALID, not a catch. A missing
anchor is a SKIP, and a SKIP is never evidence.

Usage:
    python tools/ah_negative_controls.py
"""

import io
import os
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    ".."))
COMPARATOR = os.path.join(REPO, "tools", "compare_ah_semantic_differential.py")
RUNNER = os.path.join(REPO, "tools", "run_ah_semantic_differential.py")
SELFTEST = os.path.join(REPO, "tests", "ci", "ah_differential_test.py")

MUTATIONS = [
    ("NC-AH-A", "the baseline return code is ignored",
     RUNNER,
     [("""    if rc_b != 0:
        print("A-H SEMANTIC DIFFERENTIAL: FAIL — the baseline probe exited "
              "rc=%d" % rc_b)
        return 1
""", """    if false:
        print("A-H SEMANTIC DIFFERENTIAL: FAIL — the baseline probe exited "
              "rc=%d" % rc_b)
        return 1
""")]),

    ("NC-AH-B", "a missing fixture is accepted",
     COMPARATOR,
     [("""    missing = [n for n in CANONICAL_FIXTURES if n not in seen]
    if missing:
        failures.append("%s: the canonical fixtures are missing: %s"
                        % (side, ", ".join(missing)))
""", """    missing = []
    if missing:
        failures.append("%s: the canonical fixtures are missing: %s"
                        % (side, ", ".join(missing)))
""")]),

    ("NC-AH-C", "a duplicated fixture name is accepted",
     COMPARATOR,
     [("""    for name, count in sorted(seen.items()):
        if count > 1:
            failures.append("%s: the fixture %r appears %d times"
                            % (side, name, count))
""", """    for name, count in sorted(seen.items()):
        if false:
            failures.append("%s: the fixture %r appears %d times"
                            % (side, name, count))
""")]),

    ("NC-AH-D", "a malformed nested JSON is skipped",
     COMPARATOR,
     [("""            if isinstance(raw, str):
                try:
                    evs.append(json.loads(raw))
                except json.JSONDecodeError as error:
                    raise FixtureError(
                        "%s: the fixture %r has a malformed event %d: %s"
                        % (path, name, index, error))
""", """            if isinstance(raw, str):
                try:
                    evs.append(json.loads(raw))
                except json.JSONDecodeError as error:
                    pass
""")]),

    ("NC-AH-E", "a failed import is ignored",
     RUNNER,
     [("""    if proc.returncode != 0:
        print("A-H SEMANTIC DIFFERENTIAL: FAIL — the Godot editor import "
              "failed in %s (rc=%d)" % (root, proc.returncode))
        return False
""", """    if false:
        print("A-H SEMANTIC DIFFERENTIAL: FAIL — the Godot editor import "
              "failed in %s (rc=%d)" % (root, proc.returncode))
        return False
""")]),
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
    failed = 0
    for line in out.splitlines():
        if line.startswith("the CI-02 comparator self-tests:"):
            parts = line.replace(",", "").split()
            failed = int(parts[-1])
    return proc.returncode, failed, out


def main():
    results = []
    originals = {}

    for name, title, target, edits in MUTATIONS:
        if target not in originals:
            originals[target] = read(target)
        original, original_lf = originals[target]

        mutated = original_lf
        ok = True
        for old, new in edits:
            if old not in mutated:
                print("%-10s SKIP: the anchor is missing in %s"
                      % (name, os.path.basename(target)))
                ok = False
                break
            if mutated.count(old) != 1:
                print("%-10s SKIP: the anchor is not unique in %s"
                      % (name, os.path.basename(target)))
                ok = False
                break
            mutated = mutated.replace(old, new, 1)
        if not ok:
            results.append((name, "SKIP", 0, 0))
            continue

        write(target, mutated.replace("\n", "\r\n")
              if "\r\n" in original else mutated)
        try:
            # The mutated file must still PARSE: a parse error is an
            # INVALID verdict, not a catch.
            compile(mutated, target, "exec")
            rc, failed, out = run_selftest()
            if failed > 0:
                verdict = "RED"
            elif "SyntaxError" in out or "IndentationError" in out:
                verdict = "INVALID"
            else:
                verdict = "MISSED"
            results.append((name, verdict, rc, failed))
        finally:
            write(target, original)

    rc, failed, out = run_selftest()
    if rc != 0 or failed != 0:
        results.append(("RESTORE", "NOT-GREEN", rc, failed))
    else:
        results.append(("RESTORE", "GREEN", rc, failed))

    print("")
    print("%-10s %-10s %5s %8s" % ("MUTATION", "VERDICT", "rc", "failed"))
    for name, verdict, rc, failed in results:
        print("%-10s %-10s %5d %8d" % (name, verdict, rc, failed))

    bad = [r for r in results if r[1] != "RED" and r[0] != "RESTORE"]
    total = len([r for r in results if r[0] != "RESTORE"])
    clean = len([r for r in results if r[1] == "RED"])
    print("")
    print("negative controls: %d, clean: %d, problems: %d"
          % (total, clean, len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
