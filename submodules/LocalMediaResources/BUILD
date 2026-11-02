load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "LocalMediaResources",
    module_name = "LocalMediaResources",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/ImageCompression:ImageCompression",
        "//submodules/PersistentStringHash:PersistentStringHash",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "LocalMediaResourcesTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":LocalMediaResources",
    ],
)

ios_test_runner(
    name = "LocalMediaResourcesTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "LocalMediaResourcesTests",
    minimum_os_version = "15.0",
    runner = ":LocalMediaResourcesTestRunner",
    deps = [
        ":LocalMediaResourcesTestsLib",
    ],
)
