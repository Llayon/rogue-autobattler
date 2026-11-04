#!/usr/bin/env python3
"""Audit the reachability of the legacy test functions in tests/run_tests.gd.

tests/run_tests.gd declares its test functions as `func _test_<name>()`.
A function that is declared but never CALLED is dead: it asserts
nothing, it can never fail, and it hides a regression. Five such
functions hid the Shield Block legacy regression for a whole sprint.

This tool fails (exit 1) when a declared `_test_*` function is never
invoked from the call list.

Usage:
    python tools/audit_run_tests_reachability.py [path]
"""

import io
import os
import re
import sys

DEFAULT = os.path.join("tests", "run_tests.gd")
FUNC_DEF = re.compile(r"^func\s+(_test_[A-Za-z0-9_]+)\s*\(", re.MULTILINE)
# A call looks like an indented `_test_name()` on its own line.
FUNC_CALL = re.compile(r"^\s+(_test_[A-Za-z0-9_]+)\s*\(", re.MULTILINE)


def main(argv):
    path = argv[1] if len(argv) > 1 else DEFAULT
    if not os.path.isfile(path):
        print("audit_run_tests_reachability: %s not found" % path)
        return 2

    text = io.open(path, encoding="utf-8", errors="replace").read()
    defined = set(FUNC_DEF.findall(text))
    called = set(FUNC_CALL.findall(text))
    # A definition line also matches the call pattern when it is
    # indented, but a `func` definition starts at column 0, so the
    # call set cannot contain a definition.
    dead = sorted(defined - called)

    print("declared _test_* functions : %d" % len(defined))
    print("reachable (called)         : %d" % len(called & defined))
    print("dead                       : %d" % len(dead))
    if dead:
        print("")
        for name in dead:
            print("  DEAD: %s" % name)
        print("")
        print("AUDIT: FAIL — a declared test function is never called.")
        return 1
    print("")
    print("AUDIT: PASS — every declared _test_* function is reachable.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
