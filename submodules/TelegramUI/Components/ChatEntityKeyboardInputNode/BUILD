load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "ChatEntityKeyboardInputNode",
    module_name = "ChatEntityKeyboardInputNode",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/ChatPresentationInterfaceState:ChatPresentationInterfaceState",
        "//submodules/TelegramUI/Components/ButtonComponent",
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/Components/ComponentDisplayAdapters:ComponentDisplayAdapters",
        "//submodules/Components/MultilineTextComponent",
        "//submodules/TelegramUI/Components/EdgeEffect",
        "//submodules/TelegramUI/Components/EntityKeyboard:EntityKeyboard",
        "//submodules/TelegramUI/Components/EmojiTextAttachmentView",
        "//submodules/TelegramUI/Components/AnimationCache:AnimationCache",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer:MultiAnimationRenderer",
        "//submodules/TextFormat:TextFormat",
        "//submodules/AppBundle:AppBundle",
        "//submodules/SearchBarNode:SearchBarNode",
        "//submodules/TelegramUI/Components/ChatInputNode:ChatInputNode",
        "//submodules/Components/PagerComponent:PagerComponent",
        "//submodules/PremiumUI:PremiumUI",
        "//submodules/UndoUI:UndoUI",
        "//submodules/ContextUI:ContextUI",
        "//submodules/StickerResources",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramNotices:TelegramNotices",
        "//submodules/StickerPeekUI:StickerPeekUI",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/TelegramUI/Components/MultiplexedVideoNode:MultiplexedVideoNode",
        "//submodules/TelegramUI/Components/ChatControllerInteraction:ChatControllerInteraction",
        "//submodules/FeaturedStickersScreen:FeaturedStickersScreen",
        "//submodules/TelegramUI/Components/EntityKeyboardGifContent:EntityKeyboardGifContent",
        "//submodules/TelegramUI/Components/GlassControls",
        "//submodules/TelegramUI/Components/LegacyMessageInputPanelInputView:LegacyMessageInputPanelInputView",
        "//submodules/TelegramUI/Components/BatchVideoRendering",
        "//submodules/TelegramUI/Components/GlassBackgroundComponent",
        "//submodules/TelegramUI/Components/SubcodecAnimationCacheImpl:SubcodecAnimationCacheImpl",
        "//submodules/TelegramUI/Components/SubcodecMultiAnimationRendererImpl:SubcodecMultiAnimationRendererImpl",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ChatEntityKeyboardInputNodeTestsLib",
    testonly = True,
    srcs = glob(["Tests/**/*.swift"]),
    deps = [
        ":ChatEntityKeyboardInputNode",
        "//submodules/Postbox:Postbox",
    ],
)

ios_test_runner(
    name = "ChatEntityKeyboardInputNodeTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "ChatEntityKeyboardInputNodeTests",
    minimum_os_version = "15.0",
    runner = ":ChatEntityKeyboardInputNodeTestRunner",
    deps = [":ChatEntityKeyboardInputNodeTestsLib"],
)
