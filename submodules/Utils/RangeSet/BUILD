load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_test")

swift6_library(
    name = "RangeSet",
    module_name = "RangeSet",
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

# Host (macOS) test: `./build-input/bazel-9.3.1-darwin-arm64 test //submodules/Utils/RangeSet:RangeSetTests`.
swift_test(
    name = "RangeSetTests",
    srcs = [
        "Tests/RangeSetTests.swift",
    ],
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":RangeSet",
    ],
)
