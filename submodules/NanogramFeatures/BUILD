load("//build-system/bazel-utils:swift_strict.bzl", "strict_swift_library", "strict_swift_test")

# Pure logic of Settings > Nanogram features: search operators and link hygiene (docs/specs/search-operators.md).
strict_swift_library(
    name = "NanogramFeatures",
    module_name = "NanogramFeatures",
    srcs = glob(["Sources/**/*.swift"]),
    visibility = ["//visibility:public"],
)

# Host (macOS) test; it needs nothing but Foundation.
strict_swift_test(
    name = "NanogramFeaturesTests",
    srcs = glob(["Tests/**/*.swift"]),
    deps = [":NanogramFeatures"],
)
