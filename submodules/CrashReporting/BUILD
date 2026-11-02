load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

swift_library(
    name = "CrashReporting",
    module_name = "CrashReporting",
    srcs = glob(["Sources/*.swift"]),
    copts = ["-warnings-as-errors"],
    visibility = ["//visibility:public"],
)

# Host (macOS) test of the report stores: Foundation and CryptoKit only.
# Run with `./build-input/bazel-9.3.1-darwin-arm64 test //submodules/CrashReporting:CrashReportingTests`.
swift_test(
    name = "CrashReportingTests",
    srcs = glob(["Tests/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [":CrashReporting"],
)
