load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

swift_library(
    name = "ImageDecodeSizing",
    module_name = "ImageDecodeSizing",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Host (macOS) test: ImageIO and CoreGraphics only.
# Run with `./build-input/bazel-9.3.1-darwin-arm64 test //submodules/ImageDecodeSizing:ImageDecodeSizingTests`.
swift_test(
    name = "ImageDecodeSizingTests",
    srcs = [
        "Tests/ImageDecodeSizingTests.swift",
    ],
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":ImageDecodeSizing",
    ],
)
