load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "TelegramNotices",
    module_name = "TelegramNotices",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramPermissions:TelegramPermissions",
    ],
    visibility = [
        "//visibility:public",
    ],
)
