load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "ChatMessageStarsMediaInfoNode",
    module_name = "ChatMessageStarsMediaInfoNode",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramPresentationData",
        "//submodules/AccountContext",
        "//submodules/LocalizedPeerData",
        "//submodules/PhotoResources",
        "//submodules/TelegramStringFormatting",
        "//submodules/TextFormat",
        "//submodules/TelegramUI/Components/TextNodeWithEntities",
        "//submodules/ComponentFlow",
        "//submodules/WallpaperBackgroundNode",
        "//submodules/TelegramUI/Components/ChatControllerInteraction",
    ],
    visibility = [
        "//visibility:public",
    ],
)
