load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

config_setting(
    name = "debug_build",
    values = {
        "compilation_mode": "dbg",
    },
)

optimization_flags = select({
    ":debug_build": [
        #"-O",
    ],
    "//conditions:default": [],
})

swift_library(
    name = "AnimatedStickerNode",
    module_name = "AnimatedStickerNode",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ] + optimization_flags,
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/YuvConversion:YuvConversion",
        "//submodules/GZip:GZip",
        "//submodules/LottieBinding:LottieBinding",
        "//submodules/LottieSettings:LottieSettings",
        "//submodules/MediaResources:MediaResources",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
        "//submodules/ManagedFile:ManagedFile",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AnimationCompression:AnimationCompression",
        "//submodules/Components/MetalImageView:MetalImageView",
        "//submodules/WebPBinding:WebPBinding",
        "//submodules/AnimatedStickerNode/VP9Hardware:VP9Hardware",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "AnimatedStickerNodeTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":AnimatedStickerNode",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/YuvConversion:YuvConversion",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/FFMpegBinding:FFMpegBinding",
        "//submodules/AnimatedStickerNode/VP9Hardware:VP9Hardware",
        "//submodules/LottieSettings:LottieSettings",
        "//submodules/MediaResources:MediaResources",
        "//submodules/AnimationCompression:AnimationCompression",
        "//submodules/AnimationCompression:DctHuffman",
    ],
)

ios_test_runner(
    name = "AnimatedStickerNodeTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "AnimatedStickerNodeTests",
    minimum_os_version = "15.0",
    runner = ":AnimatedStickerNodeTestRunner",
    resources = glob([
        "Tests/Resources/*.bin",
        "Tests/Resources/*.webm",
        "Tests/Resources/*.tgs",
    ]),
    deps = [
        ":AnimatedStickerNodeTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
