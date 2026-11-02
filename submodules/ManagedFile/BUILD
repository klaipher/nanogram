load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "ManagedFile",
    module_name = "ManagedFile",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
