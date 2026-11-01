#!/usr/bin/env python3
"""Lint and test guardrails for changed code.

  tglint.py install                 download the pinned SwiftLint (checksum verified)
  tglint.py lint [--base REV]       lint changed Swift lines (default: working tree vs HEAD)
  tglint.py lint --commits A..B     lint the lines B changes relative to A, as committed in B
  tglint.py affected-tests [paths]  test targets for changed paths (default: working tree vs HEAD)
  tglint.py pre-push REMOTE URL     git pre-push hook (reads refs on stdin)
  tglint.py install-hook [--uninstall]

See docs/guardrails.md.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
LINT_DIR = os.path.join(ROOT, 'tools', 'dev', 'lint')
CONFIG = os.path.join(LINT_DIR, 'swiftlint.yml')

SWIFTLINT_VERSION = '0.65.1'
SWIFTLINT_URL = 'https://github.com/realm/SwiftLint/releases/download/{v}/portable_swiftlint.zip'.format(v=SWIFTLINT_VERSION)
# GitHub's asset digest for portable_swiftlint.zip (macOS universal binary).
SWIFTLINT_SHA256 = 'c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0'

ZERO_SHA = '0' * 40

# Not ours to lint: vendored code and build outputs.
EXCLUDED_PREFIXES = (
    'third-party/',
    'build-input/',
    'bazel-',
)

# Force operations in tests crash only the test run; report them, don't block on them.
TEST_DOWNGRADED_RULES = {'force_unwrapping', 'force_try', 'force_cast', 'implicitly_unwrapped_optional'}

WIDE_TYPES = r'(?:Int|Int64|UInt64|Double|Float|Float64|CGFloat|TimeInterval|CFAbsoluteTime|CFTimeInterval|Date)'

TEST_RULE_KINDS = ('ios_unit_test', 'swift_test', 'strict_swift_test', 'cc_test', 'objc_test', 'macos_unit_test')

# Fallback to dependents' tests is capped so a core module does not run half the suite.
MAX_DEPENDENT_TESTS = 3


def tools_dir():
    return os.environ.get('TG_TOOLS_DIR', os.path.join(os.path.expanduser('~'), '.cache', 'telegram-ios', 'tools'))


def swiftlint_path():
    return os.path.join(tools_dir(), 'swiftlint-' + SWIFTLINT_VERSION, 'swiftlint')


def git(*args, cwd=None, check=True, input=None):
    result = subprocess.run(['git'] + list(args), cwd=cwd or ROOT, input=input, capture_output=True, text=True,
                            encoding='utf-8', errors='replace')
    if check and result.returncode != 0:
        raise RuntimeError('git {} failed: {}'.format(' '.join(args), result.stderr.strip()))
    return result.stdout


# --- SwiftLint install -------------------------------------------------------

def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def cmd_install(_args):
    target = swiftlint_path()
    if os.path.exists(target):
        print('SwiftLint {} already installed: {}'.format(SWIFTLINT_VERSION, target))
        return 0
    directory = os.path.dirname(target)
    os.makedirs(os.path.dirname(directory), exist_ok=True)
    work = tempfile.mkdtemp(prefix='swiftlint-', dir=os.path.dirname(directory))
    try:
        archive = os.path.join(work, 'portable_swiftlint.zip')
        print('Downloading ' + SWIFTLINT_URL)
        with urllib.request.urlopen(SWIFTLINT_URL) as response, open(archive, 'wb') as out:
            shutil.copyfileobj(response, out)
        actual = sha256_of(archive)
        if actual != SWIFTLINT_SHA256:
            print('error: checksum mismatch for portable_swiftlint.zip: got {}, want {}'.format(actual, SWIFTLINT_SHA256), file=sys.stderr)
            return 1
        unpacked = os.path.join(work, 'unpacked')
        with zipfile.ZipFile(archive) as z:
            member = z.getinfo('swiftlint')
            z.extract(member, unpacked)
        binary = os.path.join(unpacked, 'swiftlint')
        os.chmod(binary, 0o755)
        os.makedirs(directory, exist_ok=True)
        os.replace(binary, target)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print('Installed SwiftLint {} to {}'.format(SWIFTLINT_VERSION, target))
    return 0


# --- Changed lines -------------------------------------------------------------

HUNK_RE = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@')


def parse_unified_diff(text):
    """Maps each new-side path in a `git diff -U0` to the set of added/changed line numbers."""
    changed = {}
    path = None
    for line in text.splitlines():
        if line.startswith('+++ '):
            target = line[4:]
            if target == '/dev/null':
                path = None
            else:
                path = target[2:] if target.startswith('b/') else target
                changed.setdefault(path, set())
            continue
        match = HUNK_RE.match(line)
        if match and path is not None:
            start = int(match.group(1))
            count = 1 if match.group(2) is None else int(match.group(2))
            changed[path].update(range(start, start + count))
    return {p: lines for p, lines in changed.items()}


def is_lintable(path):
    return path.endswith('.swift') and not path.startswith(EXCLUDED_PREFIXES)


def changed_lines_worktree(base):
    diff = git('diff', '-U0', '--no-color', '--no-ext-diff', '--diff-filter=AMR', '-M', base, '--', '*.swift')
    changed = parse_unified_diff(diff)
    for path in git('ls-files', '--others', '--exclude-standard', '--', '*.swift').splitlines():
        full = os.path.join(ROOT, path)
        with open(full, encoding='utf-8', errors='replace') as f:
            count = sum(1 for _ in f)
        changed[path] = set(range(1, count + 1))
    return {p: l for p, l in changed.items() if is_lintable(p) and l}


def changed_lines_commits(base, head):
    diff = git('diff', '-U0', '--no-color', '--no-ext-diff', '--diff-filter=AMR', '-M', base, head, '--', '*.swift')
    return {p: l for p, l in parse_unified_diff(diff).items() if is_lintable(p) and l}


# --- Violations ------------------------------------------------------------------

def is_test_path(path):
    return '/Tests/' in '/' + path or path.startswith('Tests/')


def declared_wide_before(source_lines, name, line):
    """True when `name` is declared with a 64-bit or floating type before `line` (1-based)."""
    escaped = re.escape(name)
    patterns = [
        re.compile(r'\b' + escaped + r'\s*:\s*' + WIDE_TYPES + r'\b(?!\.)'),
        re.compile(r'\b(?:let|var)\s+' + escaped + r'\s*=\s*' + WIDE_TYPES + r'\('),
    ]
    for text in source_lines[:max(0, line - 1)]:
        if any(p.search(text) for p in patterns):
            return True
    return False


def filter_violations(violations, changed, sources):
    """Keeps violations on changed lines and applies the repo's adjustments.

    violations: dicts with path (repo-relative), line, character, severity ('error'/'warning'), rule_id, reason.
    sources: path -> list of source lines.
    """
    kept = []
    for v in violations:
        lines = changed.get(v['path'])
        if not lines or v['line'] not in lines:
            continue
        v = dict(v)
        if v['rule_id'] == 'int32_timestamp_arithmetic':
            text = sources.get(v['path'], [])
            if 0 < v['line'] <= len(text):
                start = max(0, (v.get('character') or 1) - 1)
                match = re.match(r'\w+', text[v['line'] - 1][start:])
                if match and match.group(0) != 'Int32' and declared_wide_before(text, match.group(0), v['line']):
                    continue
        if v['severity'] == 'error' and is_test_path(v['path']) and v['rule_id'] in TEST_DOWNGRADED_RULES:
            v['severity'] = 'warning'
        kept.append(v)
    kept.sort(key=lambda v: (v['path'], v['line'], v.get('character') or 0))
    return kept


def run_swiftlint(files, cwd):
    binary = os.environ.get('TG_SWIFTLINT', swiftlint_path())
    if not os.path.exists(binary):
        raise FileNotFoundError(binary)
    violations = []
    for i in range(0, len(files), 200):
        chunk = files[i:i + 200]
        result = subprocess.run(
            [binary, 'lint', '--quiet', '--no-cache', '--reporter', 'json', '--config', CONFIG] + chunk,
            cwd=cwd, capture_output=True, text=True)
        if result.returncode not in (0, 2):
            raise RuntimeError('swiftlint failed ({}): {}'.format(result.returncode, result.stderr.strip()))
        for item in json.loads(result.stdout or '[]'):
            path = os.path.relpath(os.path.realpath(item['file']), os.path.realpath(cwd))
            violations.append({
                'path': path,
                'line': item.get('line') or 0,
                'character': item.get('character'),
                'severity': (item.get('severity') or '').lower(),
                'rule_id': item.get('rule_id'),
                'reason': item.get('reason'),
            })
    return violations


def read_lines(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        return f.read().split('\n')


def lint_changed(changed, commit=None):
    """Returns the kept violations. With `commit`, lints the files as committed there."""
    if not changed:
        return []
    files = sorted(changed)
    if commit is None:
        cwd = ROOT
        sources = {p: read_lines(os.path.join(ROOT, p)) for p in files}
        return filter_violations(run_swiftlint(files, cwd), changed, sources)
    work = tempfile.mkdtemp(prefix='tglint-')
    try:
        sources = {}
        for p in files:
            content = git('show', '{}:{}'.format(commit, p))
            dest = os.path.join(work, p)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, 'w', encoding='utf-8') as f:
                f.write(content)
            sources[p] = content.split('\n')
        return filter_violations(run_swiftlint(files, work), changed, sources)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def report(violations, strict):
    errors = 0
    for v in violations:
        if v['severity'] == 'error' or strict:
            errors += 1
        print('{}:{}:{}: {}: {} ({})'.format(v['path'], v['line'], v.get('character') or 1, v['severity'], v['reason'], v['rule_id']))
    return errors


def missing_swiftlint_message():
    return 'SwiftLint {} is not installed. Run: python3 tools/dev/lint/tglint.py install'.format(SWIFTLINT_VERSION)


def cmd_lint(args):
    if args.commits:
        if '...' in args.commits or '..' not in args.commits:
            print('error: --commits takes A..B', file=sys.stderr)
            return 2
        base, _, head = args.commits.partition('..')
        changed = changed_lines_commits(base, head or 'HEAD')
        commit = head or 'HEAD'
    else:
        changed = changed_lines_worktree(args.base)
        commit = None
    try:
        violations = lint_changed(changed, commit)
    except FileNotFoundError:
        print('error: ' + missing_swiftlint_message(), file=sys.stderr)
        return 2
    errors = report(violations, args.strict)
    print('tglint: {} changed Swift file(s), {} finding(s), {} blocking'.format(len(changed), len(violations), errors))
    return 1 if errors else 0


# --- Build flags -------------------------------------------------------------------

# Swift traps on overflow, failed force unwraps and bad casts unless these are set.
TRAP_REMOVING_FLAGS = r'-Ounchecked|-remove-runtime-asserts|-enforce-exclusivity=unchecked|-assert-config +Unchecked'


def find_trap_removing_flags(root=None):
    result = subprocess.run(
        ['git', 'grep', '-n', '-E', '-e', TRAP_REMOVING_FLAGS, '--', '*BUILD', '*BUILD.bazel', '*.bzl', '*.bazelrc',
         'build-system/Make/*.py', '*Package.swift', 'tools/dev/tg', ':!third-party'],
        cwd=root or ROOT, capture_output=True, text=True)
    return result.stdout.splitlines()


# --- Affected tests --------------------------------------------------------------

def package_of(path, root=None):
    """Nearest directory (repo-relative) with a BUILD file, or None."""
    root = root or ROOT
    directory = os.path.dirname(path)
    while True:
        for name in ('BUILD', 'BUILD.bazel'):
            if os.path.isfile(os.path.join(root, directory, name)):
                return directory
        if not directory:
            return None
        directory = os.path.dirname(directory)


def test_targets_in_package(package, root=None):
    root = root or ROOT
    for name in ('BUILD', 'BUILD.bazel'):
        build = os.path.join(root, package, name)
        if os.path.isfile(build):
            with open(build, encoding='utf-8', errors='replace') as f:
                text = f.read()
            break
    else:
        return []
    labels = []
    for match in re.finditer(r'^(' + '|'.join(TEST_RULE_KINDS) + r')\(', text, re.M):
        name = re.search(r'\bname\s*=\s*"([^"]+)"', text[match.end():])
        if name:
            labels.append('//{}:{}'.format(package, name.group(1)))
    return labels


def rule_blocks(text):
    """Top-level rule calls of a BUILD file, as (kind, text)."""
    starts = [m for m in re.finditer(r'^([A-Za-z_]\w*)\(', text, re.M)]
    blocks = []
    for i, m in enumerate(starts):
        end = starts[i + 1].start() if i + 1 < len(starts) else len(text)
        blocks.append((m.group(1), text[m.start():end]))
    return blocks


def dependent_packages(package, root=None, tests_only=False):
    """Packages whose BUILD file names `//package:` or `//package"`.

    With tests_only, only those where a test rule or a testonly rule names it.
    """
    root = root or ROOT
    needles = ('//{}:'.format(package), '//{}"'.format(package))
    result = subprocess.run(['git', 'grep', '-l', '-F', '-e', needles[0], '-e', needles[1],
                             '--', '*BUILD', '*BUILD.bazel'],
                            cwd=root, capture_output=True, text=True)
    packages = []
    for build in result.stdout.splitlines():
        directory = os.path.dirname(build)
        if directory == package:
            continue
        if tests_only:
            with open(os.path.join(root, build), encoding='utf-8', errors='replace') as f:
                blocks = rule_blocks(f.read())
            if not any((kind in TEST_RULE_KINDS or re.search(r'\btestonly\s*=\s*True', body))
                       and any(n in body for n in needles) for kind, body in blocks):
                continue
        packages.append(directory)
    return sorted(set(packages))


def affected_tests(paths, root=None, all_dependents=None):
    """Tests of each changed package, plus tests that use it directly.

    Tests in other packages (a testonly library or test naming the package, or for a package
    without such tests, any dependent's tests) are added only when there are at most
    MAX_DEPENDENT_TESTS of them, unless all_dependents (or TG_PRE_PUSH_ALL_TESTS=1).
    """
    root = root or ROOT
    if all_dependents is None:
        all_dependents = os.environ.get('TG_PRE_PUSH_ALL_TESTS') == '1'
    tests = []
    notes = []
    packages = []
    for path in paths:
        package = package_of(path, root)
        if package and package not in packages:
            packages.append(package)
    for package in packages:
        own = test_targets_in_package(package, root)
        dependents = []
        for dependent in dependent_packages(package, root, tests_only=True):
            dependents.extend(test_targets_in_package(dependent, root))
        if not own and not dependents:
            for dependent in dependent_packages(package, root):
                dependents.extend(test_targets_in_package(dependent, root))
        tests.extend(own)
        if len(dependents) <= MAX_DEPENDENT_TESTS or all_dependents:
            tests.extend(dependents)
        else:
            notes.append('//{}: skipping {} test targets in other packages (TG_PRE_PUSH_ALL_TESTS=1 runs them)'.format(
                package, len(dependents)))
    unique = []
    for t in tests:
        if t not in unique:
            unique.append(t)
    return unique, notes


def python_suites(paths):
    suites = []
    if any(p.startswith('tools/dev/lint/') for p in paths):
        suites.append('tools/dev/lint/tests')
    if any(p.startswith('build-system/Make/') for p in paths):
        suites.append('build-system/Make/tests')
    return suites


def worktree_changed_paths(base='HEAD'):
    paths = git('diff', '--name-only', '--no-renames', base).splitlines()
    paths += git('ls-files', '--others', '--exclude-standard').splitlines()
    return sorted(set(paths))


def cmd_affected_tests(args):
    paths = args.paths or worktree_changed_paths()
    tests, notes = affected_tests(paths)
    for note in notes:
        print('# ' + note, file=sys.stderr)
    for t in tests:
        print(t)
    return 0


# --- pre-push ----------------------------------------------------------------------

def push_base(remote, local_sha, remote_sha):
    """The commit the pushed range starts from, or None when it cannot be found."""
    if remote_sha != ZERO_SHA and subprocess.run(['git', 'cat-file', '-e', remote_sha + '^{commit}'],
                                                 cwd=ROOT, capture_output=True).returncode == 0:
        return git('merge-base', remote_sha, local_sha, check=False).strip() or remote_sha
    # New branch: start where it leaves what the remote already has.
    first = git('rev-list', '--reverse', local_sha, '--not', '--remotes=' + remote, check=False).split()
    if not first:
        return None
    parent = git('rev-parse', '--verify', '--quiet', first[0] + '^', check=False).strip()
    return parent or None


def parse_push_refs(text):
    refs = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 4:
            refs.append(tuple(parts))
    return refs


def run_tests(labels):
    failed = []
    tg = os.path.join(ROOT, 'tools', 'dev', 'tg')
    for label in labels:
        print('tglint: tg test ' + label, flush=True)
        if subprocess.run([tg, 'test', label], cwd=ROOT).returncode != 0:
            failed.append(label)
    return failed


def run_python_suites(suites):
    failed = []
    for suite in suites:
        print('tglint: python3 -m unittest discover -s ' + suite, flush=True)
        if subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', suite], cwd=ROOT).returncode != 0:
            failed.append(suite)
    return failed


def cmd_pre_push(args):
    if os.environ.get('TG_PRE_PUSH') == '0':
        return 0
    refs = parse_push_refs(sys.stdin.read())
    all_paths = []
    blocking = 0
    for local_ref, local_sha, remote_ref, remote_sha in refs:
        if local_sha == ZERO_SHA:
            continue  # deleting a ref
        base = push_base(args.remote, local_sha, remote_sha)
        if base is None:
            print('tglint: {}: nothing new to check'.format(local_ref))
            continue
        print('tglint: checking {} ({}..{})'.format(local_ref, base[:10], local_sha[:10]))
        try:
            violations = lint_changed(changed_lines_commits(base, local_sha), local_sha)
        except FileNotFoundError:
            print('error: ' + missing_swiftlint_message(), file=sys.stderr)
            print('(skip this check once with: git push --no-verify)', file=sys.stderr)
            return 1
        blocking += report(violations, os.environ.get('TG_LINT_STRICT') == '1')
        all_paths += git('diff', '--name-only', '--no-renames', base, local_sha).splitlines()
    if blocking:
        print('tglint: {} blocking lint finding(s); push stopped. Fix them, or push with --no-verify.'.format(blocking), file=sys.stderr)
        return 1
    if os.environ.get('TG_PRE_PUSH_TESTS') == '0':
        return 0
    all_paths = sorted(set(all_paths))
    labels, notes = affected_tests(all_paths)
    for note in notes:
        print('tglint: ' + note)
    if labels and git('status', '--porcelain', '--untracked-files=no', check=False).strip():
        print('tglint: warning: the working tree has uncommitted changes; tests run on the working tree, not the pushed commits')
    failed = run_python_suites(python_suites(all_paths)) + run_tests(labels)
    if failed:
        print('tglint: failed: ' + ', '.join(failed), file=sys.stderr)
        return 1
    return 0


HOOK_MARKER = '# installed by tools/dev/lint/tglint.py'
HOOK_SCRIPT = '''#!/bin/sh
{marker}
# Runs the pre-push checks of the checkout being pushed from.
root="$(git rev-parse --show-toplevel)" || exit 1
if [ ! -x "$root/tools/dev/lint/pre-push" ]; then
  exit 0
fi
exec "$root/tools/dev/lint/pre-push" "$@"
'''.format(marker=HOOK_MARKER)


def cmd_install_hook(args):
    hooks = git('rev-parse', '--git-path', 'hooks').strip()
    hooks = hooks if os.path.isabs(hooks) else os.path.join(ROOT, hooks)
    path = os.path.join(hooks, 'pre-push')
    existing = None
    if os.path.exists(path):
        with open(path, encoding='utf-8', errors='replace') as f:
            existing = f.read()
    ours = existing is not None and HOOK_MARKER in existing
    if args.uninstall:
        if ours:
            os.remove(path)
            print('Removed ' + path)
        else:
            print('No tglint pre-push hook at ' + path)
        return 0
    if existing is not None and not ours:
        print('error: {} exists and is not ours; not replacing it'.format(path), file=sys.stderr)
        return 1
    os.makedirs(hooks, exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(HOOK_SCRIPT)
    os.chmod(path, 0o755)
    print('Installed ' + path)
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('install')
    lint = sub.add_parser('lint')
    lint.add_argument('--base', default='HEAD', help='compare the working tree with this revision')
    lint.add_argument('--commits', help='A..B: lint what B changes relative to A, as committed')
    lint.add_argument('--strict', action='store_true', help='warnings block too')
    tests = sub.add_parser('affected-tests')
    tests.add_argument('paths', nargs='*')
    push = sub.add_parser('pre-push')
    push.add_argument('remote')
    push.add_argument('url', nargs='?')
    hook = sub.add_parser('install-hook')
    hook.add_argument('--uninstall', action='store_true')
    args = parser.parse_args(argv)
    return {
        'install': cmd_install,
        'lint': cmd_lint,
        'affected-tests': cmd_affected_tests,
        'pre-push': cmd_pre_push,
        'install-hook': cmd_install_hook,
    }[args.command](args)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
