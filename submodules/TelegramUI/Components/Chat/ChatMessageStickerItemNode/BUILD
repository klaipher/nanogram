load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "ChatMessageStickerItemNode",
    module_name = "ChatMessageStickerItemNode",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/TelegramUI/Components/StaticGlassBackground",
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/TelegramPresentationData",
        "//submodules/TextFormat",
        "//submodules/AccountContext",
        "//submodules/StickerResources",
        "//submodules/ContextUI",
        "//submodules/Markdown",
        "//submodules/ShimmerEffect",
        "//submodules/WallpaperBackgroundNode",
        "//submodules/TelegramUI/Components/ChatControllerInteraction",
        "//submodules/TelegramUI/Components/Chat/ChatMessageForwardInfoNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageDateAndStatusNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemCommon",
        "//submodules/TelegramUI/Components/Chat/ChatMessageReplyInfoNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItem",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemView",
        "//submodules/TelegramUI/Components/Chat/ChatMessageSwipeToReplyNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageSelectionNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageDeliveryFailedNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageShareButton",
        "//submodules/TelegramUI/Components/Chat/ChatMessageThreadInfoNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageActionButtonsNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageReactionsFooterContentNode",
        "//submodules/TelegramUI/Components/Chat/ChatSwipeToReplyRecognizer",
        "//submodules/TelegramUI/Components/Chat/ChatMessageSuggestedPostInfoNode",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ChatMessageStickerItemNodeTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":ChatMessageStickerItemNode",
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemView",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15.
ios_test_runner(
    name = "ChatMessageStickerItemNodeTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "ChatMessageStickerItemNodeTests",
    minimum_os_version = "15.0",
    runner = ":ChatMessageStickerItemNodeTestRunner",
    deps = [
        ":ChatMessageStickerItemNodeTestsLib",
    ],
)
