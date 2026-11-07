#!/bin/bash
# pre_action of DisplayAccessibilityTestRunner. The runner reuses one "BAZEL_TEST_<device>_<os>" simulator
# (REUSE_GLOBAL_SIMULATOR), and installd does NOT replace an installed app whose build number is unchanged, so without
# this a run silently tests the PREVIOUS host build — and the host carries Display and AsyncDisplayKit, the code under
# test. A stale host with a test bundle built against a changed ListViewImpl layout crashes ("Index out of range" in
# ListViewImpl.neighbors(at:), 2026-11-07). Same fix as Tests/ComposerHarness/Tools/uninstall_harness_from_test_sims.sh,
# but it also boots a shut-down simulator, since `simctl uninstall` needs a booted one.
#
# Every BAZEL_TEST_ simulator, not one name: the device and OS come from build-system/bazel-utils/test_simulator.bzl,
# and a name pinned here (it was "iPhone 17_26.5") silently stops matching when that file moves to a new runtime.
set -u
for udid in $(xcrun simctl list devices available | grep -E "BAZEL_TEST_" | grep -oE "[0-9A-F-]{36}"); do
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  xcrun simctl uninstall "$udid" org.telegram.DisplayAccessibilityTestHost >/dev/null 2>&1 || true
done
exit 0
