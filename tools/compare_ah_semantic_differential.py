#!/usr/bin/env python
"""B6.4c FULL A-H SEMANTIC DIFFERENTIAL.

Compares the BASELINE A-H probe output against the CANDIDATE A-H
probe output.

The baseline and candidate are two trees; the probe file is copied
into both so the SAME probe runs on each.

The candidate is projected back to LEGACY form first:
  1. strip DAMAGE_STARTED (type=12)
  2. reparent the stripped event's children to the DAMAGE_STARTED's
     own parent (by event_id, exact)
  3. subtract the inserted depth level(s) (transitive)
  4. renumber event_id / parent / root_action_id through a stable
     order map

Then EXACT equality is required on:
  world        (HP, alive, positions)
  rng          (seed, draw_count, internal state hex)
  emitter      (tick, next_root_action_id)
  result       (winner_team, termination_reason, ticks)
  events       (count, relative order, type, parent, root, depth,
                source, target, run-unit ids, amount, tag,
                from/to cell)

The emitter's next_event_id IS allowed to differ: the inserted
DAMAGE_STARTED layer consumes event ids. It is reported but not
treated as a failure.
"""
import json
import sys

DAMAGE_STARTED = 12

EVENT_FIELDS = ("type", "tick", "source_entity", "target_entity",
                "source_run_unit_id", "target_run_unit_id",
                "amount", "tag", "from_cell", "to_cell",
                "parent_event_id", "root_action_id", "chain_depth")

# Fields compared EXACTLY (event_id is renumbered, so it is
# compared through the order map instead).
WORLD_FIELDS = ("0_hp", "0_alive", "0_pos", "1_hp", "1_alive", "1_pos")
RNG_FIELDS = ("seed", "draw_count", "state_hex")
EMITTER_FIELDS = ("next_root_action_id", "current_tick")
RESULT_FIELDS = ("winner_team", "termination_reason", "ticks")


# The canonical eight scenarios. The differential is a comparison of
# THESE fixtures: a set that is missing one of them, or that carries
# one of them twice, is not the A-H differential.
CANONICAL_FIXTURES = (
    "A_scheduled_nonlethal",
    "B_scheduled_lethal",
    "C_counterattack",
    "D_aoo",
    "E_aoo_counter",
    "F_direct_damage",
    "G_real_burn",
    "H_full_battle",
)

# The mandatory sections of a snapshot.
MANDATORY_SECTIONS = ("world", "rng", "emitter", "result", "events")


class FixtureError(Exception):
    """A damaged fixture. It MUST fail the run, never disappear."""


def load_fixtures(path):
    """Loads the fixtures, STRICTLY.

    CI-02: the baseline swallowed a malformed fixture line and a
    malformed nested event, so a damaged record disappeared and the
    comparison silently compared a SHORTER list. Every line that
    carries the fixture marker MUST parse, and every nested event MUST
    parse.
    """
    fixtures = []
    for number, line in enumerate(
            open(path, encoding="utf-8", errors="replace"), 1):
        line = line.strip()
        if not line.startswith("{"):
            # The Godot diagnostics are not fixture data.
            continue
        try:
            snap = json.loads(line)
        except json.JSONDecodeError as error:
            raise FixtureError(
                "%s line %d: the fixture JSON is malformed: %s"
                % (path, number, error))
        if not isinstance(snap, dict):
            raise FixtureError(
                "%s line %d: a fixture must be a JSON object" % (path, number))
        name = snap.get("name")
        if not isinstance(name, str) or name == "":
            raise FixtureError(
                "%s line %d: the fixture has no name" % (path, number))
        for section in MANDATORY_SECTIONS:
            if section not in snap:
                raise FixtureError(
                    "%s line %d: the fixture %r has no %r section"
                    % (path, number, name, section))
        # The events are stored as JSON strings (one per event), so
        # they need a second parse. A malformed event is a FAILURE, not
        # a vanished event.
        evs = []
        for index, raw in enumerate(snap.get("events", [])):
            if isinstance(raw, str):
                try:
                    evs.append(json.loads(raw))
                except json.JSONDecodeError as error:
                    raise FixtureError(
                        "%s: the fixture %r has a malformed event %d: %s"
                        % (path, name, index, error))
            elif isinstance(raw, dict):
                evs.append(raw)
            else:
                raise FixtureError(
                    "%s: the fixture %r has an event %d of an unknown type"
                    % (path, name, index))
        snap["events"] = evs
        fixtures.append(snap)
    return fixtures


def check_fixture_set(fixtures, side):
    """The fixture set must be EXACTLY the canonical A-H, once each.

    CI-02: the baseline compared only the COUNT, so two sides that
    both carried the same SEVEN fixtures passed, and a duplicated name
    was compared against itself.
    """
    failures = []
    names = [f.get("name") for f in fixtures]
    seen = {}
    for name in names:
        seen[name] = seen.get(name, 0) + 1
    for name, count in sorted(seen.items()):
        if count > 1:
            failures.append("%s: the fixture %r appears %d times"
                            % (side, name, count))
    missing = [n for n in CANONICAL_FIXTURES if n not in seen]
    if missing:
        failures.append("%s: the canonical fixtures are missing: %s"
                        % (side, ", ".join(missing)))
    unknown = [n for n in sorted(seen) if n not in CANONICAL_FIXTURES]
    if unknown:
        failures.append("%s: the unknown fixtures are present: %s"
                        % (side, ", ".join(unknown)))
    return failures


def project(events):
    """Project a B6.4c trace back to legacy shape (id-exact)."""
    event_parent = {e["event_id"]: e["parent_event_id"] for e in events}
    stripped = set()
    for e in events:
        if e["type"] == DAMAGE_STARTED:
            stripped.add(e["event_id"])

    def legacy_parent(eid):
        pid = event_parent.get(eid)
        while pid is not None and pid in stripped:
            pid = event_parent.get(pid)
        return pid

    def stripped_above(eid):
        n = 0
        pid = event_parent.get(eid)
        while pid is not None and pid > 0:
            if pid in stripped:
                n += 1
            pid = event_parent.get(pid)
        return n

    out = []
    for e in events:
        if e["type"] == DAMAGE_STARTED:
            continue
        c = dict(e)
        c["parent_event_id"] = legacy_parent(e["event_id"])
        c["chain_depth"] = e["chain_depth"] - stripped_above(e["event_id"])
        out.append(c)
    # Renumber event_id, parent and root_action_id.
    order_map = {}
    for i, e in enumerate(out):
        order_map[e["event_id"]] = i + 1
    root_map = {}
    for e in out:
        if e["root_action_id"] not in root_map:
            root_map[e["root_action_id"]] = len(root_map) + 1
        e["root_action_id"] = root_map[e["root_action_id"]]
    for e in out:
        e["event_id"] = order_map[e["event_id"]]
        if e["parent_event_id"] in order_map:
            e["parent_event_id"] = order_map[e["parent_event_id"]]
    return out


def compare(base_path, cand_path):
    failures = []
    notes = []
    try:
        bases = load_fixtures(base_path)
    except FixtureError as error:
        return ["the baseline fixtures are damaged: %s" % error], notes
    try:
        cands = load_fixtures(cand_path)
    except FixtureError as error:
        return ["the candidate fixtures are damaged: %s" % error], notes
    # CI-02: the set must be EXACTLY the canonical A-H, once each, on
    # BOTH sides. A missing fixture, an unknown fixture or a duplicated
    # name blocks the PASS -- the baseline compared only the COUNT, so
    # two identical INCOMPLETE sets passed.
    failures.extend(check_fixture_set(bases, "the baseline"))
    failures.extend(check_fixture_set(cands, "the candidate"))
    if len(bases) != len(cands):
        failures.append("fixture count mismatch %d vs %d"
                        % (len(bases), len(cands)))
    if failures:
        return failures, notes
    for b, c in zip(bases, cands):
        name = b.get("name", "?")
        if b.get("name") != c.get("name"):
            failures.append("fixture name mismatch: %r vs %r"
                            % (b.get("name"), c.get("name")))
            continue
        # --- world ---
        for f in WORLD_FIELDS:
            if b["world"].get(f) != c["world"].get(f):
                failures.append("%s world.%s: base=%r cand=%r"
                                % (name, f, b["world"].get(f), c["world"].get(f)))
        # --- rng ---
        for f in RNG_FIELDS:
            if b["rng"].get(f) != c["rng"].get(f):
                failures.append("%s rng.%s: base=%r cand=%r"
                                % (name, f, b["rng"].get(f), c["rng"].get(f)))
        # --- emitter ---
        for f in EMITTER_FIELDS:
            if b["emitter"].get(f) != c["emitter"].get(f):
                failures.append("%s emitter.%s: base=%r cand=%r"
                                % (name, f, b["emitter"].get(f), c["emitter"].get(f)))
        # next_event_id is allowed to shift (the inserted layer
        # consumes ids) — reported, not a failure.
        if b["emitter"].get("next_event_id") != c["emitter"].get("next_event_id"):
            notes.append("%s emitter.next_event_id: base=%r cand=%r "
                         "(expected shift from the inserted layer)"
                         % (name, b["emitter"].get("next_event_id"),
                            c["emitter"].get("next_event_id")))
        # --- battle result ---
        if b.get("result") != c.get("result"):
            failures.append("%s result: base=%r cand=%r"
                            % (name, b.get("result"), c.get("result")))
        # --- events ---
        be = project(b["events"])
        ce = project(c["events"])
        # The number of distinct causal families (roots) must match
        # exactly: an extra root would mean the candidate created
        # a NEW causal family that the baseline never had. The
        # root renumbering inside project() would otherwise hide
        # that, so it is checked separately.
        b_roots = len(set(e["root_action_id"] for e in b["events"]))
        c_roots = len(set(e["root_action_id"] for e in c["events"]))
        if b_roots != c_roots:
            failures.append("%s causal families (roots): base=%d cand=%d"
                            % (name, b_roots, c_roots))
        if len(be) != len(ce):
            failures.append("%s legacy event count: base=%d cand=%d"
                            % (name, len(be), len(ce)))
            for e in be:
                failures.append("    BASE " + fmt(e))
            for e in ce:
                failures.append("    CAND " + fmt(e))
            continue
        for i, (x, y) in enumerate(zip(be, ce)):
            for f in EVENT_FIELDS:
                if x.get(f) != y.get(f):
                    failures.append("%s event %d %s: base=%r cand=%r"
                                    % (name, i, f, x.get(f), y.get(f)))
    return failures, notes


def fmt(e):
    return ("id=%s type=%s tag=%s parent=%s root=%s depth=%s src=%s tgt=%s "
            "amt=%s" % (e.get("event_id"), e.get("type"), e.get("tag"),
                        e.get("parent_event_id"), e.get("root_action_id"),
                        e.get("chain_depth"), e.get("source_entity"),
                        e.get("target_entity"), e.get("amount")))


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: compare_ah_semantic_differential.py BASELINE.jsonl CANDIDATE.jsonl")
        sys.exit(2)
    failures, notes = compare(sys.argv[1], sys.argv[2])
    for n in notes:
        print("  NOTE " + n)
    if failures:
        print("A-H SEMANTIC DIFFERENTIAL: FAIL (%d)" % len(failures))
        for f in failures:
            print("  " + f)
        sys.exit(1)
    # CI-02: the message reports the REAL number of compared
    # fixtures, not a fixed number.
    compared = len(json.loads("[]"))
    try:
        compared = len(load_fixtures(sys.argv[1]))
    except FixtureError:
        compared = 0
    print("A-H SEMANTIC DIFFERENTIAL: PASS "
          "(%d fixtures, legacy-projected traces + world + rng + "
          "emitter + result all identical)" % compared)
    sys.exit(0)