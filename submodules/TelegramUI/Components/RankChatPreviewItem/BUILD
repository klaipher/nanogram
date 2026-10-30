load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "RankChatPreviewItem",
    module_name = "RankChatPreviewItem",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/ComponentFlow",
        "//submodules/Components/ViewControllerComponent",
        "//submodules/Components/ComponentDisplayAdapters",
        "//submodules/TelegramPresentationData",
        "//submodules/AccountContext",
        "//submodules/ItemListUI",
        "//submodules/PresentationDataUtils",
        "//submodules/WallpaperBackgroundNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemImpl",
	"//submodules/TelegramUI/Components/ListItemComponentAdaptor",
    ],
    visibility = [
        "//visibility:public",
    ],
)
