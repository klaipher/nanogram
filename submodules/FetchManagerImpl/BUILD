load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "FetchManagerImpl",
    module_name = "FetchManagerImpl",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/AccountContext:AccountContext",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
        "//submodules/Utils/RangeSet:RangeSet",
    ],
    visibility = [
        "//visibility:public",
    ],
)
