load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "UrlHandling",
    module_name = "UrlHandling",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/TelegramNotices:TelegramNotices",
        "//submodules/WalletContext:WalletContext",
    ],
    visibility = [
        "//visibility:public",
    ],
)
