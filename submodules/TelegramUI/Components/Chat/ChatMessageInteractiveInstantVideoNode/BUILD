load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "ChatMessageInteractiveInstantVideoNode",
    module_name = "ChatMessageInteractiveInstantVideoNode",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
        #"-Xfrontend", "-debug-time-function-bodies"
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
        "//submodules/TelegramPresentationData",
        "//submodules/AccountContext",
        "//submodules/RadialStatusNode",
        "//submodules/SemanticStatusNode",
        "//submodules/PhotoResources",
        "//submodules/TelegramUniversalVideoContent",
        "//submodules/FileMediaResourceStatus",
        "//submodules/Components/HierarchyTrackingLayer",
        "//submodules/ComponentFlow",
        "//submodules/TelegramUI/Components/StaticGlassBackground",
        "//submodules/TelegramUI/Components/AudioTranscriptionButtonComponent",
        "//submodules/UndoUI",
        "//submodules/TelegramNotices",
        "//submodules/Markdown",
        "//submodules/TextFormat",
        "//submodules/InvisibleInkDustNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageForwardInfoNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageDateAndStatusNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemCommon",
        "//submodules/TelegramUI/Components/Chat/ChatMessageBubbleContentNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageReplyInfoNode",
        "//submodules/TelegramUI/Components/Chat/InstantVideoRadialStatusNode",
        "//submodules/TelegramUI/Components/Chat/ChatInstantVideoMessageDurationNode",
        "//submodules/TelegramUI/Components/ChatControllerInteraction",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ChatMessageInteractiveInstantVideoNodeTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":ChatMessageInteractiveInstantVideoNode",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15.
ios_test_runner(
    name = "ChatMessageInteractiveInstantVideoNodeTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "ChatMessageInteractiveInstantVideoNodeTests",
    minimum_os_version = "26.0",
    runner = ":ChatMessageInteractiveInstantVideoNodeTestRunner",
    deps = [
        ":ChatMessageInteractiveInstantVideoNodeTestsLib",
    ],
)
