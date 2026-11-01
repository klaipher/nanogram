"""Tests for tools/dev/lint/tglint.py. Run: python3 -m unittest discover -s tools/dev/lint/tests

The SwiftLint tests are skipped when the pinned SwiftLint is not installed (tglint.py install).
"""

import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import tglint  # noqa: E402

FIXTURES = os.path.join(HERE, 'fixtures')
HAVE_SWIFTLINT = os.path.exists(os.environ.get('TG_SWIFTLINT', tglint.swiftlint_path()))


def run(cmd, cwd):
    subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True)


def make_repo():
    path = tempfile.mkdtemp(prefix='tglint-test-')
    run(['git', 'init', '-q', '-b', 'main'], path)
    run(['git', 'config', 'user.email', 't@example.com'], path)
    run(['git', 'config', 'user.name', 't'], path)
    run(['git', 'config', 'commit.gpgsign', 'false'], path)
    return path


def write(root, rel, text):
    full = os.path.join(root, rel)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, 'w') as f:
        f.write(text)


def commit_all(root, message='c'):
    run(['git', 'add', '-A'], root)
    run(['git', 'commit', '-q', '-m', message], root)
    return subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root, check=True, capture_output=True, text=True).stdout.strip()


def fixture(name):
    with open(os.path.join(FIXTURES, name)) as f:
        return f.read()


class RepoTestCase(unittest.TestCase):
    def setUp(self):
        self.repo = make_repo()
        self.addCleanup(shutil.rmtree, self.repo, True)
        patcher = mock.patch.object(tglint, 'ROOT', self.repo)
        patcher.start()
        self.addCleanup(patcher.stop)


class DiffParsingTests(unittest.TestCase):
    def test_added_and_changed_lines(self):
        diff = '\n'.join([
            'diff --git a/A.swift b/A.swift',
            '--- a/A.swift',
            '+++ b/A.swift',
            '@@ -3 +3 @@',
            '@@ -10,0 +11,2 @@',
            '@@ -20,3 +22,0 @@',
            'diff --git a/New.swift b/New.swift',
            '--- /dev/null',
            '+++ b/New.swift',
            '@@ -0,0 +1,3 @@',
            'diff --git a/Gone.swift b/Gone.swift',
            '--- a/Gone.swift',
            '+++ /dev/null',
            '@@ -1,2 +0,0 @@',
        ])
        self.assertEqual(tglint.parse_unified_diff(diff), {'A.swift': {3, 11, 12}, 'New.swift': {1, 2, 3}})

    def test_vendored_paths_are_not_linted(self):
        self.assertFalse(tglint.is_lintable('third-party/libprisma/X.swift'))
        self.assertFalse(tglint.is_lintable('submodules/A/README.md'))
        self.assertTrue(tglint.is_lintable('submodules/A/Sources/A.swift'))


class FilterTests(unittest.TestCase):
    def violation(self, line, rule='int32_timestamp_arithmetic', path='submodules/A/Sources/A.swift', character=1, severity='error'):
        return {'path': path, 'line': line, 'character': character, 'severity': severity, 'rule_id': rule, 'reason': 'r'}

    def test_only_changed_lines_are_kept(self):
        source = {'submodules/A/Sources/A.swift': ['until + 1', 'until + 1']}
        kept = tglint.filter_violations([self.violation(1), self.violation(2)], {'submodules/A/Sources/A.swift': {2}}, source)
        self.assertEqual([v['line'] for v in kept], [2])

    def test_name_declared_wide_earlier_is_dropped(self):
        lines = [
            'func until(_ second: Int64) -> Double { 0 }',
            'let statusTimestamp = Int64(statusTimestamp)',
            'let x = until(statusTimestamp + 1)',
            'let y = until(second + 1)',
        ]
        path = 'submodules/A/Sources/A.swift'
        violations = [self.violation(3, character=15), self.violation(4, character=15)]
        kept = tglint.filter_violations(violations, {path: {3, 4}}, {path: lines})
        # `statusTimestamp` was widened on line 2; `second` is only wide inside `until`, but the
        # file-level check cannot tell scopes apart and drops it too (documented limitation).
        self.assertEqual(kept, [])

    def test_int32_name_is_kept(self):
        lines = [
            'case let .present(statusTimestamp):',
            '    return until(statusTimestamp + 1)',
        ]
        path = 'submodules/A/Sources/A.swift'
        kept = tglint.filter_violations([self.violation(2, character=18)], {path: {2}}, {path: lines})
        self.assertEqual(len(kept), 1)

    def test_wide_declaration_after_the_use_does_not_count(self):
        lines = [
            'let a = lastActivity + 30',
            'var lastActivity: Int64 = 0',
        ]
        path = 'submodules/A/Sources/A.swift'
        kept = tglint.filter_violations([self.violation(1, character=9)], {path: {1}}, {path: lines})
        self.assertEqual(len(kept), 1)

    def test_force_rules_in_tests_are_warnings(self):
        path = 'submodules/A/Tests/ATests.swift'
        kept = tglint.filter_violations([self.violation(1, rule='force_try', path=path)], {path: {1}}, {path: ['try! f()']})
        self.assertEqual(kept[0]['severity'], 'warning')
        kept = tglint.filter_violations([self.violation(1, path=path)], {path: {1}}, {path: ['until + 1']})
        self.assertEqual(kept[0]['severity'], 'error')


class AffectedTestsTests(RepoTestCase):
    def test_own_tests_then_dependents(self):
        write(self.repo, 'submodules/A/BUILD', 'swift_library(\n    name = "A",\n)\n\nios_unit_test(\n    name = "ATests",\n    deps = [":ATestsLib"],\n)\n')
        write(self.repo, 'submodules/A/Sources/A.swift', '')
        write(self.repo, 'submodules/C/BUILD', 'objc_library(\n    name = "C",\n)\n')
        write(self.repo, 'submodules/C/Sources/C.c', '')
        write(self.repo, 'submodules/D/BUILD', 'swift_library(\n    name = "DTestsLib",\n    deps = ["//submodules/C:C"],\n)\n\nios_unit_test(\n    name = "DTests",\n)\n\ncc_test(\n    name = "DHostTests",\n)\n')
        write(self.repo, 'submodules/E/BUILD', 'swift_library(\n    name = "E",\n    deps = ["//submodules/A:A"],\n)\n')
        write(self.repo, 'submodules/F/BUILD', 'swift_library(\n    name = "FTestsLib",\n    testonly = True,\n    deps = ["//submodules/A:A"],\n)\n\nios_unit_test(\n    name = "FTests",\n)\n')
        write(self.repo, 'BUILD.bazel', '')
        write(self.repo, 'docs/x.md', '')
        commit_all(self.repo)
        tests, notes = tglint.affected_tests(
            ['submodules/A/Sources/A.swift', 'submodules/C/Sources/C.c', 'docs/x.md', 'submodules/A/Tests/ATests.swift'],
            root=self.repo, all_dependents=False)
        # A: its own tests and F's, whose testonly library uses A (E is not a test).
        # C: no tests of its own or in a testonly rule, so its dependents' tests.
        self.assertEqual(tests, ['//submodules/A:ATests', '//submodules/F:FTests', '//submodules/D:DTests', '//submodules/D:DHostTests'])
        self.assertEqual(notes, [])

    def test_many_dependents_are_capped(self):
        write(self.repo, 'submodules/Core/BUILD', 'swift_library(\n    name = "Core",\n)\n')
        for i in range(tglint.MAX_DEPENDENT_TESTS + 1):
            write(self.repo, 'submodules/U{}/BUILD'.format(i),
                  'swift_library(\n    name = "L",\n    testonly = True,\n    deps = ["//submodules/Core:Core"],\n)\n\nios_unit_test(\n    name = "T",\n)\n')
        commit_all(self.repo)
        tests, notes = tglint.affected_tests(['submodules/Core/Sources/Core.swift'], root=self.repo, all_dependents=False)
        self.assertEqual(tests, [])
        self.assertEqual(len(notes), 1)
        tests, _ = tglint.affected_tests(['submodules/Core/Sources/Core.swift'], root=self.repo, all_dependents=True)
        self.assertEqual(len(tests), tglint.MAX_DEPENDENT_TESTS + 1)

    def test_real_repo_mapping(self):
        root = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
        if not os.path.isdir(os.path.join(root, 'submodules', 'PeerPresenceStatusManager')):
            self.skipTest('not in the Telegram-iOS checkout')
        tests, _ = tglint.affected_tests([
            'submodules/PeerPresenceStatusManager/Sources/PeerPresenceStatusManager.swift',
            'submodules/TelegramUI/Components/AnimationCache/ImageDCT/Sources/SparseCoefficients.c',
        ], root=root, all_dependents=False)
        self.assertIn('//submodules/PeerPresenceStatusManager:PeerPresenceStatusManagerTests', tests)
        self.assertIn('//submodules/TelegramUI/Components/AnimationCache/ImageDCT:SparseCoefficientsSanitizerTests', tests)
        self.assertIn('//submodules/TelegramUI/Components/DCTAnimationCacheImpl:DCTAnimationCacheImplTests', tests)

    def test_python_suites(self):
        self.assertEqual(tglint.python_suites(['tools/dev/lint/tglint.py', 'build-system/Make/Make.py', 'a.swift']),
                         ['tools/dev/lint/tests', 'build-system/Make/tests'])


class PushRangeTests(RepoTestCase):
    def setUp(self):
        super().setUp()
        write(self.repo, 'a.txt', '1')
        self.first = commit_all(self.repo)
        self.remote = tempfile.mkdtemp(prefix='tglint-remote-')
        self.addCleanup(shutil.rmtree, self.remote, True)
        run(['git', 'init', '-q', '--bare', self.remote], self.repo)
        run(['git', 'remote', 'add', 'origin', self.remote], self.repo)
        run(['git', 'push', '-q', 'origin', 'main'], self.repo)

    def test_existing_branch_starts_at_remote_commit(self):
        write(self.repo, 'a.txt', '2')
        head = commit_all(self.repo)
        self.assertEqual(tglint.push_base('origin', head, self.first), self.first)

    def test_new_branch_starts_where_it_leaves_the_remote(self):
        run(['git', 'switch', '-q', '-c', 'feature'], self.repo)
        write(self.repo, 'b.txt', '1')
        commit_all(self.repo)
        write(self.repo, 'b.txt', '2')
        head = commit_all(self.repo)
        self.assertEqual(tglint.push_base('origin', head, tglint.ZERO_SHA), self.first)

    def test_nothing_new(self):
        self.assertIsNone(tglint.push_base('origin', self.first, tglint.ZERO_SHA))

    def test_parse_refs(self):
        text = 'refs/heads/main {} refs/heads/main {}\n'.format('a' * 40, tglint.ZERO_SHA)
        self.assertEqual(tglint.parse_push_refs(text), [('refs/heads/main', 'a' * 40, 'refs/heads/main', tglint.ZERO_SHA)])


class InstallHookTests(RepoTestCase):
    def test_install_and_uninstall(self):
        args = mock.Mock(uninstall=False)
        with mock.patch('sys.stdout', io.StringIO()):
            self.assertEqual(tglint.cmd_install_hook(args), 0)
            hook = os.path.join(self.repo, '.git', 'hooks', 'pre-push')
            with open(hook) as f:
                self.assertIn(tglint.HOOK_MARKER, f.read())
            self.assertTrue(os.access(hook, os.X_OK))
            args.uninstall = True
            self.assertEqual(tglint.cmd_install_hook(args), 0)
            self.assertFalse(os.path.exists(hook))

    def test_foreign_hook_is_kept(self):
        write(self.repo, '.git/hooks/pre-push', '#!/bin/sh\necho mine\n')
        with mock.patch('sys.stderr', io.StringIO()):
            self.assertEqual(tglint.cmd_install_hook(mock.Mock(uninstall=False)), 1)
        with open(os.path.join(self.repo, '.git', 'hooks', 'pre-push')) as f:
            self.assertIn('echo mine', f.read())


class InstallTests(unittest.TestCase):
    def test_checksum_mismatch_installs_nothing(self):
        tools = tempfile.mkdtemp(prefix='tglint-tools-')
        self.addCleanup(shutil.rmtree, tools, True)
        with mock.patch.dict(os.environ, {'TG_TOOLS_DIR': tools}), \
                mock.patch('urllib.request.urlopen', return_value=io.BytesIO(b'not the release')), \
                mock.patch('sys.stdout', io.StringIO()), mock.patch('sys.stderr', io.StringIO()) as err:
            self.assertEqual(tglint.cmd_install(None), 1)
            self.assertIn('checksum mismatch', err.getvalue())
            self.assertFalse(os.path.exists(tglint.swiftlint_path()))
            self.assertEqual(os.listdir(tools), [])


class OverflowTrapsStayOnTests(RepoTestCase):
    """Swift traps on integer overflow unless built with -Ounchecked; keep it that way."""

    def test_detects_unchecked_flags(self):
        write(self.repo, 'submodules/A/BUILD', 'swift_library(\n    copts = ["-Ounchecked"],\n)\n')
        write(self.repo, 'third-party/x/BUILD', 'copts = ["-Ounchecked"]\n')
        commit_all(self.repo)
        self.assertEqual(tglint.find_trap_removing_flags(self.repo), ['submodules/A/BUILD:2:    copts = ["-Ounchecked"],'])

    def test_repo_keeps_traps(self):
        root = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
        if not os.path.exists(os.path.join(root, '.git')):
            self.skipTest('not in a git checkout')
        self.assertEqual(tglint.find_trap_removing_flags(root), [])


@unittest.skipUnless(HAVE_SWIFTLINT, 'SwiftLint not installed (python3 tools/dev/lint/tglint.py install)')
class SwiftLintRulesTests(RepoTestCase):
    """Runs the real config on the code that crashed at launch (2c51ac0d) and on its fix (aee7088e)."""

    def lint_new_file(self, rel, text):
        write(self.repo, 'README', '')
        commit_all(self.repo)
        write(self.repo, rel, text)
        return tglint.lint_changed(tglint.changed_lines_worktree('HEAD'))

    def test_launch_crash_code_is_blocked(self):
        violations = self.lint_new_file('submodules/P/Sources/P.swift', fixture('presence_2c51ac0d.swift.txt'))
        overflow = [v['line'] for v in violations if v['rule_id'] == 'int32_timestamp_arithmetic' and v['severity'] == 'error']
        # until(statusTimestamp + 1), until(statusTimestamp + 31), lastActivity + 30, until(activeUntil + 1)
        self.assertEqual(overflow, [27, 37, 46, 48])
        conversions = [v['line'] for v in violations if v['rule_id'] == 'narrowing_integer_conversion']
        self.assertEqual(conversions, [22])  # let now = Int32(timestamp)

    def test_fix_passes(self):
        violations = self.lint_new_file('submodules/P/Sources/P.swift', fixture('presence_aee7088e.swift.txt'))
        self.assertEqual([v for v in violations if v['severity'] == 'error'], [])

    def test_only_changed_lines_of_existing_code(self):
        write(self.repo, 'submodules/P/Sources/P.swift', 'func f(_ until: Int32) -> Int32 {\n    return until + 1\n}\n')
        commit_all(self.repo)
        write(self.repo, 'submodules/P/Sources/P.swift', 'func f(_ until: Int32) -> Int32 {\n    return until + 1\n}\nlet x = [1].first!\n')
        violations = tglint.lint_changed(tglint.changed_lines_worktree('HEAD'))
        self.assertEqual([(v['line'], v['rule_id']) for v in violations], [(4, 'force_unwrapping')])

    def test_committed_content_is_linted(self):
        write(self.repo, 'README', '')
        base = commit_all(self.repo)
        write(self.repo, 'submodules/P/Sources/P.swift', 'let a = try! f()\n')
        head = commit_all(self.repo)
        write(self.repo, 'submodules/P/Sources/P.swift', 'let a = 1\n')  # uncommitted fix is not what is pushed
        violations = tglint.lint_changed(tglint.changed_lines_commits(base, head), head)
        self.assertEqual([(v['line'], v['rule_id'], v['severity']) for v in violations], [(1, 'force_try', 'error')])

    def test_force_operations_and_precision(self):
        source = '\n'.join([
            'import Foundation',
            'func f(_ any: Any, _ s: String?, _ d: Double, _ messageTimestamp: Int32) throws -> Int32 {',
            '    let a = any as! Int',                                  # 3 force_cast
            '    let b = try! JSONSerialization.data(withJSONObject: [])',  # 4 force_try
            '    let c = s!',                                            # 5 force_unwrapping
            '    let e = messageTimestamp + 86400',                       # 6 overflow
            '    let g = Int32(d)',                                      # 7 conversion
            '    let h = Int32(clamping: Int64(d))',                     # 8 ok
            '    let i = Int32(exactly: d) ?? 0',                        # 9 ok
            '    let j = d + 1.0',                                       # 10 ok: floating literal
            '    // until + 1 in a comment',                             # 11 ok
            '    let k = "timestamp + 1"',                               # 12 ok: string
            '    let l = Int64(messageTimestamp) + 1',                   # 13 ok: widened
            '    let m = Int32(Date().timeIntervalSince1970) + 30',      # 14 overflow (and conversion)
            '    let n = update + 1',                                    # 15 ok: not a timestamp name
            '    let o = Int32(5)',                                      # 16 ok: literal
            '    _ = (a, b, c, e, g, h, i, j, k, l, m, n, o)',
            '    return 0',
            '}',
            'let update = 1',
        ])
        violations = self.lint_new_file('submodules/P/Sources/P.swift', source)
        found = sorted((v['line'], v['rule_id']) for v in violations)
        self.assertEqual(found, [
            (3, 'force_cast'),
            (4, 'force_try'),
            (5, 'force_unwrapping'),
            (6, 'int32_timestamp_arithmetic'),
            (7, 'narrowing_integer_conversion'),
            (14, 'int32_timestamp_arithmetic'),
            (14, 'narrowing_integer_conversion'),
        ])


if __name__ == '__main__':
    unittest.main()
