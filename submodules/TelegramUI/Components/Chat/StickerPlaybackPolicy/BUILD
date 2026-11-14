load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("//build-system/bazel-utils:swift_strict.bzl", "strict_swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

# The pure rules for how a chat sticker plays (loop or once) and what to do when Power Saving changes the choice.
# No UI and no Telegram types, so they run as host-less unit tests.
strict_swift_library(
    name = "StickerPlaybackPolicy",
    module_name = "StickerPlaybackPolicy",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "StickerPlaybackPolicyTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":StickerPlaybackPolicy",
    ],
)

ios_test_runner(
    name = "StickerPlaybackPolicyTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "StickerPlaybackPolicyTests",
    minimum_os_version = "26.0",
    runner = ":StickerPlaybackPolicyTestRunner",
    deps = [
        ":StickerPlaybackPolicyTestsLib",
    ],
)
