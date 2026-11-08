load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

# Pure-UIKit virtualized list library, vendored from the standalone CoreListDemo
# project (which keeps its own Xcode infrastructure alongside this BUILD file).
# The demo app entry points, demo view controllers, demo item, and demo-side
# loading policy are excluded so only the reusable library compiles here.
CORE_LIST_LIBRARY_SRCS = glob(
    ["CoreListDemo/**/*.swift"],
    exclude = [
        "CoreListDemo/AppDelegate.swift",
        "CoreListDemo/SceneDelegate.swift",
        "CoreListDemo/ViewController.swift",
        "CoreListDemo/PhysicsScrollDemoViewController.swift",
        "CoreListDemo/ScrollComparisonViewController.swift",
        "CoreListDemo/PipelineDepthProbe.swift",
        "CoreListDemo/PipelineDepthViewController.swift",
        "CoreListDemo/DemoRow.swift",
        "CoreListDemo/AutoLoadResponseScheduler.swift",
    ],
)

swift_library(
    name = "CoreList",
    module_name = "CoreList",
    srcs = CORE_LIST_LIBRARY_SRCS,
    visibility = [
        "//visibility:public",
    ],
)

# The same library sources under the demo's module name, so test files written for the
# Xcode CoreListDemoTests target (`@testable import CoreListDemo`) also run under Bazel.
# Only a hand-picked subset of those tests is listed below; the full suite stays on
# xcodebuild (see CLAUDE.md).
swift_library(
    name = "CoreListDemoForTests",
    module_name = "CoreListDemo",
    testonly = True,
    srcs = CORE_LIST_LIBRARY_SRCS,
)

swift_library(
    name = "CoreListAttachmentFlightTestsLib",
    testonly = True,
    srcs = glob(
        ["CoreListDemoTests/TestSupport/*.swift"],
        exclude = [
            # Needs the demo-only AutoLoadResponseScheduler.
            "CoreListDemoTests/TestSupport/ManualAutoLoadResponseScheduler.swift",
        ],
    ) + [
        "CoreListDemoTests/AttachmentKeyframeParityTests.swift",
        "CoreListDemoTests/AttachmentFlightTrackReuseTests.swift",
    ],
    deps = [
        ":CoreListDemoForTests",
    ],
)

ios_test_runner(
    name = "CoreListTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "CoreListAttachmentFlightTests",
    minimum_os_version = "15.0",
    runner = ":CoreListTestRunner",
    deps = [
        ":CoreListAttachmentFlightTestsLib",
    ],
)

# Identity scans run on every applyChanges (every chat history transaction): duplicate check and diff.
swift_library(
    name = "CoreListIdentityScanTestsLib",
    testonly = True,
    srcs = glob(
        ["CoreListDemoTests/TestSupport/*.swift"],
        exclude = [
            "CoreListDemoTests/TestSupport/ManualAutoLoadResponseScheduler.swift",
        ],
    ) + [
        "CoreListDemoTests/IdentityScanTests.swift",
        "CoreListDemoTests/ItemDiffTests.swift",
    ],
    deps = [
        ":CoreListDemoForTests",
    ],
)

ios_unit_test(
    name = "CoreListIdentityScanTests",
    minimum_os_version = "15.0",
    runner = ":CoreListTestRunner",
    deps = [
        ":CoreListIdentityScanTestsLib",
    ],
)

# Scroll-path membership and serial lookups (render() / rebalanceActiveWindow()), pinned against the
# quadratic and whole-collection algorithms they replaced.
swift_library(
    name = "CoreListScrollPathTestsLib",
    testonly = True,
    srcs = glob(
        ["CoreListDemoTests/TestSupport/*.swift"],
        exclude = [
            "CoreListDemoTests/TestSupport/ManualAutoLoadResponseScheduler.swift",
        ],
    ) + [
        "CoreListDemoTests/ListMembershipTests.swift",
        "CoreListDemoTests/AttachmentSerialLookupTests.swift",
        "CoreListDemoTests/RowRetirementTests.swift",
    ],
    deps = [
        ":CoreListDemoForTests",
    ],
)

ios_unit_test(
    name = "CoreListScrollPathTests",
    minimum_os_version = "15.0",
    runner = ":CoreListTestRunner",
    deps = [
        ":CoreListScrollPathTestsLib",
    ],
)

# Per-frame chat scroll reads: the presented-frame pass, the O(1) view -> index lookup, and the memoized attachment
# flight tracks (perf/chat-scroll-tick).
swift_library(
    name = "CoreListChatScrollTickTestsLib",
    testonly = True,
    srcs = glob(
        ["CoreListDemoTests/TestSupport/*.swift"],
        exclude = [
            "CoreListDemoTests/TestSupport/ManualAutoLoadResponseScheduler.swift",
        ],
    ) + [
        "CoreListDemoTests/ChatScrollTickGeometryTests.swift",
        "CoreListDemoTests/AttachmentFlightMemoTests.swift",
    ],
    deps = [
        ":CoreListDemoForTests",
    ],
)

ios_unit_test(
    name = "CoreListChatScrollTickTests",
    minimum_os_version = "15.0",
    runner = ":CoreListTestRunner",
    deps = [
        ":CoreListChatScrollTickTestsLib",
    ],
)
