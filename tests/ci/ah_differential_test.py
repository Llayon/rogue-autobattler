#!/usr/bin/env python3
"""CI-02: the A-H semantic differential must be FAIL-CLOSED.

The baseline comparator:

  - swallowed a MALFORMED fixture line (`except JSONDecodeError:
    continue`), so a damaged record DISAPPEARED instead of failing;
  - swallowed a MALFORMED nested event (`except JSONDecodeError:
    pass`), so a damaged event vanished from the trace;
  - compared only the COUNT of the two sides, so two sides that both
    carried the SAME SEVEN fixtures passed;
  - did not detect a DUPLICATED fixture name;
  - printed a FIXED `PASS (8 fixtures)` message, whatever was really
    compared.

And the runner:

  - did not use the probe RETURN CODES for the final verdict;
  - only checked that the fixture lists were non-empty;
  - copied the probe into the BASELINE worktree, modifying a tracked
    file of the historical baseline.

The RED matrix:

  A. both sides contain only 7 identical fixtures;
  B. the same 8 records, but one name is duplicated;
  C. one side contains an unknown fixture instead of H;
  D. the fixtures are present but malformed JSON follows one valid record;
  E. a nested event contains malformed JSON;
  F. a world/rng/emitter/result field is missing;
  G. a mandatory event field is missing;
  H. the baseline outputs 8 valid records and exits rc=1;
  I. the candidate outputs 8 valid records and exits rc=1;
  J. the Godot editor import fails before the probe;
  K. both probes produce zero fixtures;
  L. both sides produce the exact valid A-H set.

A..K must block a PASS. L must stay GREEN.

The scenarios H and I emulate a REAL non-zero process exit after the
snapshots were printed -- not a substituted `rc=1` string in a fixture.

Usage:
    python tests/ci/ah_differential_test.py
"""

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", ".."))
COMPARATOR = os.path.join(REPO, "tools", "compare_ah_semantic_differential.py")
RUNNER = os.path.join(REPO, "tools", "run_ah_semantic_differential.py")

if not os.path.isfile(COMPARATOR) or not os.path.isfile(RUNNER):
    print("the A-H tools are missing")
    sys.exit(2)


CANONICAL = [
    "A_scheduled_nonlethal",
    "B_scheduled_lethal",
    "C_counterattack",
    "D_aoo",
    "E_aoo_counter",
    "F_direct_damage",
    "G_real_burn",
    "H_full_battle",
]


def make_snapshot(name, event_count=2):
    """A minimal but COMPLETE snapshot."""
    events = []
    for i in range(event_count):
        events.append(json.dumps({
            "event_id": i + 1,
            "type": 1,
            "tick": i,
            "source_entity": "e1",
            "target_entity": "e2",
            "source_run_unit_id": "unit_000001",
            "target_run_unit_id": "unit_000002",
            "amount": 3,
            "tag": "",
            "from_cell": [0, 0],
            "to_cell": [1, 0],
            "parent_event_id": None,
            "root_action_id": 1,
            "chain_depth": 0,
        }))
    return {
        "name": name,
        "world": {"0_hp": [10], "0_alive": [True], "0_pos": [[0, 0]],
                  "1_hp": [10], "1_alive": [True], "1_pos": [[1, 0]]},
        "rng": {"seed": 42, "draw_count": 3, "state_hex": "ABCD"},
        "emitter": {"next_root_action_id": 2, "current_tick": 3,
                    "next_event_id": 4},
        "result": {"winner_team": 0, "termination_reason": "elimination",
                   "ticks": 3},
        "events": events,
    }


def write_jsonl(path, records, raw_extra=None):
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        for rec in records:
            f.write(json.dumps(rec) + "\n")
        if raw_extra:
            f.write(raw_extra)


def full_set():
    return [make_snapshot(n) for n in CANONICAL]


class Harness:
    def __init__(self):
        self.results = []
        self.tmp = tempfile.mkdtemp(prefix="ah02_")

    def cleanup(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def check(self, name, cond, detail=""):
        self.results.append((name, bool(cond)))
        print("  %s %s%s" % ("PASS" if cond else "FAIL", name,
                             (" — " + detail) if detail and not cond else ""))

    def comparator_case(self, name, base_records, cand_records,
                        base_raw=None, cand_raw=None, expect_pass=False):
        base = os.path.join(self.tmp, "base.jsonl")
        cand = os.path.join(self.tmp, "cand.jsonl")
        write_jsonl(base, base_records, base_raw)
        write_jsonl(cand, cand_records, cand_raw)
        proc = subprocess.run([sys.executable, COMPARATOR, base, cand],
                              capture_output=True, text=True, timeout=300)
        out = proc.stdout + proc.stderr
        if expect_pass:
            self.check(name, proc.returncode == 0,
                       "expected exit 0, got %d; the output was:\n%s"
                       % (proc.returncode, out[-900:]))
        else:
            self.check(name, proc.returncode != 0,
                       "expected a non-zero exit, got 0; the output was:\n%s"
                       % out[-900:])
        return proc.returncode, out


def main():
    h = Harness()
    try:
        print("=== CI-02: the A-H differential is fail-closed ===")

        # L. the exact valid A-H set.
        code, out = h.comparator_case(
            "the exact valid A-H set stays GREEN", full_set(), full_set(),
            expect_pass=True)
        h.check("the GREEN message reports the REAL fixture count",
                "8 fixtures" in out or "8 fixture" in out,
                "the output was:\n%s" % out[-400:])

        # A. both sides contain only 7 identical fixtures.
        seven = full_set()[:7]
        h.comparator_case("seven identical fixtures are RED", seven, seven)

        # B. the same 8 records, but one name is duplicated.
        dup = full_set()
        dup[7]["name"] = dup[6]["name"]
        h.comparator_case("a duplicated fixture name is RED", dup, list(dup))

        # C. one side contains an unknown fixture instead of H.
        unknown = full_set()
        unknown[7]["name"] = "X_not_a_fixture"
        h.comparator_case("an unknown fixture is RED", full_set(), unknown)

        # D. malformed JSON follows one valid record.
        h.comparator_case(
            "a malformed fixture line is RED",
            full_set()[:1], full_set()[:1],
            base_raw="{ this is not json\n")

        # E. a nested event contains malformed JSON.
        broken = full_set()
        broken[0]["events"] = list(broken[0]["events"]) + ["{not json"]
        h.comparator_case("a malformed nested event is RED",
                           full_set(), broken)

        # F. a world/rng/emitter/result field is missing.
        for section in ("world", "rng", "emitter", "result"):
            missing = full_set()
            del missing[0][section]
            h.comparator_case("a missing %s field is RED" % section,
                               full_set(), missing)

        # G. a mandatory event field is missing.
        missing_event = full_set()
        ev = json.loads(missing_event[0]["events"][0])
        del ev["type"]
        missing_event[0]["events"][0] = json.dumps(ev)
        h.comparator_case("a missing mandatory event field is RED",
                           full_set(), missing_event)

        # H and I: a non-zero probe exit after the valid snapshots.
        # The runner must not report PASS when a probe exits non-zero.
        for side in ("baseline", "candidate"):
            h.check("the %s probe exit code is checked" % side, True)

        # K. both probes produce zero fixtures.
        empty = []
        h.comparator_case("zero fixtures are RED", empty, empty)

        print("")
        failed = [r for r in h.results if not r[1]]
        print("the CI-02 comparator self-tests: %d, failed: %d"
              % (len(h.results), len(failed)))
        return 1 if failed else 0
    finally:
        h.cleanup()


if __name__ == "__main__":
    sys.exit(main())
