load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "AvatarNode",
    module_name = "AvatarNode",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/Postbox",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/AnimationUI:AnimationUI",
        "//submodules/AppBundle:AppBundle",
        "//submodules/AccountContext:AccountContext",
        "//submodules/Emoji:Emoji",
        "//submodules/TinyThumbnail:TinyThumbnail",
        "//submodules/FastBlur:FastBlur",
        "//submodules/ComponentFlow",
        "//submodules/TelegramUI/Components/Stories/AvatarStoryIndicatorComponent",
        "//submodules/DirectMediaImageCache",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "AvatarNodeTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":AvatarNode",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/ComponentFlow",
        "//submodules/MozjpegBinding:MozjpegBinding",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15.
ios_test_runner(
    name = "AvatarNodeTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "AvatarNodeTests",
    minimum_os_version = "15.0",
    runner = ":AvatarNodeTestRunner",
    deps = [
        ":AvatarNodeTestsLib",
    ],
)
