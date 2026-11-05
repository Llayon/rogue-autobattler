"""Run parse-valid semantic mutations sequentially and always restore production."""
import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", required=True)
    parser.add_argument("--output", default="artifacts/inventory_integrity/negative-controls.json")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    path = root / "core/progression/run_domain_state.gd"
    original = path.read_bytes()
    source = original.decode("utf-8").replace("\r\n", "\n")
    mutations = [
        (" or live_items.has(it.instance_id)", ""),
        ("# Remove the item itself from the items array.", "# Remove the item itself from the items array.\n\tnext_item_instance_seq -= 1"),
        ("var idx: int = old_owner.equipped_item_ids.find(item_instance_id)", "var idx: int = -1"),
        ("if int(u.location) != int(RunUnit.LOCATION_BOARD):", "if false:"),
        ('it.owner_unit_id = ""\n\t_purge_equipped_references', 'it.instance_id = allocate_item_instance_id()\n\tit.owner_unit_id = ""\n\t_purge_equipped_references'),
        ('# Remove the item itself from the items array.\n\tvar pos: int = items.find(it)', '# Remove by definition (deliberately broken).\n\tfor candidate in items:\n\t\tif candidate.definition_id == it.definition_id:\n\t\t\tit = candidate\n\t\t\tbreak\n\tvar pos: int = items.find(it)'),
        ('if u == null:\n\t\treturn false\n\tif int(u.location)', 'if u == null:\n\t\tit.owner_unit_id = unit_instance_id\n\t\treturn false\n\tif int(u.location)'),
    ]
    def run(n):
        p = subprocess.run([args.godot, "--headless", "--path", str(root), "--script", "tests/inventory_integrity/negative_control_test.gd", "--", str(n)], capture_output=True, text=True, timeout=60)
        out = p.stdout + p.stderr
        return dict(rc=p.returncode, script_errors=out.count("SCRIPT ERROR"), parse_errors=out.count("Parse Error"), semantic_fail="[FAIL] NC-I" in out)
    rows = []
    try:
        for n, (old, new) in enumerate(mutations, 1):
            assert old in source, (n, old)
            path.write_text(source.replace(old, new, 1), encoding="utf-8", newline="\n")
            red = run(n)
            path.write_bytes(original)
            green = run(n)
            row = dict(control="NC-I%d" % n, red=red, restored_green=green)
            rows.append(row)
            print(json.dumps(row), flush=True)
            assert red["rc"] != 0 and red["semantic_fail"] and red["script_errors"] == red["parse_errors"] == 0
            assert green["rc"] == green["script_errors"] == green["parse_errors"] == 0 and not green["semantic_fail"]
    finally:
        path.write_bytes(original)
        output = root / args.output
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(rows, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
