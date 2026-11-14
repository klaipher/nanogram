load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "DCTMultiAnimationRendererImpl",
    module_name = "DCTMultiAnimationRendererImpl",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/CrashReporting:CrashReporting",
        "//submodules/TelegramUI/Components/AnimationCache:AnimationCache",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer:MultiAnimationRenderer",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "DCTMultiAnimationRendererImplTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":DCTMultiAnimationRendererImpl",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramUI/Components/AnimationCache:AnimationCache",
        "//submodules/TelegramUI/Components/DCTAnimationCacheImpl:DCTAnimationCacheImpl",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer:MultiAnimationRenderer",
    ],
)

ios_test_runner(
    name = "DCTMultiAnimationRendererImplTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "DCTMultiAnimationRendererImplTests",
    minimum_os_version = "26.0",
    runner = ":DCTMultiAnimationRendererImplTestRunner",
    deps = [
        ":DCTMultiAnimationRendererImplTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
