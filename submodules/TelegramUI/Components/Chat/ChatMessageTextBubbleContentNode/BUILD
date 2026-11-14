load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "ChatMessageTextBubbleContentNode",
    module_name = "ChatMessageTextBubbleContentNode",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/TelegramCore",
        "//submodules/TextFormat",
        "//submodules/UrlEscaping",
        "//submodules/TelegramUniversalVideoContent",
        "//submodules/TextSelectionNode",
        "//submodules/InvisibleInkDustNode",
        "//submodules/Emoji",
        "//submodules/AnimatedStickerNode",
        "//submodules/TelegramAnimatedStickerNode",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/AccountContext",
        "//submodules/WalletContext",
        "//submodules/YuvConversion",
        "//submodules/TelegramUI/Components/AnimationCache",
        "//submodules/TelegramUI/Components/LottieAnimationCache",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer",
        "//submodules/TelegramUI/Components/EmojiTextAttachmentView",
        "//submodules/TelegramUI/Components/TextNodeWithEntities",
        "//submodules/TelegramUI/Components/Chat/ChatMessageDateAndStatusNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageBubbleContentNode",
        "//submodules/TelegramUI/Components/Chat/ShimmeringLinkNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemCommon",
        "//submodules/TelegramUI/Components/Chat/MessageQuoteComponent",
        "//submodules/TelegramUI/Components/TextLoadingEffect",
        "//submodules/TelegramUI/Components/ChatControllerInteraction",
        "//submodules/TelegramUI/Components/InteractiveTextComponent",
        "//submodules/TelegramUI/Components/ShimmeringMask",
        "//submodules/TelegramUI/Components/StreamingTextReveal:StreamingTextReveal",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ChatMessageTextBubbleContentNodeTestsLib",
    testonly = True,
    srcs = glob(["Tests/**/*.swift"]),
    deps = [
        ":ChatMessageTextBubbleContentNode",
        "//submodules/TelegramCore",
        "//submodules/TextFormat",
    ],
)

ios_test_runner(
    name = "ChatMessageTextBubbleContentNodeTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "ChatMessageTextBubbleContentNodeTests",
    minimum_os_version = "26.0",
    runner = ":ChatMessageTextBubbleContentNodeTestRunner",
    deps = [
        ":ChatMessageTextBubbleContentNodeTestsLib",
    ],
)
