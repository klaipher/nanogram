"""Tests that Make.py's --bazelArguments reach every bazel invocation.

Run: python3 -m unittest discover -s build-system/Make/tests -v
"""

import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

import Make  # noqa: E402


class FakeBuildEnvironment:
    def __init__(self, base_path, bazel_path, override_bazel_version, override_xcode_version):
        self.base_path = base_path
        self.bazel_path = bazel_path


class BazelArgumentsTest(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(Make, 'BuildEnvironment', FakeBuildEnvironment)
        patcher.start()
        self.addCleanup(patcher.stop)

        identity_patcher = mock.patch.object(Make, 'get_xcode_sdk_identity', lambda: '')
        identity_patcher.start()
        self.addCleanup(identity_patcher.stop)

        self.calls = []
        call_patcher = mock.patch.object(Make, 'call_executable', lambda args, **kw: self.calls.append(args))
        call_patcher.start()
        self.addCleanup(call_patcher.stop)

        self.command_line = Make.BazelCommandLine(
            bazel='/fake/bazel',
            override_bazel_version=False,
            override_xcode_version=False,
            bazel_user_root=None,
        )
        self.command_line.set_build_number('1')
        self.command_line.set_configuration('debug_sim_arm64')

    def test_no_arguments_adds_nothing(self):
        self.command_line.add_additional_args(None)
        self.assertEqual(self.command_line.get_user_arguments(), [])

    def test_arguments_are_split_like_a_shell(self):
        self.command_line.add_additional_args('--//Telegram:disableExtensions --jobs=8 "--copt=-DA B"')
        self.assertEqual(
            self.command_line.get_user_arguments(),
            ['--//Telegram:disableExtensions', '--jobs=8', '--copt=-DA B'],
        )

    def test_build_passes_arguments_last(self):
        self.command_line.add_additional_args('--//Telegram:disableExtensions')
        self.command_line.invoke_build()
        self.assertEqual(self.calls[-1][-1], '--//Telegram:disableExtensions')

    def test_test_passes_arguments(self):
        self.command_line.add_additional_args('--jobs=4')
        self.command_line.invoke_test(test_target='//foo:bar')
        self.assertEqual(self.calls[-1][-1], '--jobs=4')

    def test_query_passes_arguments_before_query_expression(self):
        self.command_line.add_additional_args('--jobs=4')
        self.command_line.invoke_query(['deps(//foo)'])
        self.assertEqual(self.calls[-1][-2:], ['--jobs=4', 'deps(//foo)'])

    def test_project_generation_includes_arguments(self):
        self.command_line.add_additional_args('--jobs=4')
        self.assertEqual(self.command_line.get_project_generation_arguments()[-1], '--jobs=4')

    def test_release_links_use_the_thinlto_cache_and_debug_does_not(self):
        self.command_line.set_configuration('release_arm64')
        self.command_line.invoke_build()
        release = self.calls[-1]
        self.assertIn('--linkopt=-Wl,-cache_path_lto,{}'.format(Make.LTO_CACHE_DIR), release)
        self.assertIn('--linkopt=-Wl,-prune_after_lto,1209600', release)
        self.assertIn('--linkopt=-Wl,-max_relative_cache_size_lto,5', release)

        self.command_line.set_configuration('debug_sim_arm64')
        self.command_line.invoke_build()
        self.assertFalse([a for a in self.calls[-1] if 'cache_path_lto' in a])

    def test_sandbox_release_build_may_write_the_lto_cache(self):
        self.command_line.set_enable_sandbox(True)
        self.command_line.set_configuration('release_arm64')
        self.command_line.invoke_build()
        self.assertIn('--sandbox_writable_path={}'.format(Make.LTO_CACHE_DIR), self.calls[-1])

        self.command_line.set_configuration('debug_sim_arm64')
        self.command_line.invoke_build()
        self.assertFalse([a for a in self.calls[-1] if 'sandbox_writable_path' in a])

    def test_project_generation_carries_the_xcode_identity(self):
        with mock.patch.object(Make, 'get_xcode_sdk_identity', lambda: 'xc-1'):
            args = self.command_line.get_project_generation_arguments()
        self.assertIn('--action_env=NANOGRAM_XCODE_ID=xc-1', args)


if __name__ == '__main__':
    unittest.main()
