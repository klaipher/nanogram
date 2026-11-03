load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "TelegramIntents",
    module_name = "TelegramIntents",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
    	"//submodules/TelegramCore:TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/AvatarNode:AvatarNode",
        "//submodules/NotificationsPresentationData:NotificationsPresentationData",
    ],
    visibility = [
        "//visibility:public",
    ],
)
