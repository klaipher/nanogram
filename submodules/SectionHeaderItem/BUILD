load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "SectionHeaderItem",
    module_name = "SectionHeaderItem",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/ListSectionHeaderNode:ListSectionHeaderNode",
    ],
    visibility = [
        "//visibility:public",
    ],
)
