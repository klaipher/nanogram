load("//build-system/bazel-utils:swift_strict.bzl", "strict_swift_library", "strict_swift_test")

# Says "Nanogram" where a string names this app, in every language pack the app loads.
# The key lists in Sources/NanogramIdentityKeys.swift are also read by tools/dev/lint/branding.py.
strict_swift_library(
    name = "NanogramBranding",
    module_name = "NanogramBranding",
    srcs = glob(["Sources/**/*.swift"]),
    deps = [],
    visibility = ["//visibility:public"],
)

# Runs on the Mac: the module needs only the standard library.
# `./build-input/bazel-9.3.2-darwin-arm64 test //submodules/NanogramBranding:NanogramBrandingTests`
strict_swift_test(
    name = "NanogramBrandingTests",
    srcs = glob(["Tests/**/*.swift"]),
    deps = [":NanogramBranding"],
)
