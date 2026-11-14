load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "SparseItemGrid",
    module_name = "SparseItemGrid",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Display:Display",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/AnimationUI:AnimationUI",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/Components/MultilineTextComponent",
        "//submodules/TelegramUI/Components/GlassBackgroundComponent",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "SparseItemGridTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":SparseItemGrid",
    ],
)

ios_test_runner(
    name = "SparseItemGridTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "SparseItemGridTests",
    minimum_os_version = "26.0",
    runner = ":SparseItemGridTestRunner",
    deps = [
        ":SparseItemGridTestsLib",
    ],
)
