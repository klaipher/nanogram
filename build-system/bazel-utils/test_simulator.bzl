"""The simulator every ios_test_runner in this repo runs on.

Upstream pins each runner to a device/OS pair of its own CI machines (e.g. iOS 26.5),
and xctestrunner refuses an OS version that is not installed, so `tg test` failed for
every app-side test here. Keep these in sync with an installed runtime:

    xcrun simctl list runtimes -j   # each runtime lists its supported device types

After an Xcode update that brings a new simulator runtime, change these two values.
"""

TEST_SIMULATOR_DEVICE = "iPhone 17"
TEST_SIMULATOR_OS = "27.0"
