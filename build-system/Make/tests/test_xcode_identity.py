"""Tests for the Xcode/SDK identity Make.py passes as --action_env=NANOGRAM_XCODE_ID.

Run: python3 -m unittest discover -s build-system/Make/tests -v
"""

import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

import BuildEnvironment  # noqa: E402
import Make  # noqa: E402


class FakeBuildEnvironment:
    def __init__(self, base_path, bazel_path, override_bazel_version, override_xcode_version):
        self.base_path = base_path
        self.bazel_path = bazel_path


class XcodeIdentityTest(unittest.TestCase):
    def test_parse_build_version(self):
        self.assertEqual(BuildEnvironment.parse_xcode_build_version('Xcode 27.1\nBuild version 18B100\n'), '18B100')
        self.assertIsNone(BuildEnvironment.parse_xcode_build_version('xcode-select: error\n'))

    def test_identity_combines_xcode_and_both_sdks(self):
        def fake(program, arguments, **kwargs):
            if program == 'xcodebuild':
                return 'Xcode 27.1\nBuild version 18B100\n'
            return {'iphoneos': '24A100\n', 'iphonesimulator': '24A101\n'}[arguments[1]]

        with mock.patch.object(BuildEnvironment, '_run_tool_without_developer_dir', fake):
            self.assertEqual(
                BuildEnvironment.get_xcode_sdk_identity(),
                'xcode-18B100.iphoneos-24A100.iphonesimulator-24A101',
            )

    def test_identity_is_empty_when_tools_fail(self):
        def fake(program, arguments, **kwargs):
            raise Exception('no xcode')

        with mock.patch.object(BuildEnvironment, '_run_tool_without_developer_dir', fake):
            self.assertEqual(BuildEnvironment.get_xcode_sdk_identity(), '')

    def test_build_and_test_commands_carry_the_identity(self):
        calls = []
        with mock.patch.object(Make, 'BuildEnvironment', FakeBuildEnvironment), \
                mock.patch.object(Make, 'call_executable', lambda args, **kw: calls.append(args)), \
                mock.patch.object(Make, 'get_xcode_sdk_identity', lambda: 'xcode-X.iphoneos-A.iphonesimulator-B'):
            command_line = Make.BazelCommandLine(
                bazel='/fake/bazel', override_bazel_version=False, override_xcode_version=False, bazel_user_root=None)
            command_line.set_build_number('1')
            command_line.set_configuration('debug_sim_arm64')
            command_line.invoke_build()
            command_line.invoke_test(test_target='//foo:bar')
        for call in calls:
            self.assertIn('--action_env=NANOGRAM_XCODE_ID=xcode-X.iphoneos-A.iphonesimulator-B', call)


if __name__ == '__main__':
    unittest.main()
