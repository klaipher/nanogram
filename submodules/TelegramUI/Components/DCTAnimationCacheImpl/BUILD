load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "DCTAnimationCacheImpl",
    module_name = "DCTAnimationCacheImpl",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/CryptoUtils:CryptoUtils",
        "//submodules/ManagedFile:ManagedFile",
        "//submodules/TelegramUI/Components/AnimationCache:AnimationCache",
        "//submodules/TelegramUI/Components/AnimationCache/ImageDCT:ImageDCT",
        "//third-party/subcodec:SubcodecObjC",
        "//submodules/DiskWriteAccounting",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "DCTAnimationCacheImplTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":DCTAnimationCacheImpl",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/CryptoUtils:CryptoUtils",
        "//submodules/TelegramUI/Components/AnimationCache:AnimationCache",
        "//submodules/TelegramUI/Components/AnimationCache/ImageDCT:ImageDCT",
    ],
)

ios_test_runner(
    name = "DCTAnimationCacheImplTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "DCTAnimationCacheImplTests",
    minimum_os_version = "15.0",
    runner = ":DCTAnimationCacheImplTestRunner",
    resources = glob([
        "Tests/Resources/*.bin",
    ]),
    deps = [
        ":DCTAnimationCacheImplTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
