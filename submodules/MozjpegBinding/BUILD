
load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

objc_library(
    name = "MozjpegBinding",
    module_name = "MozjpegBinding",
    enable_modules = True,
    srcs = glob([
        "Sources/**/*.m",
        "Sources/**/*.mm",
        "Sources/**/*.h",
    ], allow_empty=True),
    hdrs = glob([
        "Public/**/*.h",
    ]),
    includes = [
        "Public",
    ],
    deps = [
        "//third-party/libjpeg-turbo:libjpeg_turbo",
    ],
    sdk_frameworks = [
        "Accelerate",
    ],
    visibility = [
        "//visibility:public",
    ]
)

swift_library(
    name = "MozjpegBindingTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":MozjpegBinding",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15.
ios_test_runner(
    name = "MozjpegBindingTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "MozjpegBindingTests",
    minimum_os_version = "26.0",
    runner = ":MozjpegBindingTestRunner",
    deps = [
        ":MozjpegBindingTestsLib",
    ],
)
