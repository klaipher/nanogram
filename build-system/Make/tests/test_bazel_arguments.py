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


if __name__ == '__main__':
    unittest.main()
