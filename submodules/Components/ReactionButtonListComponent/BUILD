load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "ReactionButtonListComponent",
    module_name = "ReactionButtonListComponent",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Display:Display",
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/WebPBinding:WebPBinding",
        "//submodules/AnimatedAvatarSetNode:AnimatedAvatarSetNode",
        "//submodules/Components/ReactionImageComponent:ReactionImageComponent",
        "//submodules/TelegramUI/Components/EmojiTextAttachmentView:EmojiTextAttachmentView",
        "//submodules/TelegramUI/Components/AnimationCache:AnimationCache",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer:MultiAnimationRenderer",
        "//submodules/TextFormat:TextFormat",
        "//submodules/AppBundle",
        "//submodules/TelegramUI/Components/AnimatedTextComponent",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ReactionButtonListComponentTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":ReactionButtonListComponent",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramUI/Components/EmojiTextAttachmentView:EmojiTextAttachmentView",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer:MultiAnimationRenderer",
    ],
)

ios_test_runner(
    name = "ReactionButtonListComponentTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "ReactionButtonListComponentTests",
    minimum_os_version = "15.0",
    runner = ":ReactionButtonListComponentTestRunner",
    deps = [
        ":ReactionButtonListComponentTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
