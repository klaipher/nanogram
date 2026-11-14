#!/usr/bin/env python3
"""Rewrite every `minimum_os_version = "<v>"` in tracked BUILD files to the value in Telegram/BUILD (single source of truth).

Run it after every upstream sync: upstream BUILD files bring their own literals back. `--check` only reports drift.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LITERAL = re.compile(r'(minimum_os_version = ")[0-9.]+(")')


def source_version(root=ROOT):
    match = re.search(r'^minimum_os_version = "([0-9.]+)"', (root / "Telegram/BUILD").read_text(), re.M)
    if not match:
        raise SystemExit("Telegram/BUILD has no top-level minimum_os_version")
    return match.group(1)


def build_files(root=ROOT):
    out = subprocess.run(["git", "grep", "-l", "minimum_os_version = \"", "--", "BUILD", "**/BUILD", "*.bzl"],
                         cwd=root, capture_output=True, text=True).stdout
    return [root / line for line in out.splitlines() if line]


def rewrite(root=ROOT, check=False):
    version = source_version(root)
    drift = []
    for path in build_files(root):
        text = path.read_text()
        new = LITERAL.sub(lambda m: m.group(1) + version + m.group(2), text)
        if new != text:
            drift.append(path)
            if not check:
                path.write_text(new)
    return version, drift


if __name__ == "__main__":
    check = "--check" in sys.argv[1:]
    version, drift = rewrite(check=check)
    for path in drift:
        print(("drift " if check else "updated ") + str(path.relative_to(ROOT)))
    print(f"minimum_os_version {version}: {len(drift)} file(s) {'differ' if check else 'rewritten'}")
    sys.exit(1 if check and drift else 0)
