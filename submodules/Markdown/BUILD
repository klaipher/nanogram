load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "Markdown",
    module_name = "Markdown",
    srcs = glob([
        "Source/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    visibility = [
        "//visibility:public",
    ],
)
