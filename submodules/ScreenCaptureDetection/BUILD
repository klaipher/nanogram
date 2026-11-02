load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "ScreenCaptureDetection",
    module_name = "ScreenCaptureDetection",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
    	"//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
