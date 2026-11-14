load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "LottieBinding",
    module_name = "LottieBinding",
    srcs = glob(["Sources/**/*.swift"]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/tlottie:TLottieBinding",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "LottieBindingTestsLib",
    testonly = True,
    srcs = glob(["Tests/**/*.swift"]),
    deps = [
        ":LottieBinding",
        "//submodules/tlottie:TLottieBinding",
    ],
)

# The runner must be pinned to a real device and OS. The default runner picks an
# invalid device and the test process exits 15.
ios_test_runner(
    name = "LottieBindingTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "LottieBindingTests",
    minimum_os_version = "26.0",
    runner = ":LottieBindingTestRunner",
    deps = [":LottieBindingTestsLib"],
    visibility = [
        "//visibility:public",
    ],
)
