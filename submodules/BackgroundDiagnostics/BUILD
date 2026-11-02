load("//build-system/bazel-utils:swift_strict.bzl", "strict_swift_library", "strict_swift_test")

strict_swift_library(
    name = "BackgroundDiagnostics",
    module_name = "BackgroundDiagnostics",
    srcs = glob(["Sources/**/*.swift"]),
    deps = [],
    visibility = ["//visibility:public"],
)

# Runs on the Mac: ./build-input/bazel-<version>-darwin-arm64 test //submodules/BackgroundDiagnostics:BackgroundDiagnosticsTests
strict_swift_test(
    name = "BackgroundDiagnosticsTests",
    srcs = glob(["Tests/**/*.swift"]),
    deps = [":BackgroundDiagnostics"],
)
