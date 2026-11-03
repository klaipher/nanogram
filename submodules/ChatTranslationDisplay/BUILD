load("//build-system/bazel-utils:swift_strict.bzl", "strict_swift_library", "strict_swift_test")

strict_swift_library(
    name = "ChatTranslationDisplay",
    module_name = "ChatTranslationDisplay",
    srcs = glob(["Sources/**/*.swift"]),
    deps = [],
    visibility = ["//visibility:public"],
)

# Runs on the Mac: the module needs only the standard library.
strict_swift_test(
    name = "ChatTranslationDisplayTests",
    srcs = glob(["Tests/**/*.swift"]),
    deps = [":ChatTranslationDisplay"],
)
