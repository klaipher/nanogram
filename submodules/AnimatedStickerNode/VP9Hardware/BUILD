load("//build-system/bazel-utils:swift_strict.bzl", "strict_swift_library", "strict_swift_test")

# Hardware VP9 decoding for video stickers: a small WebM demuxer, the iOS 26.2+ supplemental
# VideoToolbox decoder and a probe for it. AnimatedStickerNode uses it only when the probe
# reports a hardware decoder; libvpx stays the default and the fallback.
strict_swift_library(
    name = "VP9Hardware",
    module_name = "VP9Hardware",
    srcs = glob(["Sources/**/*.swift"]),
    visibility = ["//visibility:public"],
)

# Host (macOS) test: Apple silicon Macs have the VP9 decoder and the simulator has none, so this
# is where hardware frames are compared with libvpx. Run with
# `./build-input/bazel-9.3.2-darwin-arm64 test //submodules/AnimatedStickerNode/VP9Hardware:VP9HardwareTests`.
strict_swift_test(
    name = "VP9HardwareTests",
    srcs = glob(["Tests/**/*.swift"]),
    data = glob(["Tests/Resources/*.webm"]),
    deps = [":VP9Hardware"],
)
