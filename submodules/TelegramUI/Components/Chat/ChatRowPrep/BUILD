load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

# The pure parts of the two Debug Settings chat-scroll switches ("Chat rows: prepare layout ahead" and
# "Chat rows: reuse row views"): the cached switch state, the prefetch key and cache, the view pool and the
# idle work queue. No UI and no Telegram types, so they run as host-less unit tests.
swift_library(
    name = "ChatRowPrep",
    module_name = "ChatRowPrep",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ChatRowPrepTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":ChatRowPrep",
    ],
)

ios_test_runner(
    name = "ChatRowPrepTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "ChatRowPrepTests",
    minimum_os_version = "15.0",
    runner = ":ChatRowPrepTestRunner",
    deps = [
        ":ChatRowPrepTestsLib",
    ],
)
