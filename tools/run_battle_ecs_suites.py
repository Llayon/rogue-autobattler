#!/usr/bin/env python3
"""Run every standalone Battle ECS suite and report one summary.

The Phase-3 Battle ECS suites were never executed by CI: the workflow
ran the legacy suite, the characterization suite and the save suites,
but nothing under tests/battle_ecs/. A regression in the Phase-3
trigger spine could therefore reach the canonical branch unnoticed.

This runner discovers the suites automatically, so a NEW ordinary
standalone suite is picked up without touching a list of 50+ files.

Discovery: every `tests/battle_ecs/**/*.gd` whose top level is
`extends SceneTree`. A suite that is preloaded by another suite is
still run on its own: the modules are valid standalone suites and
running them twice is harmless.

For every suite the runner requires ALL of:
  - the process exit code is 0;
  - the output contains no `[FAIL]`;
  - the output contains no `SCRIPT ERROR`;
  - the output contains no `Parse Error`;
  - the output contains no unexpected `ERROR:`;
  - the output contains a parseable summary, so a suite that prints
    nothing cannot silently count as a pass;
  - the summary reports at least ONE passing assertion, so a suite
    that asserts nothing cannot silently count as a pass.

And for the run as a whole:
  - at least one suite was DISCOVERED (an empty discovery is RED);
  - the `--only` filter matched at least one suite (an unmatched
    filter is RED);
  - every discovered suite was EXECUTED and PASSED.

The suite COUNT is free to grow -- there is no hard-coded number --
but it must never be zero.

Usage:
    python tools/run_battle_ecs_suites.py [--godot PATH] [--root PATH]
                                          [--only SUBSTRING] [--keep-going]

Exit code 0 when every suite passed, 1 otherwise.
"""

import argparse
import io
import os
import re
import subprocess
import sys

SUMMARY_PATTERNS = [
    re.compile(r"(\d+)\s+pass(?:ed)?\s*/\s*(\d+)\s+fail(?:ed)?"),
    re.compile(r"(\d+)\s+pass(?:ed)?\s*,\s*(\d+)\s+fail(?:ed)?"),
]

ERROR_PATTERNS = [
    ("[FAIL]", re.compile(r"\[FAIL\]")),
    ("SCRIPT ERROR", re.compile(r"SCRIPT ERROR")),
    ("Parse Error", re.compile(r"Parse Error")),
    # Horizontal whitespace only: \s would also match a NEWLINE, so
    # the match could start on the blank line before the error and the
    # extracted line would be empty.
    ("ERROR:", re.compile(r"^[ 	]*ERROR:", re.MULTILINE)),
    # GameLog.error() prints "[ERROR] [tag] message" through
    # printerr(). Without this pattern the runner would not see the
    # production fail-safe logs — most importantly the B6.4c dangling
    # damage window invariant in battle_simulation.gd, which is the
    # strongest Phase-3 invariant there is.
    #
    # The pattern is scoped to the PHASE-3 FAIL-SAFE TAGS. A blanket
    # "[ERROR]" match would be a false-positive source: the legacy
    # save path logs "[ERROR] [save] resume_run diagnostic" when a
    # test deliberately asks for a slot that does not exist, and the
    # suite is expected to pass in that case.
    ("[ERROR] [battle_simulation]", re.compile(
        r"^[ 	]*\[ERROR\] \[battle_simulation\]", re.MULTILINE)),
    ("[ERROR] [combatant]", re.compile(
        r"^[ 	]*\[ERROR\] \[combatant\]", re.MULTILINE)),
]

# The exact baseline error lines that the headless renderer emits on
# exit in this repository. They are matched BY EXACT LINE, so a new
# error — including a new resource leak — is still reported and still
# fails the run.
#
# The allowlist is intentionally narrow: only the known signatures of
# the headless dummy renderer and of the one suite that keeps a
# resource alive at exit.
KNOWN_BASELINE_ERROR_LINES = frozenset([
    "ERROR: 2 RID allocations of type 'N16RendererViewport8ViewportE' were leaked at exit.",
    "ERROR: 2 RID allocations of type 'PN13RendererDummy14TextureStorage12DummyTextureE' were leaked at exit.",
    "ERROR: 2 RID allocations of type 'N17RendererSceneCull8ScenarioE' were leaked at exit.",
    "ERROR: 1 resources still in use at exit (run with --verbose for details).",
])

# SPECIAL PROBES: files under tests/battle_ecs/ that are NOT suites.
#
# They are `extends SceneTree` files that dump a machine-readable
# snapshot for a COMPARATOR to read (the A-H semantic differential
# probe writes JSON per fixture). They print no pass/fail summary,
# so they cannot be judged by the suite criteria.
#
# They are listed EXPLICITLY and on purpose: an ordinary new suite
# must be picked up automatically, but a probe is a different kind of
# artefact and has to be named here. Each entry names the comparator
# that consumes its output.
SPECIAL_PROBES = {
    "tests/battle_ecs/effects/b64c_ah_diff_probe.gd":
        "consumed by the A-H semantic differential comparator",
}


def discover(root):
    base = os.path.join(root, "tests")
    found = []
    for dirpath, _dirs, files in os.walk(base):
        for name in sorted(files):
            if not name.endswith(".gd"):
                continue
            path = os.path.join(dirpath, name)
            try:
                text = io.open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            if re.search(r"^extends\s+SceneTree\b", text, re.MULTILINE):
                rel = os.path.relpath(path, root).replace("\\", "/")
                if rel in SPECIAL_PROBES:
                    continue
                found.append(path)
    return sorted(found)


def parse_summary(text):
    for pattern in SUMMARY_PATTERNS:
        matches = pattern.findall(text)
        if matches:
            passed, failed = matches[-1]
            return int(passed), int(failed)
    return None


def find_errors(text):
    """Returns a list of (label, offending line) pairs."""
    found = []
    for label, pattern in ERROR_PATTERNS:
        for match in pattern.finditer(text):
            start = text.rfind("\n", 0, match.start()) + 1
            end = text.find("\n", match.start())
            if end < 0:
                end = len(text)
            line = text[start:end].strip()
            if label == "ERROR:" and line in KNOWN_BASELINE_ERROR_LINES:
                continue
            found.append((label, line))
    return found


def run_suite(godot, root, path):
    rel = os.path.relpath(path, root).replace("\\", "/")
    proc = subprocess.run(
        [godot, "--headless", "--path", root, "--script", "res://" + rel],
        capture_output=True, text=True, timeout=1800)
    text = proc.stdout + proc.stderr
    return proc.returncode, text


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=os.environ.get(
        "GODOT", "godot"), help="the Godot 4.7 executable")
    parser.add_argument("--root", default=".", help="the project root")
    parser.add_argument("--only", default="", help="run only the suites whose path contains this substring")
    parser.add_argument("--keep-going", action="store_true",
                        help="run every suite even after a failure")
    args = parser.parse_args(argv[1:])

    root = os.path.abspath(args.root)
    discovered = discover(root)
    suites = discovered
    if args.only:
        suites = [s for s in suites if args.only in s.replace("\\", "/")]

    # CI-01: the runner must PROVE that it ran something. An empty
    # discovery -- no tests directory, a wrong root, a filter that
    # matched nothing -- is a RED, not a GREEN: the baseline reported
    # `RUNNER: GREEN` and exit code 0 for exactly that case.
    if not suites:
        print("=== Battle ECS suite runner ===")
        print("godot    : %s" % args.godot)
        print("root     : %s" % root)
        print("discovered: %d suites" % len(discovered))
        if args.only:
            print("filter   : %r" % args.only)
        print("")
        if args.only:
            print("RUNNER: RED — the --only filter matched NO suite")
        else:
            print("RUNNER: RED — the discovery found NO suite")
        print("A runner that discovered nothing cannot prove that it ran "
              "anything.")
        return 1

    print("=== Battle ECS suite runner ===")
    print("godot    : %s" % args.godot)
    print("root     : %s" % root)
    print("expected : %d suites" % len(suites))
    if SPECIAL_PROBES:
        print("probes   : %d (not suites, judged by a comparator)"
              % len(SPECIAL_PROBES))
        for probe, purpose in sorted(SPECIAL_PROBES.items()):
            print("            %s — %s" % (probe, purpose))
    print("")

    executed = 0
    passed = 0
    failed = 0
    unparsed = 0
    total_assertions = 0
    total_failed_assertions = 0
    failures = []

    for path in suites:
        rel = os.path.relpath(path, root).replace("\\", "/")
        try:
            rc, text = run_suite(args.godot, root, path)
        except subprocess.TimeoutExpired:
            failed += 1
            executed += 1
            failures.append((rel, "TIMEOUT"))
            print("  [FAIL] %s — TIMEOUT" % rel)
            if not args.keep_going:
                break
            continue
        executed += 1
        summary = parse_summary(text)
        errors = find_errors(text)
        if summary is None:
            unparsed += 1
            failed += 1
            failures.append((rel, "no parseable summary"))
            print("  [FAIL] %s — no parseable summary" % rel)
            continue
        total_assertions += summary[0]
        total_failed_assertions += summary[1]
        problems = []
        if rc != 0:
            problems.append("rc=%d" % rc)
        if summary[1] > 0:
            problems.append("%d failed assertions" % summary[1])
        # CI-01: a suite that asserts NOTHING is not a pass. `0 pass /
        # 0 fail` means the suite never proved anything -- it is the
        # shape of a suite that silently lost its body.
        if summary[0] <= 0:
            problems.append("the suite asserted nothing (0 passing assertions)")
        for label, line in errors:
            problems.append("%s (%s)" % (label, line[:90]))
        if problems:
            failed += 1
            failures.append((rel, ", ".join(problems)))
            print("  [FAIL] %s — %s" % (rel, ", ".join(problems)))
            for line in text.splitlines():
                if "[FAIL]" in line or "SCRIPT ERROR" in line or "Parse Error" in line:
                    print("         %s" % line.strip()[:150])
        else:
            passed += 1
            print("  [OK]   %s — %d pass / %d fail" % (rel, summary[0], summary[1]))
        if not args.keep_going and failed:
            break

    print("")
    print("=== SUMMARY ===")
    print("expected : %d" % len(suites))
    print("executed : %d" % executed)
    # CI-01: the counts must agree. A runner that executed fewer
    # suites than it discovered did not run the whole set, and the
    # difference must be visible.
    if executed != len(suites):
        print("MISMATCH : executed %d of %d discovered suites"
              % (executed, len(suites)))
    print("passed   : %d" % passed)
    print("failed   : %d" % failed)
    print("unparsed : %d" % unparsed)
    print("assertions: %d pass / %d fail" % (total_assertions, total_failed_assertions))
    if failures:
        print("")
        print("FAILED SUITES:")
        for rel, reason in failures:
            print("  %s — %s" % (rel, reason))
        print("")
        print("RUNNER: RED")
        return 1
    # CI-01: the runner may only report GREEN when it proves the whole
    # contract. The empty-discovery case is handled before the loop,
    # and the per-suite checks guarantee a positive assertion count,
    # so the remaining invariant is the count agreement.
    if executed != len(suites) or passed != executed:
        print("")
        print("RUNNER: RED — the counts do not agree: %d discovered, "
              "%d executed, %d passed" % (len(suites), executed, passed))
        return 1
    print("")
    print("RUNNER: GREEN")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
