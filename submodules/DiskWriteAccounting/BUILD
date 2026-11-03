load("//build-system/bazel-utils:swift_strict.bzl", "strict_swift_library", "strict_swift_test")

strict_swift_library(
    name = "DiskWriteAccounting",
    module_name = "DiskWriteAccounting",
    srcs = glob(["Sources/**/*.swift"]),
    deps = [],
    visibility = ["//visibility:public"],
)

# Runs on the Mac: ./build-input/bazel-<version>-darwin-arm64 test //submodules/DiskWriteAccounting:DiskWriteAccountingTests
strict_swift_test(
    name = "DiskWriteAccountingTests",
    srcs = glob(["Tests/**/*.swift"]),
    deps = [":DiskWriteAccounting"],
)
