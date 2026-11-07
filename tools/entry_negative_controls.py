"""The negative controls of the battle-entry guard (RUN-ENTRY-01).

    NC-ENTRY-A  remove the merchant guard        -> semantic RED
    NC-ENTRY-B  allow a MAP battle without a selection -> semantic RED
    NC-ENTRY-C  consume the battle readiness incorrectly -> semantic RED
    NC-ENTRY-D  allow a repeat combat from a completed encounter -> semantic RED
    NC-ENTRY-E  reintroduce the SPACE double-handling -> semantic RED

Each control mutates ONE production decision, runs the suite that must
catch it, and restores the original file.

The trustworthy RED is:

    rc != 0  AND  a semantic [FAIL]  AND  0 parse errors
    AND  0 SCRIPT ERROR lines

A mutation that breaks the PARSING is INVALID, not a catch. A missing
anchor is a SKIP, and a SKIP is never evidence.

Usage:
    python tools/entry_negative_controls.py
"""

import io
import os
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    ".."))
GODOT = os.environ.get("GODOT",
                       r"D:\Programms\Max\Godot_v4.7-stable_win64.exe"
                       r"\Godot_v4.7-stable_win64_console.exe")

CONTROLLER = os.path.join(REPO, "core", "progression", "run_controller.gd")
ENTRY_SUITE = "res://tests/run_integrity/battle_entry_guard_test.gd"
INPUT_SUITE = "res://tests/run_integrity/merchant_input_path_test.gd"

MUTATIONS = [
    ("NC-ENTRY-A", "the merchant guard is removed",
     CONTROLLER, ENTRY_SUITE,
     [("""	if state != null and state.just_visited_merchant:
		return false
""", """	if false:
		return false
""")]),

    ("NC-ENTRY-B", "a MAP battle without a selection is allowed",
     CONTROLLER, ENTRY_SUITE,
     [("""	if phase != Phase.PREP:
		return false
""", """	if false:
		return false
""")]),

    ("NC-ENTRY-C", "the battle readiness is consumed incorrectly",
     CONTROLLER, ENTRY_SUITE,
     [("""	if state == null or state.current_encounter_id == -1:
		return true
""", """	if state == null:
		return true
""")]),

    ("NC-ENTRY-D", "a repeat combat from a completed encounter is allowed",
     CONTROLLER, ENTRY_SUITE,
     [("""	var node: EncounterNode = encounter_map.get_node(state.current_encounter_id)
	if node == null:
		return false
	return node.is_combat()
""", """	var node: EncounterNode = encounter_map.get_node(state.current_encounter_id)
	if node == null:
		return true
	return true
""")]),

    ("NC-ENTRY-E", "the shop closes without releasing the merchant context",
     os.path.join(REPO, "scenes", "shop", "shop_scene.gd"), INPUT_SUITE,
     [("""	if run_controller != null:
		run_controller.exit_shop_to_map()
	visible = false
""", """	visible = false
""")]),
]


def read(path):
    with io.open(path, encoding="utf-8", newline="") as f:
        raw = f.read()
    return raw, raw.replace("\r\n", "\n")


def write(path, text):
    with io.open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def run_suite(suite):
    proc = subprocess.run([GODOT, "--headless", "--path", REPO,
                           "--script", suite],
                          capture_output=True, text=True, cwd=REPO,
                          timeout=900)
    out = proc.stdout + proc.stderr
    fails = out.count("[FAIL]")
    errors = (out.count("SCRIPT ERROR") + out.count("Parse Error"))
    return proc.returncode, fails, errors, out


def main():
    results = []
    originals = {}

    for name, title, target, suite, edits in MUTATIONS:
        if target not in originals:
            originals[target] = read(target)
        original, original_lf = originals[target]

        mutated = original_lf
        ok = True
        for old, new in edits:
            if old not in mutated:
                print("%-12s SKIP: the anchor is missing in %s"
                      % (name, os.path.basename(target)))
                ok = False
                break
            if mutated.count(old) != 1:
                print("%-12s SKIP: the anchor is not unique in %s"
                      % (name, os.path.basename(target)))
                ok = False
                break
            mutated = mutated.replace(old, new, 1)
        if not ok:
            results.append((name, "SKIP", 0, 0, 0))
            continue

        write(target, mutated.replace("\n", "\r\n")
              if "\r\n" in original else mutated)
        try:
            rc, fails, errors, out = run_suite(suite)
            if errors > 0:
                verdict = "INVALID"
            elif rc != 0 and fails > 0:
                verdict = "RED"
            else:
                verdict = "MISSED"
            results.append((name, verdict, rc, fails, errors))
        finally:
            write(target, original)

    # The restore must be green again.
    for target in originals:
        original, _ = originals[target]
        write(target, original)
    rc, fails, errors, out = run_suite(ENTRY_SUITE)
    if rc != 0 or fails != 0 or errors != 0:
        results.append(("RESTORE", "NOT-GREEN", rc, fails, errors))
    else:
        results.append(("RESTORE", "GREEN", rc, fails, errors))

    print("")
    print("%-12s %-10s %5s %6s %6s" % ("MUTATION", "VERDICT", "rc", "fails",
                                        "errs"))
    for name, verdict, rc, fails, errors in results:
        print("%-12s %-10s %5d %6d %6d" % (name, verdict, rc, fails, errors))

    bad = [r for r in results if r[1] != "RED" and r[0] != "RESTORE"]
    total = len([r for r in results if r[0] != "RESTORE"])
    clean = len([r for r in results if r[1] == "RED"])
    print("")
    print("negative controls: %d, clean: %d, problems: %d"
          % (total, clean, len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
