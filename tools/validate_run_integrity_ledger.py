#!/usr/bin/env python3
"""Validate the Run Integrity ledger.

The ledger (`.hermes/plans/run_integrity_ledger.json`) is the evidence
of the whole Run Integrity series. It is a DOCUMENTATION artifact: no
test reads it, so a destroyed or malformed ledger passes every gate
silently. That happened during this effort -- the ledger was emptied
by a truncation bug and `git status`, `diff --check` and the whole
test runner stayed green.

This validator is the structural guard. It checks:

  - the file exists;
  - it is not empty;
  - it is valid UTF-8;
  - it is valid JSON;
  - the root is an object;
  - `findings` is an array;
  - `integration` is an object;
  - the key entries have the expected types and the minimal mandatory
    fields.

It deliberately does NOT require:

  - a fixed file size;
  - a fixed findings count;
  - a fixed commits count;
  - `final_sha == HEAD`.

The ledger must be allowed to grow.

Usage:
    python tools/validate_run_integrity_ledger.py [path]

Exit code 0 = valid, 1 = invalid.
"""

import io
import json
import os
import sys

DEFAULT_PATH = os.path.join(".hermes", "plans", "run_integrity_ledger.json")

# The minimal mandatory fields of the `integration` section. The
# ledger may carry more; these are the ones the series depends on.
INTEGRATION_REQUIRED = {
    "final_sha": str,
    "branch": str,
    "baseline_sha": str,
    "commits_ahead_of_baseline": int,
    "production_files_touched": list,
    "verification": dict,
}

# The `push` section is an object: the publication state, the remote
# and the gates. The ledger must be able to distinguish the HISTORICAL
# pre-push state from the ACTUAL publication state, so the status is
# a nested field.
PUSH_REQUIRED = {
    "status": str,
}


def fail(errors, message):
    errors.append(message)


def validate(path):
    """Returns the list of errors. An empty list means the ledger is valid."""
    errors = []

    if not os.path.exists(path):
        fail(errors, "the ledger %s does not exist" % path)
        return errors

    if os.path.isdir(path):
        fail(errors, "the ledger %s is a directory" % path)
        return errors

    raw = io.open(path, "rb").read()

    if len(raw) == 0:
        fail(errors, "the ledger %s is empty" % path)
        return errors

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(errors, "the ledger %s is not valid UTF-8: %s" % (path, exc))
        return errors

    if text.strip() == "":
        fail(errors, "the ledger %s holds only whitespace" % path)
        return errors

    try:
        data = json.loads(text)
    except ValueError as exc:
        fail(errors, "the ledger %s is not valid JSON: %s" % (path, exc))
        return errors

    if not isinstance(data, dict):
        fail(errors, "the ledger root is a %s, not an object" % type(data).__name__)
        return errors

    if "findings" not in data:
        fail(errors, "the ledger has no `findings` section")
    elif not isinstance(data["findings"], list):
        fail(errors, "the ledger `findings` is a %s, not an array"
             % type(data["findings"]).__name__)

    if "integration" not in data:
        fail(errors, "the ledger has no `integration` section")
    elif not isinstance(data["integration"], dict):
        fail(errors, "the ledger `integration` is a %s, not an object"
             % type(data["integration"]).__name__)
    else:
        integration = data["integration"]
        for key, expected_type in INTEGRATION_REQUIRED.items():
            if key not in integration:
                fail(errors, "the ledger `integration` has no `%s`" % key)
                continue
            value = integration[key]
            if expected_type is str:
                if not isinstance(value, str):
                    fail(errors, "the ledger `integration.%s` is a %s, not a string"
                         % (key, type(value).__name__))
                elif value.strip() == "":
                    fail(errors, "the ledger `integration.%s` is empty" % key)
            elif not isinstance(value, expected_type):
                fail(errors, "the ledger `integration.%s` is a %s, not a %s"
                     % (key, type(value).__name__, expected_type.__name__))

        push = integration.get("push")
        if isinstance(push, dict):
            for key, expected_type in PUSH_REQUIRED.items():
                if key not in push:
                    fail(errors, "the ledger `integration.push` has no `%s`" % key)
                    continue
                value = push[key]
                if not isinstance(value, expected_type):
                    fail(errors, "the ledger `integration.push.%s` is a %s, not a %s"
                         % (key, type(value).__name__, expected_type.__name__))
                elif expected_type is str and value.strip() == "":
                    fail(errors, "the ledger `integration.push.%s` is empty" % key)
        elif "push" in integration:
            fail(errors, "the ledger `integration.push` is a %s, not an object"
                 % type(push).__name__)

    # The findings entries, when present, must be objects with an id.
    if isinstance(data.get("findings"), list):
        for index, entry in enumerate(data["findings"]):
            if not isinstance(entry, dict):
                fail(errors, "the ledger `findings[%d]` is a %s, not an object"
                     % (index, type(entry).__name__))
                continue
            if "id" not in entry:
                fail(errors, "the ledger `findings[%d]` has no `id`" % index)
            elif not isinstance(entry["id"], str):
                fail(errors, "the ledger `findings[%d].id` is a %s, not a string"
                     % (index, type(entry["id"]).__name__))

    return errors


def main(argv):
    path = argv[1] if len(argv) > 1 else DEFAULT_PATH
    errors = validate(path)
    if errors:
        print("RUN INTEGRITY LEDGER: INVALID (%s)" % path)
        for message in errors:
            print("  - %s" % message)
        return 1
    print("RUN INTEGRITY LEDGER: VALID (%s)" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
