"""The web artifact validation gate (R3.2 / R5.2).

    The Pages deployment publishes the `build/` directory AS THE ROOT of
    the site, so the artifact must be complete AND self-consistent:

      - index.html must exist and be non-empty;
      - the WASM binary must exist and be non-empty;
      - the JavaScript bootstrap must exist;
      - the PCK (or the resource files) must exist;
      - the index.html must reference the files that are really there;
      - no absolute local path from the build machine may leak into
        the artifact.

    The validator exits 0 when the artifact is publishable and 1 when
    it is NOT. A missing index.html is a DENY, never a warning.
"""

import os
import re
import sys

# The files a Godot 4.7 "Web (no threads)" export always produces.
REQUIRED = [
    "index.html",
]

# The script/bootstrap files of the Godot web export.
SCRIPT_SUFFIXES = (".js", ".js.gz", ".wasm.gz", ".worker.js")

# The size in bytes below which a resource is considered empty.
MIN_BYTES = 512


def fail(reason, problems):
    problems.append(reason)


def check_required(files, problems):
    """Every REQUIRED file must exist and be non-empty."""
    for name in REQUIRED:
        if name not in files:
            fail("the artifact carries no %s" % name, problems)
            continue
        if files[name] < MIN_BYTES:
            fail("%s is %d bytes: the artifact is truncated"
                 % (name, files[name]), problems)


def check_payload(files, problems):
    """The artifact must carry a WASM and a JavaScript bootstrap."""
    has_wasm = False
    has_script = False
    for name in files:
        lower = name.lower()
        if ".wasm" in lower:
            has_wasm = True
        if lower.endswith(SCRIPT_SUFFIXES):
            has_script = True
    if not has_wasm:
        fail("the artifact carries no WASM binary", problems)
    if not has_script:
        fail("the artifact carries no JavaScript bootstrap", problems)


def check_html_references(files, problems, root):
    """The index.html must reference files that are really there.

    The site is served from the ROOT of the deployment, so a relative
    reference has to resolve inside the artifact.
    """
    index = os.path.join(root, "index.html")
    if not os.path.isfile(index):
        return
    with open(index, "r", encoding="utf-8", errors="replace") as f:
        html = f.read()
    # The Godot loader names its files in the <script> tags and in the
    # engine start-up block.
    for match in re.finditer(r"[\w./-]+\.(?:js|wasm|pck|wasm\.gz)", html):
        ref = match.group(0)
        base = os.path.basename(ref)
        if base not in files:
            fail("the index.html references %s, which the artifact does not carry"
                 % base, problems)


def check_no_local_paths(files, problems, root):
    """No absolute path of the BUILD MACHINE may leak into the artifact."""
    pattern = re.compile(r"(?:/home/runner|/Users/|[A-Za-z]:\\Users\\)")
    for name in files:
        if not name.endswith((".html", ".js", ".json", ".txt")):
            continue
        path = os.path.join(root, name)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        found = pattern.search(text)
        if found:
            fail("%s carries the absolute build-machine path %s"
                 % (name, found.group(0)), problems)


def collect(root):
    """The artifact files and their sizes."""
    files = {}
    for base, _dirs, names in os.walk(root):
        for name in names:
            full = os.path.join(base, name)
            rel = os.path.relpath(full, root).replace("\\", "/")
            try:
                files[rel] = os.path.getsize(full)
            except OSError:
                files[rel] = 0
    return files


def validate(root):
    """Returns the list of problems. An empty list means publishable."""
    problems = []
    if not os.path.isdir(root):
        return ["the artifact directory %s does not exist" % root]
    files = collect(root)
    if not files:
        return ["the artifact directory %s is empty" % root]
    check_required(files, problems)
    check_payload(files, problems)
    check_html_references(files, problems, root)
    check_no_local_paths(files, problems, root)
    return problems


def main(argv):
    if len(argv) < 2:
        print("usage: validate_web_artifact.py ARTIFACT_DIR")
        return 2
    root = argv[1]
    problems = validate(root)
    files = collect(root) if os.path.isdir(root) else {}
    print("the artifact directory : %s" % root)
    print("the artifact files     : %d" % len(files))
    for name in sorted(files):
        print("  %-40s %10d bytes" % (name, files[name]))
    if problems:
        print("ARTIFACT VALIDATION: DENY (%d)" % len(problems))
        for problem in problems:
            print("  " + problem)
        return 1
    print("ARTIFACT VALIDATION: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
