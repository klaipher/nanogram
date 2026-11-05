load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

swift_library(
    name = "SwiftSignalKit",
    module_name = "SwiftSignalKit",
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

# Host (macOS) test of the signpost names and the launch-task bookkeeping.
# Run with `./build-input/bazel-9.3.1-darwin-arm64 test //submodules/SSignalKit/SwiftSignalKit:SwiftSignalKitTests`.
swift_test(
    name = "SwiftSignalKitTests",
    srcs = glob(["Tests/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [":SwiftSignalKit"],
)
