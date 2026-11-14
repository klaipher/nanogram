load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "TelegramPresentationData",
    module_name = "TelegramPresentationData",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/Postbox:Postbox",
        "//submodules/Display:Display",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/HardenedMedia",
        "//submodules/MediaResources:MediaResources",
        "//submodules/AppBundle:AppBundle",
        "//submodules/StringPluralization:StringPluralization",
        "//submodules/Sunrise:Sunrise",
        "//submodules/TinyThumbnail:TinyThumbnail",
        "//submodules/FastBlur:FastBlur",
        "//Telegram:PresentationStrings",
        "//submodules/NanogramBranding",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "TelegramPresentationDataTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/Display:Display",
        "//submodules/Postbox:Postbox",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15. Matches //submodules/ChatMessageBackground:ChatMessageBackgroundTests.
ios_test_runner(
    name = "TelegramPresentationDataTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "TelegramPresentationDataTests",
    minimum_os_version = "26.0",
    runner = ":TelegramPresentationDataTestRunner",
    deps = [
        ":TelegramPresentationDataTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
