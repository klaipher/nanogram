load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "ImageObjectSeparation",
    module_name = "ImageObjectSeparation",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/AccountContext",
        "//submodules/AppBundle",
        "//submodules/ImageTransparency",
        "//submodules/TelegramUI/Components/AnimationCache/ImageDCT",
        "//submodules/FileMediaResourceStatus",
        "//third-party/ZipArchive:ZipArchive",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ImageObjectSeparationTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":ImageObjectSeparation",
    ],
)

ios_test_runner(
    name = "ImageObjectSeparationTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "ImageObjectSeparationTests",
    minimum_os_version = "15.0",
    runner = ":ImageObjectSeparationTestRunner",
    deps = [
        ":ImageObjectSeparationTestsLib",
    ],
)
