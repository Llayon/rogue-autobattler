#!/usr/bin/env python3
"""Audit standalone Godot test harnesses for unsafe exit-code paths.

Godot's `SceneTree.quit(code)` is DEFERRED: the call records the exit
code but the current function keeps running. A harness that does

    if _failed > 0:
        quit(1)
    quit(0)

therefore reports exit code 0 to the shell even though the suite
failed. Every standalone test that can exit non-zero must either
`return` right after the non-zero quit, or use the if/else form.

This tool fails (exit 1) when it finds such a fallthrough.

Usage:
    python tools/audit_test_exit_contract.py [path ...]
"""

import io
import os
import re
import sys

QUIT_NONZERO = re.compile(r"\bquit\(\s*([1-9]\d*)\s*\)")
QUIT_ZERO = re.compile(r"\bquit\(\s*0\s*\)")
SCENE_TREE = re.compile(r"^\s*extends\s+SceneTree\b")


def scan_file(path):
    """Return the list of unsafe fallthroughs found in one file."""
    try:
        text = io.open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return []
    lines = text.splitlines()
    if not any(SCENE_TREE.match(line) for line in lines):
        return []
    hits = []
    for i, line in enumerate(lines):
        if not QUIT_NONZERO.search(line):
            continue
        # A non-zero quit on the same line as an else-branch or a
        # one-liner `if ...: quit(1)` is safe only when the very next
        # statement is a return or the quit sits in the else arm.
        for j in range(i + 1, min(i + 15, len(lines))):
            if not QUIT_ZERO.search(lines[j]):
                continue
            prev_idx = j - 1
            while prev_idx >= 0 and not lines[prev_idx].strip():
                prev_idx -= 1
            prev = lines[prev_idx].strip() if prev_idx >= 0 else ""
            if prev.startswith("else:"):
                break
            if prev == "return" or prev.startswith("return "):
                break
            # `quit(1)` followed by a `return` on the next line and
            # only then `quit(0)` is safe.
            if prev.startswith("quit("):
                # Look one further back: if a return follows the quit,
                # the path is safe.
                k = prev_idx - 1
                while k >= 0 and not lines[k].strip():
                    k -= 1
                if k >= 0 and lines[k].strip().startswith("return"):
                    break
            hits.append({
                "file": path,
                "line": i + 1,
                "quit_line": line.strip(),
                "zero_line": j + 1,
            })
            break
    return hits


def collect(paths):
    hits = []
    scanned = 0
    for root_path in paths:
        if os.path.isfile(root_path):
            if root_path.endswith(".gd"):
                scanned += 1
                hits.extend(scan_file(root_path))
            continue
        for root, dirs, files in os.walk(root_path):
            dirs[:] = [d for d in dirs if d not in (".git", ".godot")]
            for name in files:
                if not name.endswith(".gd"):
                    continue
                full = os.path.join(root, name)
                scanned += 1
                hits.extend(scan_file(full))
    return scanned, hits


def main(argv):
    paths = argv[1:] or ["tests"]
    scanned, hits = collect(paths)
    print("standalone suites scanned : %d" % scanned)
    print("unsafe exit paths         : %d" % len(hits))
    if hits:
        print("")
        for hit in hits:
            print("  %s:%d" % (hit["file"], hit["line"]))
            print("      %s" % hit["quit_line"])
            print("      -> later: %s" % hit["zero_line"])
        print("")
        print("AUDIT: FAIL — a non-zero quit falls through to quit(0).")
        return 1
    print("")
    print("AUDIT: PASS — every non-zero quit cannot fall through to quit(0).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
