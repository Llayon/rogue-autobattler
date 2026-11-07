"""The negative control matrix of the post-closure hardening.

Every control mutates ONE production decision, runs the suite that must
catch it, and restores the original file. A trustworthy RED is:

    rc != 0  AND  at least one [FAIL]  AND  0 parse errors  AND
    0 SCRIPT ERROR lines

A mutation that breaks the PARSING is INVALID, not a catch. A
mutation whose anchor is missing or not unique is a SKIP, and a SKIP
is never evidence. A control that cannot fail is not a control.

The suites run ONE AT A TIME: several Godot processes in parallel fail
on Windows with a fork error, and that would look like a mutation
failure.

Usage:

    python tools/negative_controls.py

The controls are not a CI gate on their own -- they mutate the
production tree -- but they are part of the hardening evidence and
they are reproducible from this file.
"""

import io
import os
import subprocess
import sys

GODOT = os.environ.get(
    "GODOT",
    r"D:\Programms\Max\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe")
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

CONTROLLER = "core/progression/run_controller.gd"
REPOSITORY = "core/save/run_save_repository.gd"
SHOP = "core/progression/shop_screen.gd"
BUILDER = "core/battle_ecs/battle_setup_builder.gd"
SCENE = "scenes/battle/battle_scene.gd"
DOMAIN_STATE = "core/progression/run_domain_state.gd"


def read(rel):
    with io.open(os.path.join(REPO, rel), encoding="utf-8", newline="") as f:
        raw = f.read()
    return raw, raw.replace("\r\n", "\n")


def write(rel, text):
    with io.open(os.path.join(REPO, rel), "w", encoding="utf-8", newline="") as f:
        f.write(text)


def run(suite):
    proc = subprocess.run([GODOT, "--headless", "--path", REPO,
                           "--script", "res://" + suite],
                          capture_output=True, text=True, cwd=REPO, timeout=600)
    out = proc.stdout + proc.stderr
    return (proc.returncode, out.count("[FAIL]"),
            out.count("SCRIPT ERROR") + out.count("Parse Error"))


# (id, title, target file, suite, [(old, new), ...])
MUTATIONS = [
    ("NC-H01", "the save counter is incremented before the temp write",
     REPOSITORY, "tests/run_integrity/save_commit_counting_test.gd",
     [("\tvar temp: String = target + TEMP_SUFFIX\n"
       "\tvar bytes: PackedByteArray = serialize_canonical_bytes(data)\n"
       "\tif not _ops.write_bytes_and_flush(temp, bytes):",
       "\t# MUTATED: the counter moves before the temp write.\n"
       "\t_save_count += 1\n"
       "\tvar temp: String = target + TEMP_SUFFIX\n"
       "\tvar bytes: PackedByteArray = serialize_canonical_bytes(data)\n"
       "\tif not _ops.write_bytes_and_flush(temp, bytes):")]),

    ("NC-H02", "the old discount survives start_run",
     CONTROLLER, "tests/run_integrity/merchant_discount_isolation_test.gd",
     [("\tmerchant_shop.reset_discount()\n",
       "\t# MUTATED: the discount is not reset.\n")]),

    ("NC-H03", "the save happens before the PREP transition",
     CONTROLLER, "tests/run_integrity/map_checkpoint_stability_test.gd",
     [("\tif node.is_combat():\n\t\t_set_phase(Phase.PREP)\n"
       "\t\t# The TRANSACTION: the selected combat and the PREP phase are\n"
       "\t\t# on the disk in ONE write.\n\t\tsave_now()",
       "\tif node.is_combat():\n"
       "\t\t# MUTATED: the save happens BEFORE the transition.\n"
       "\t\tsave_now()\n\t\t_set_phase(Phase.PREP)")]),

    ("NC-H05A", "the outcome retry is removed",
     CONTROLLER, "tests/run_integrity/outcome_retry_test.gd",
     [("\tif not _outcome_pending_persist:\n\t\treturn false",
       "\t# MUTATED: the retry does nothing.\n\treturn false")]),

    ("NC-H05B", "the outcome is re-applied",
     CONTROLLER, "tests/run_integrity/outcome_retry_test.gd",
     [("\tvar written: bool = bool(report.checkpoint_committed)\n\tif written:",
       "\t# MUTATED: the outcome is re-applied on every retry.\n"
       "\tstate.wins += 1\n\tstate.round_index += 1\n"
       "\tvar written: bool = bool(report.checkpoint_committed)\n\tif written:")]),

    ("NC-H06A", "the purchase save is removed",
     CONTROLLER, "tests/run_integrity/merchant_durability_test.gd",
     [("\t# H-06: the purchase is persisted. The write happens AFTER the\n"
       "\t# mutation, so a failed write leaves a STALE checkpoint with the\n"
       "\t# PRE-purchase state: the item is not duplicated and the gold is\n"
       "\t# not charged twice.\n\tsave_now()",
       "\t# MUTATED: the purchase is not persisted.")]),

    ("NC-H06C", "the exit guard is removed",
     CONTROLLER, "tests/run_integrity/merchant_durability_test.gd",
     [("\tif state == null or not state.just_visited_merchant:\n"
       "\t\tGameLog.warn(\"run\", \"the shop exit needs a real merchant context\")\n"
       "\t\treturn",
       "\t# MUTATED: the exit guard is gone.")]),

    ("NC-H07A", "the service dead end is a victory again",
     CONTROLLER, "tests/run_integrity/boss_dead_end_test.gd",
     [("\t\tif not encounter_map.is_valid():",
       "\t\tif false:")]),

    ("NC-H09A", "the equip no-op guard is removed",
     CONTROLLER, "tests/run_integrity/equipment_durability_test.gd",
     [("\tif owner_after == owner_before:",
       "\tif owner_after == owner_before and false:")]),

    ("NC-H09C", "the battle phase guard is removed",
     CONTROLLER, "tests/run_integrity/equipment_durability_test.gd",
     [("\tif not _phase_may_persist():", "\tif false:")]),

    ("NC-H12", "the terminal outcome is not idempotent",
     CONTROLLER, "tests/run_integrity/cross_package_gauntlet_test.gd",
     [("\t\t\t_battle_outcome_applied = true\n\t\t\t_end_run(true)",
       "\t\t\t# MUTATED: the terminal branch does not consume the latch.\n"
       "\t\t\t_end_run(true)")]),

    ("NC-H11A", "the inventory validation is removed",
     BUILDER, "tests/inventory_integrity/battle_inventory_boundary_test.gd",
     [("\tif not p_state.is_inventory_valid():", "\tif false:")]),

    ("NC-H11B", "a duplicate ownership is accepted silently",
     DOMAIN_STATE, "tests/inventory_integrity/battle_inventory_boundary_test.gd",
     [("\t\tfor item_id in u.equipped_item_ids:\n"
       "\t\t\tif listings.has(item_id):\n"
       "\t\t\t\treturn false\n"
       "\t\t\tlistings[item_id] = u.instance_id",
       "\t\tfor item_id in u.equipped_item_ids:\n"
       "\t\t\tlistings[item_id] = u.instance_id")]),

    ("NC-H04", "the stale visual context survives the resume",
     SCENE, "tests/run_integrity/resume_isolation_test.gd",
     [("\tif battle_view != null and battle_view._ctx != run_controller.ctx:",
       "\tif battle_view != null and run_controller.ctx != null \\\n"
       "\t\tand battle_view._ctx != run_controller.ctx:")]),
]


def main():
    results = []
    for name, title, target, suite, edits in MUTATIONS:
        original, original_lf = read(target)
        mutated = original_lf
        ok = True
        for old, new in edits:
            if old not in mutated:
                print("%-10s SKIP: the anchor is missing in %s" % (name, target))
                ok = False
                break
            if mutated.count(old) != 1:
                print("%-10s SKIP: the anchor is not unique in %s" % (name, target))
                ok = False
                break
            mutated = mutated.replace(old, new, 1)
        if not ok:
            results.append((name, "SKIP", 0, 0, 0))
            continue
        write(target, mutated.replace("\n", "\r\n")
              if "\r\n" in original else mutated)
        try:
            rc, fails, errs = run(suite)
            if rc != 0 and fails > 0 and errs == 0:
                verdict = "RED"
            elif errs > 0:
                verdict = "INVALID"
            else:
                verdict = "MISSED"
            results.append((name, verdict, rc, fails, errs))
        finally:
            write(target, original)
        rc, fails, errs = run(suite)
        if rc != 0 or fails > 0:
            results.append((name + "/RESTORE", "NOT-GREEN", rc, fails, errs))

    print("")
    print("%-14s %-10s %5s %5s %5s" % ("MUTATION", "VERDICT", "rc", "fails", "errs"))
    for name, verdict, rc, fails, errs in results:
        print("%-14s %-10s %5d %5d %5d" % (name, verdict, rc, fails, errs))

    bad = [r for r in results if r[1] != "RED"]
    total = len([r for r in results if not r[0].endswith("/RESTORE")])
    clean = len([r for r in results if r[1] == "RED"])
    print("")
    print("negative controls: %d, clean: %d, problems: %d"
          % (total, clean, len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
