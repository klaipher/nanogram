load("//build-system/bazel-utils:swift_strict.bzl", "strict_swift_library", "strict_swift_test")

# One place that answers "which codec runs on the hardware of this device": cached VideoToolbox probes and the
# pure rules that turn them into a decode path. MediaPlayer, the VP9 sticker decoder and Send Logs use it.
strict_swift_library(
    name = "MediaCapabilities",
    module_name = "MediaCapabilities",
    srcs = glob(["Sources/**/*.swift"]),
    visibility = ["//visibility:public"],
)

# Host (macOS) test; it needs nothing but VideoToolbox.
# Run with `./build-input/bazel-9.3.2-darwin-arm64 test //submodules/MediaCapabilities:MediaCapabilitiesTests`.
strict_swift_test(
    name = "MediaCapabilitiesTests",
    srcs = glob(["Tests/**/*.swift"]),
    deps = [":MediaCapabilities"],
)
