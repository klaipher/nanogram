load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "SearchPeerMembers",
    module_name = "SearchPeerMembers",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/StringTransliteration:StringTransliteration",
    ],
    visibility = [
        "//visibility:public",
    ],
)
