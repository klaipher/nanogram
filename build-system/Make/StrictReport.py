"""Summarize a Swift 6 strict-concurrency build log per Bazel package.

Used by `tools/dev/tg strict-report`:

    python3 build-system/Make/StrictReport.py <workspace root> <build log> [<bazel binary>]

Each diagnostic is counted once even if the log repeats it, and is attributed to the
package that owns its file (nearest BUILD file). With a bazel binary, the packages that
could not be checked because a module they depend on failed to compile are listed too.
"""

import os
import re
import subprocess
import sys
from collections import Counter

DIAGNOSTIC = re.compile(r'^(?P<path>[^\s:]+\.swift):(?P<line>\d+):(?P<column>\d+): (?P<kind>warning|error): ')
FAILED_MODULE = re.compile(r'^ERROR: .*Compiling Swift module (?P<label>//[^\s]+) failed')


def parse_log(lines):
    """Returns ({(path, line, column, kind)}, [failed module labels]) from build output lines."""
    diagnostics = set()
    failed = []
    for line in lines:
        match = DIAGNOSTIC.match(line)
        if match:
            diagnostics.add((match['path'], int(match['line']), int(match['column']), match['kind']))
            continue
        match = FAILED_MODULE.match(line)
        if match and match['label'] not in failed:
            failed.append(match['label'])
    return diagnostics, failed


def package_of(root, path):
    """The Bazel package (directory relative to root) that owns `path`, or None outside root."""
    absolute = os.path.normpath(os.path.join(root, path))
    if not absolute.startswith(os.path.normpath(root) + os.sep):
        return None
    directory = os.path.dirname(absolute)
    while directory.startswith(os.path.normpath(root)):
        if any(os.path.isfile(os.path.join(directory, name)) for name in ('BUILD', 'BUILD.bazel')):
            return os.path.relpath(directory, root)
        directory = os.path.dirname(directory)
    return None


def count_by_package(root, diagnostics):
    counts = Counter()
    for path, _line, _column, _kind in diagnostics:
        package = package_of(root, path)
        if package is not None:
            counts[package] += 1
    return counts


def unchecked_packages(root, bazel, failed):
    """Packages of modules that depend on a failed module (so were never compiled)."""
    if not failed:
        return []
    query = 'rdeps(//Telegram:Telegram, set({})) except set({})'.format(' '.join(failed), ' '.join(failed))
    result = subprocess.run(
        [bazel, 'query', query, '--output=package'],
        cwd=root, capture_output=True, text=True,
    )
    if result.returncode != 0:
        return []
    return sorted(set(result.stdout.split()) - {''})


def main(argv):
    if len(argv) not in (3, 4):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root, log_path = argv[1], argv[2]
    bazel = argv[3] if len(argv) == 4 else None
    with open(log_path, errors='replace') as log:
        diagnostics, failed = parse_log(log)
    counts = count_by_package(root, diagnostics)

    print('Swift 6 strict-concurrency problems: {} in {} packages'.format(sum(counts.values()), len(counts)))
    print()
    for package, count in counts.most_common():
        print('{:7d}  {}'.format(count, package))
    if failed:
        print()
        print('Failed to compile even with problems reported as warnings ({}):'.format(len(failed)))
        for label in failed:
            print('         {}'.format(label))
        if bazel:
            unchecked = unchecked_packages(root, bazel, failed)
            print()
            print('Not checked, because they depend on a module above ({} packages):'.format(len(unchecked)))
            for package in unchecked:
                print('         {}'.format(package))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
