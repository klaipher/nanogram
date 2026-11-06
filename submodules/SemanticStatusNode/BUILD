load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "SemanticStatusNode",
    module_name = "SemanticStatusNode",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Display:Display",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/LegacyComponents:LegacyComponents",
        "//submodules/GZip:GZip",
        "//submodules/LottieBinding:LottieBinding",
        "//submodules/AppBundle:AppBundle",
        "//submodules/ManagedAnimationNode:ManagedAnimationNode",
        "//submodules/Components/HierarchyTrackingLayer",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "SemanticStatusNodeTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":SemanticStatusNode",
    ],
    # LegacyComponents (a transitive dependency) leaves these to the app; a test bundle needs them.
    linkopts = [
        "-lz",
        "-framework",
        "Accelerate",
        "-framework",
        "AVKit",
    ],
)

ios_test_runner(
    name = "SemanticStatusNodeTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "SemanticStatusNodeTests",
    minimum_os_version = "15.0",
    runner = ":SemanticStatusNodeTestRunner",
    deps = [
        ":SemanticStatusNodeTestsLib",
    ],
)
