load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "FlatBuffers",
    module_name = "FlatBuffers",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    # No -suppress-warnings: it conflicts with the global "-Wwarning DeprecatedDeclaration" copt (.bazelrc).
    deps = [
    ],
    visibility = [
        "//visibility:public",
    ],
)
