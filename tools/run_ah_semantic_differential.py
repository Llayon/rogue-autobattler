#!/usr/bin/env python3
"""Run the A-H semantic differential between a baseline tree and a candidate.

The A-H differential is the strongest semantic gate of the Phase-3
trigger spine: the SAME probe runs on the baseline tree and on the
candidate tree, the candidate is projected back to legacy form, and
EXACT equality is required on the world state, the RNG state, the
emitter counters, the battle result and the full event trace.

The probe itself is a SPECIAL PROBE, not a suite: it prints a JSON
snapshot per fixture and has no pass/fail summary, so the suite runner
deliberately skips it. This script is its counterpart: it runs the
probe on both trees and compares the output.

The comparator is tools/compare_ah_semantic_differential.py.

CI-02 -- the differential is FAIL-CLOSED:

  - a probe that exits NON-ZERO blocks the PASS, even when it printed
    valid snapshots;
  - the fixture set must be EXACTLY the canonical A-H, once each, on
    BOTH sides (the comparator enforces the names, this script reports
    them);
  - a Godot editor import that fails blocks the run;
  - the BASELINE worktree is never written to: the probe runs in an
    isolated COPY of it, and the copy is removed afterwards.

Usage:
    python tools/run_ah_semantic_differential.py --baseline PATH --candidate PATH
                                                  [--godot PATH] [--keep-going]

Exit code 0 when the differential passes, 1 otherwise.
"""

import argparse
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

PROBE_REL = "tests/battle_ecs/effects/b64c_ah_diff_probe.gd"
COMPARATOR_REL = "tools/compare_ah_semantic_differential.py"


def run_probe(godot, root):
    proc = subprocess.run(
        [godot, "--headless", "--path", root, "--script", "res://" + PROBE_REL],
        capture_output=True, text=True, timeout=1800)
    lines = [line for line in (proc.stdout + proc.stderr).splitlines()
             if line.startswith("{")]
    return proc.returncode, lines


def copy_tree(source, target):
    """Copies a project tree WITHOUT the .git directory.

    The baseline worktree must never be written to, so the probe runs
    in an isolated copy. The `.godot` cache is copied as well: it is
    the import registry the probe needs.
    """
    shutil.copytree(source, target, symlinks=True,
                    ignore=shutil.ignore_patterns(".git", "__pycache__"))


def fixture_ids(path):
    """The fixture names of a JSONL file, for the report."""
    ids = []
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            snap = json.loads(line)
        except ValueError:
            continue
        if isinstance(snap, dict) and isinstance(snap.get("name"), str):
            ids.append(snap["name"])
    return ids


def import_cache(godot, root):
    """Builds the project cache when it is missing.

    A freshly checked-out worktree has NO .godot cache, so Godot
    cannot resolve the class_name registry and the probe fails with
    "Parse Error: Could not resolve external class member". The editor
    import builds that registry.

    CI-02: a failed import is a FAILURE. The baseline ignored the
    return code, so a broken import led to a probe that produced
    nothing -- and the "no fixtures" check then reported the wrong
    reason.
    """
    if os.path.isdir(os.path.join(root, ".godot")):
        return True
    print("importing the project cache in %s ..." % root)
    proc = subprocess.run([godot, "--headless", "--path", root,
                           "--editor", "--quit"],
                          capture_output=True, text=True, timeout=1800)
    if proc.returncode != 0:
        print("A-H SEMANTIC DIFFERENTIAL: FAIL — the Godot editor import "
              "failed in %s (rc=%d)" % (root, proc.returncode))
        return False
    return True


def run_differential(args, baseline, candidate):
    """Runs the probes on both trees and compares the results."""
    for root in (baseline, candidate):
        if not import_cache(args.godot, root):
            return 1

    out_dir = os.path.join(os.environ.get("TEMP", "/tmp"),
                           "ah_semantic_differential")
    os.makedirs(out_dir, exist_ok=True)
    base_jsonl = os.path.join(out_dir, "baseline.jsonl")
    cand_jsonl = os.path.join(out_dir, "candidate.jsonl")

    rc_b, base_lines = run_probe(args.godot, baseline)
    with io.open(base_jsonl, "w", encoding="utf-8") as fh:
        fh.write("\n".join(base_lines))
    print("baseline fixtures  : %d (rc=%s)" % (len(base_lines), rc_b))

    rc_c, cand_lines = run_probe(args.godot, candidate)
    with io.open(cand_jsonl, "w", encoding="utf-8") as fh:
        fh.write("\n".join(cand_lines))
    print("candidate fixtures : %d (rc=%s)" % (len(cand_lines), rc_c))
    print("")

    if not base_lines or not cand_lines:
        print("A-H SEMANTIC DIFFERENTIAL: FAIL — a probe produced no fixtures")
        return 1

    # CI-02: a probe that exits NON-ZERO blocks the PASS, even when it
    # printed valid snapshots. The baseline printed the return codes
    # and then ignored them.
    if rc_b != 0:
        print("A-H SEMANTIC DIFFERENTIAL: FAIL — the baseline probe exited "
              "rc=%d" % rc_b)
        return 1
    if rc_c != 0:
        print("A-H SEMANTIC DIFFERENTIAL: FAIL — the candidate probe exited "
              "rc=%d" % rc_c)
        return 1

    comparator = os.path.join(candidate, COMPARATOR_REL)
    if not os.path.isfile(comparator):
        print("A-H SEMANTIC DIFFERENTIAL: FAIL — the comparator is missing")
        return 1

    proc = subprocess.run([sys.executable, comparator, base_jsonl, cand_jsonl],
                          capture_output=True, text=True)
    print(proc.stdout.rstrip())
    if proc.stderr.strip():
        print(proc.stderr.rstrip())
    if proc.returncode != 0:
        return proc.returncode

    # CI-02: the report names the fixtures that were really compared.
    print("baseline fixture ids  : %s" % ", ".join(fixture_ids(base_jsonl)))
    print("candidate fixture ids : %s" % ", ".join(fixture_ids(cand_jsonl)))
    return 0


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--keep-going", action="store_true")
    args = parser.parse_args(argv[1:])

    baseline = os.path.abspath(args.baseline)
    candidate = os.path.abspath(args.candidate)

    for root in (baseline, candidate):
        if not os.path.isdir(root):
            print("A-H differential: %s is not a directory" % root)
            return 2

    print("=== A-H SEMANTIC DIFFERENTIAL ===")
    print("baseline  : %s" % baseline)
    print("candidate : %s" % candidate)
    print("")

    # The SAME probe file must run on both trees.
    #
    # CI-02: the baseline copied the probe INTO the baseline worktree,
    # which modified a tracked file of the historical baseline. The
    # baseline is now an ISOLATED COPY: the original worktree is never
    # written to, and the copy is removed afterwards.
    workdir = tempfile.mkdtemp(prefix="ah_baseline_")
    try:
        isolated = os.path.join(workdir, "baseline")
        copy_tree(baseline, isolated)
        probe_src = os.path.join(candidate, PROBE_REL)
        probe_dst = os.path.join(isolated, PROBE_REL)
        if os.path.isfile(probe_src):
            shutil.copyfile(probe_src, probe_dst)
        return run_differential(args, isolated, candidate)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
