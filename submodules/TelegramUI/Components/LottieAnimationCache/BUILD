load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "LottieAnimationCache",
    module_name = "LottieAnimationCache",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramUI/Components/AnimationCache:AnimationCache",
        "//submodules/Display:Display",
        "//submodules/LottieBinding:LottieBinding",
        "//submodules/GZip:GZip",
        "//submodules/WebPBinding:WebPBinding",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "LottieAnimationCacheTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":LottieAnimationCache",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramUI/Components/AnimationCache:AnimationCache",
    ],
)

ios_test_runner(
    name = "LottieAnimationCacheTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "LottieAnimationCacheTests",
    minimum_os_version = "15.0",
    runner = ":LottieAnimationCacheTestRunner",
    resources = glob([
        "Tests/Resources/*.tgs",
    ]),
    deps = [
        ":LottieAnimationCacheTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
