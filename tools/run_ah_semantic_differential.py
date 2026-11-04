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

Usage:
    python tools/run_ah_semantic_differential.py --baseline PATH --candidate PATH
                                                  [--godot PATH] [--keep-going]

Exit code 0 when the differential passes, 1 otherwise.
"""

import argparse
import io
import os
import re
import shutil
import subprocess
import sys

PROBE_REL = "tests/battle_ecs/effects/b64c_ah_diff_probe.gd"
COMPARATOR_REL = "tools/compare_ah_semantic_differential.py"


def run_probe(godot, root):
    proc = subprocess.run(
        [godot, "--headless", "--path", root, "--script", "res://" + PROBE_REL],
        capture_output=True, text=True, timeout=1800)
    lines = [line for line in (proc.stdout + proc.stderr).splitlines()
             if line.startswith("{")]
    return proc.returncode, lines


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
    probe_src = os.path.join(candidate, PROBE_REL)
    probe_dst = os.path.join(baseline, PROBE_REL)
    if os.path.isfile(probe_src):
        shutil.copyfile(probe_src, probe_dst)

    # A freshly checked-out worktree has NO .godot cache, so Godot
    # cannot resolve the class_name registry and the probe fails with
    # "Parse Error: Could not resolve external class member". The
    # editor import builds that registry.
    #
    # The candidate tree normally already has the cache (the CI job
    # imports it), but the baseline worktree never does.
    for root in (baseline, candidate):
        if not os.path.isdir(os.path.join(root, ".godot")):
            print("importing the project cache in %s ..." % root)
            subprocess.run([args.godot, "--headless", "--path", root,
                            "--editor", "--quit"],
                           capture_output=True, text=True, timeout=1800)

    out_dir = os.path.join(os.environ.get("TEMP", "/tmp"), "ah_semantic_differential")
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

    comparator = os.path.join(candidate, COMPARATOR_REL)
    if not os.path.isfile(comparator):
        print("A-H SEMANTIC DIFFERENTIAL: FAIL — the comparator is missing")
        return 1

    proc = subprocess.run([sys.executable, comparator, base_jsonl, cand_jsonl],
                          capture_output=True, text=True)
    print(proc.stdout.rstrip())
    if proc.stderr.strip():
        print(proc.stderr.rstrip())
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv))
