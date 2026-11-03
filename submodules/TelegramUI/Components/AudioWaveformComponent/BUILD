load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "AudioWaveformComponent",
    module_name = "AudioWaveformComponent",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/AppBundle:AppBundle",
        "//submodules/Display:Display",
        "//submodules/ShimmerEffect:ShimmerEffect",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "AudioWaveformComponentTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":AudioWaveformComponent",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
    ],
)

ios_test_runner(
    name = "AudioWaveformComponentTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "AudioWaveformComponentTests",
    minimum_os_version = "15.0",
    runner = ":AudioWaveformComponentTestRunner",
    deps = [
        ":AudioWaveformComponentTestsLib",
    ],
)
