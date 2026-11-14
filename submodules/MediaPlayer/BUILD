load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "UniversalMediaPlayer",
    module_name = "UniversalMediaPlayer",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/Postbox:Postbox",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramAudio:TelegramAudio",
        "//submodules/FFMpegBinding:FFMpegBinding",
        "//submodules/RingBuffer:RingBuffer",
        "//submodules/YuvConversion:YuvConversion",
        "//submodules/Utils/RangeSet:RangeSet",
        "//submodules/TextFormat:TextFormat",
        "//submodules/ManagedFile",
        "//submodules/DiskWriteAccounting",
        "//submodules/HLSPlayback:HLSPlayback",
        "//submodules/MediaCapabilities:MediaCapabilities",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "UniversalMediaPlayerTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":UniversalMediaPlayer",
        "//submodules/FFMpegBinding:FFMpegBinding",
        "//submodules/HLSPlayback:HLSPlayback",
        "//submodules/Postbox:Postbox",
        "//submodules/Utils/RangeSet:RangeSet",
        "//submodules/TelegramAudio:TelegramAudio",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/DiskWriteAccounting",
    ],
)

ios_test_runner(
    name = "UniversalMediaPlayerTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "UniversalMediaPlayerTests",
    minimum_os_version = "26.0",
    runner = ":UniversalMediaPlayerTestRunner",
    resources = glob([
        "Tests/Resources/*",
        "Tests/Fixtures/*.mp4",
    ]),
    deps = [
        ":UniversalMediaPlayerTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
