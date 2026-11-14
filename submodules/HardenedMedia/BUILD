load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_test")

swift6_library(
    name = "HardenedMedia",
    module_name = "HardenedMedia",
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

# Host (macOS) test: `./build-input/bazel-9.3.2-darwin-arm64 test //submodules/HardenedMedia:HardenedMediaTests`.
swift_test(
    name = "HardenedMediaTests",
    srcs = [
        "Tests/HardenedMediaTests.swift",
    ],
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":HardenedMedia",
    ],
)
