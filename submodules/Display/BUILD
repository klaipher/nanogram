load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "Display",
    module_name = "Display",
    srcs = glob([
        "Source/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
    	"//submodules/ObjCRuntimeUtils:ObjCRuntimeUtils",
    	"//submodules/UIKitRuntimeUtils:UIKitRuntimeUtils",
        "//submodules/AppBundle:AppBundle",
    	"//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Markdown:Markdown",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "DisplayTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":Display",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15.
ios_test_runner(
    name = "DisplayTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "DisplayTests",
    minimum_os_version = "15.0",
    runner = ":DisplayTestRunner",
    deps = [
        ":DisplayTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# ListView motion tests alone, so they run while other Display tests are mid-change.
swift_library(
    name = "ListViewMotionTestsLib",
    testonly = True,
    srcs = [
        "Tests/ListViewTransferVelocityTests.swift",
        "Tests/ListViewDeferredAccessibilityTests.swift",
    ],
    deps = [
        ":Display",
    ],
)

ios_unit_test(
    name = "ListViewMotionTests",
    minimum_os_version = "15.0",
    runner = ":DisplayTestRunner",
    deps = [
        ":ListViewMotionTestsLib",
    ],
)
