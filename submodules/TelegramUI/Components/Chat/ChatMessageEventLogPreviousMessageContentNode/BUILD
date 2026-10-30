load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "ChatMessageEventLogPreviousMessageContentNode",
    module_name = "ChatMessageEventLogPreviousMessageContentNode",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/Display",
        "//submodules/LottieSettings:LottieSettings",
        "//submodules/AsyncDisplayKit",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/TelegramUI/Components/Chat/ChatMessageBubbleContentNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemCommon",
        "//submodules/TelegramUI/Components/Chat/ChatMessageAttachedContentNode",
    ],
    visibility = [
        "//visibility:public",
    ],
)
