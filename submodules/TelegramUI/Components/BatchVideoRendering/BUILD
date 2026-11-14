load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "BatchVideoRendering",
    module_name = "BatchVideoRendering",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/MediaPlayer:UniversalMediaPlayer",
        "//submodules/Display",
        "//submodules/AccountContext",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "BatchVideoRenderingTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":BatchVideoRendering",
        "//submodules/SSignalKit/SwiftSignalKit",
    ],
)

ios_test_runner(
    name = "BatchVideoRenderingTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "BatchVideoRenderingTests",
    minimum_os_version = "26.0",
    runner = ":BatchVideoRenderingTestRunner",
    deps = [
        ":BatchVideoRenderingTestsLib",
    ],
)
