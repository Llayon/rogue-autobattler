import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

# The repository root is derived from THIS script's own location, so the
# controls work in a checkout, in a worktree and on a CI runner. A
# hard-coded absolute path would only work on one machine.
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", ".."))
VALIDATOR = os.path.join(REPO, "tools", "validate_run_integrity_ledger.py")
LEDGER = os.path.join(".hermes", "plans", "run_integrity_ledger.json")


def run_validator(path):
    proc = subprocess.run([sys.executable, VALIDATOR, path],
                          capture_output=True, text=True, cwd=REPO)
    return proc.returncode, proc.stdout + proc.stderr


def with_ledger(mutate, label):
    """Runs the validator against a TEMPORARY COPY of the real ledger.
    The production ledger is never touched.

    The mutation OWNS the file: it writes the final content. The
    harness never writes the file after the mutation, because that
    would ERASE the mutation and make the control look MISSED when the
    validator is fine."""
    tmpdir = tempfile.mkdtemp(prefix="h10_")
    try:
        tmp_path = os.path.join(tmpdir, "run_integrity_ledger.json")
        shutil.copyfile(os.path.join(REPO, LEDGER), tmp_path)
        data = json.load(io.open(tmp_path, encoding="utf-8"))
        mutate(data, tmp_path)
        rc, out = run_validator(tmp_path)
        return rc, out
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def write_json(path, data):
    with io.open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


# ------------------------------------------------------------------
# The negative controls.
# ------------------------------------------------------------------

def zero_byte(data, path):
    with io.open(path, "w", encoding="utf-8") as f:
        f.write("")


def malformed_json(data, path):
    with io.open(path, "w", encoding="utf-8") as f:
        f.write("{ this is not json ]")


def removed_findings(data, path):
    del data["findings"]
    write_json(path, data)


def removed_integration(data, path):
    del data["integration"]
    write_json(path, data)


def wrong_findings_type(data, path):
    data["findings"] = {"not": "an array"}
    write_json(path, data)


def wrong_integration_type(data, path):
    data["integration"] = ["not", "an", "object"]
    write_json(path, data)


def wrong_root_type(data, path):
    with io.open(path, "w", encoding="utf-8") as f:
        json.dump(["not", "an", "object"], f)


def missing_file(data, path):
    os.remove(path)


NEGATIVE = [
    ("NC-H10A", "a zero-byte ledger", zero_byte),
    ("NC-H10B", "a malformed JSON ledger", malformed_json),
    ("NC-H10C", "a removed mandatory section", removed_findings),
    ("NC-H10D", "a removed `integration` section", removed_integration),
    ("NC-H10E", "a wrong `findings` type", wrong_findings_type),
    ("NC-H10F", "a wrong `integration` type", wrong_integration_type),
    ("NC-H10G", "a wrong root type", wrong_root_type),
]

POSITIVE = [
    ("the valid ledger", None),
]

results = []

# The positive case: the REAL ledger must be VALID.
rc, out = run_validator(os.path.join(REPO, LEDGER))
print("the positive control: the real ledger -> rc=%d" % rc)
print("  %s" % out.strip().splitlines()[-1] if out.strip() else "")
if rc != 0:
    print("!!! the real ledger does not pass its own validator")
results.append(("the valid ledger", "PASS" if rc == 0 else "FAIL", rc, 0, 0))

for name, title, mutate in NEGATIVE:
    if mutate is missing_file:
        # The missing file needs its own handling: the copy is removed
        # BEFORE the validator runs.
        tmpdir = tempfile.mkdtemp(prefix="h10_")
        try:
            tmp_path = os.path.join(tmpdir, "run_integrity_ledger.json")
            shutil.copyfile(os.path.join(REPO, LEDGER), tmp_path)
            os.remove(tmp_path)
            rc, out = run_validator(tmp_path)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
    else:
        rc, out = with_ledger(mutate, title)
    verdict = "RED" if rc != 0 else "MISSED"
    results.append((name, verdict, rc, 0, 0))
    print("%-10s %-6s rc=%d  %s" % (name, verdict, rc, title))

print("")
print("%-22s %-8s %5s" % ("CASE", "VERDICT", "rc"))
for name, verdict, rc, fails, errs in results:
    print("%-22s %-8s %5d" % (name, verdict, rc))

bad = [r for r in results if r[1] not in ("PASS", "RED")]
print("")
print("negative controls: %d, clean: %d, problems: %d"
      % (len(results) - 1, len(results) - 1 - len(bad), len(bad)))
sys.exit(1 if bad else 0)
