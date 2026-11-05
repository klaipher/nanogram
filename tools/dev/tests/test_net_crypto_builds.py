"""Native crypto libraries built outside Bazel's copts get the same memory-safety hardening (night/net-crypto, 2026-11-05).

.bazelrc hardens every C-family compile Bazel runs. tde2e (conference-call blockchain and frame
encryption) is built by a CMake genrule, which does not see those copts, so its script adds them
for the target build only; the host-side source generators stay plain.
"""
import os
import re
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
TD_SCRIPT = os.path.join(ROOT, 'third-party', 'td', 'build-td-bazel.sh')
BAZELRC = os.path.join(ROOT, '.bazelrc')

HARDENING = (
    '-ftrivial-auto-var-init=zero',
    '-fstack-protector-strong',
    '-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST',
)


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


class TdE2eHardeningTests(unittest.TestCase):
    def setUp(self):
        self.script = read(TD_SCRIPT)

    def test_bazelrc_still_sets_the_flags_the_script_mirrors(self):
        rc = read(BAZELRC)
        for flag in HARDENING:
            self.assertIn('build --copt=' + flag, rc)

    def test_target_build_gets_every_hardening_flag(self):
        match = re.search(r'^HARDENING_FLAGS="([^"]*)"', self.script, re.M)
        self.assertIsNotNone(match)
        for flag in HARDENING:
            self.assertIn(flag, match.group(1).split())
        self.assertRegex(self.script, r'(?m)^export CFLAGS="\$CFLAGS \$HARDENING_FLAGS"$')
        self.assertRegex(self.script, r'(?m)^export CXXFLAGS="\$CFLAGS"$')

    def test_flags_are_set_after_the_host_generators_and_before_the_target_build(self):
        generators = self.script.index('cmake -DTD_GENERATE_SOURCE_FILES=ON')
        flags = self.script.index('export CFLAGS="$CFLAGS $HARDENING_FLAGS"')
        target = self.script.index('make tde2e')
        self.assertLess(generators, flags)
        self.assertLess(flags, target)


if __name__ == '__main__':
    unittest.main()
