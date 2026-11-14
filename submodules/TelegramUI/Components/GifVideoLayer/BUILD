load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "GifVideoLayer",
    module_name = "GifVideoLayer",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Display",
        "//submodules/TelegramUI/Components/BatchVideoRendering",
        "//submodules/AccountContext",
        "//submodules/TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/PhotoResources",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "GifVideoLayerTestsLib",
    testonly = True,
    srcs = glob(["Tests/**/*.swift"]),
    deps = [
        ":GifVideoLayer",
    ],
)

ios_test_runner(
    name = "GifVideoLayerTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "GifVideoLayerTests",
    minimum_os_version = "26.0",
    runner = ":GifVideoLayerTestRunner",
    deps = [":GifVideoLayerTestsLib"],
)
