load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "AnimationCache",
    module_name = "AnimationCache",
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
