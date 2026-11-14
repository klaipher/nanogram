#!/usr/bin/env python3
"""Thin wrapper: checks this repository against shared/shared-libraries.json (klaipher/nanogram-deps) with --side ios."""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
TARGET = os.path.join(ROOT, "shared", "check_shared.py")


def main(argv):
    if not os.path.isfile(TARGET):
        print(f"check_shared: {TARGET} is missing; run `git submodule update --init shared`", file=sys.stderr)
        return 2
    args = list(argv)
    if "--side" not in args:
        args = ["--side", "ios"] + args
    if "--root" not in args:
        args += ["--root", ROOT]
    return subprocess.run([sys.executable, TARGET] + args).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
