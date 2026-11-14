load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "PhotoResources",
    module_name = "PhotoResources",
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
        "//submodules/Display:Display",
        "//submodules/ImageTransparency:ImageTransparency",
        "//submodules/TinyThumbnail:TinyThumbnail",
        "//submodules/ImageBlur:ImageBlur",
        "//submodules/Tuples:Tuples",
        "//submodules/AccountContext:AccountContext",
        "//submodules/MediaResources:MediaResources",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/WebPBinding:WebPBinding",
        "//submodules/AppBundle:AppBundle",
        "//submodules/MusicAlbumArtResources:MusicAlbumArtResources",
        "//submodules/Svg/LegacyImpl",
        "//submodules/Utils/RangeSet:RangeSet",
        "//submodules/ImageCompression",
        "//submodules/PassRenderer:PassRenderer",
        "//submodules/ImageDecodeSizing",
        "//submodules/HLSPlayback:HLSPlayback",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "PhotoResourcesTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":PhotoResources",
    ],
)

ios_test_runner(
    name = "PhotoResourcesTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "PhotoResourcesTests",
    minimum_os_version = "15.0",
    runner = ":PhotoResourcesTestRunner",
    deps = [
        ":PhotoResourcesTestsLib",
    ],
)
