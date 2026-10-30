load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "FileMediaResourceStatus",
    module_name = "FileMediaResourceStatus",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
    ],
    visibility = [
        "//visibility:public",
    ],
)
