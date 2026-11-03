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

# iPad layout rules (TabletLayoutRules.swift) and the iPad device profiles alone.
swift_library(
    name = "TabletLayoutTestsLib",
    testonly = True,
    srcs = [
        "Tests/TabletLayoutRulesTests.swift",
    ],
    deps = [
        ":Display",
    ],
)

ios_unit_test(
    name = "TabletLayoutTests",
    minimum_os_version = "15.0",
    runner = ":DisplayTestRunner",
    deps = [
        ":TabletLayoutTestsLib",
    ],
)

# iPad system-API rules (TabletSystemRules.swift) alone.
swift_library(
    name = "TabletSystemTestsLib",
    testonly = True,
    srcs = [
        "Tests/TabletSystemRulesTests.swift",
    ],
    deps = [
        ":Display",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

ios_unit_test(
    name = "TabletSystemTests",
    minimum_os_version = "15.0",
    runner = ":DisplayTestRunner",
    deps = [
        ":TabletSystemTestsLib",
    ],
)

# The resizable chat-list column (SplitColumnWidth.swift) alone.
swift_library(
    name = "SplitColumnWidthTestsLib",
    testonly = True,
    srcs = [
        "Tests/SplitColumnWidthTests.swift",
        "Tests/SplitMasterWidthTests.swift",
    ],
    deps = [
        ":Display",
    ],
)

ios_unit_test(
    name = "SplitColumnWidthTests",
    minimum_os_version = "15.0",
    runner = ":DisplayTestRunner",
    deps = [
        ":SplitColumnWidthTestsLib",
    ],
)

# The second iPad batch of the iPadOS 27 audit (TabletEnergyRules, TabletMainMenuRules, TabletPencilRules,
# TabletOrientationRules) alone.
swift_library(
    name = "TabletSecondBatchTestsLib",
    testonly = True,
    srcs = [
        "Tests/TabletSecondBatchRulesTests.swift",
        "Tests/TabletReviewFixesTests.swift",
    ],
    deps = [
        ":Display",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

ios_unit_test(
    name = "TabletSecondBatchTests",
    minimum_os_version = "15.0",
    runner = ":DisplayTestRunner",
    deps = [
        ":TabletSecondBatchTestsLib",
    ],
)
