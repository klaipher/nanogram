load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "PeerPresenceStatusManager",
    module_name = "PeerPresenceStatusManager",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "PeerPresenceStatusManagerTestsLib",
    testonly = True,
    srcs = glob(["Tests/**/*.swift"]),
    deps = [
        ":PeerPresenceStatusManager",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
    ],
)

ios_test_runner(
    name = "PeerPresenceStatusManagerTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "PeerPresenceStatusManagerTests",
    minimum_os_version = "26.0",
    runner = ":PeerPresenceStatusManagerTestRunner",
    deps = [":PeerPresenceStatusManagerTestsLib"],
    visibility = ["//visibility:public"],
)
