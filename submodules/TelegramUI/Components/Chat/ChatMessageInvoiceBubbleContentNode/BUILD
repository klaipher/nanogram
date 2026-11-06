load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "ChatMessageInvoiceBubbleContentNode",
    module_name = "ChatMessageInvoiceBubbleContentNode",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/Display",
        "//submodules/AsyncDisplayKit",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/TelegramUIPreferences",
        "//submodules/TelegramStringFormatting",
        "//submodules/TelegramUI/Components/Chat/ChatMessageBubbleContentNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemCommon",
        "//submodules/TelegramUI/Components/Chat/ChatMessageAttachedContentNode",
    ],
    visibility = [
        "//visibility:public",
    ],
)
