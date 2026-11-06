load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "ItemListUI",
    module_name = "ItemListUI",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/MergeLists:MergeLists",
        "//submodules/TextFormat:TextFormat",
        "//submodules/Markdown:Markdown",
        "//submodules/ProgressNavigationButtonNode:ProgressNavigationButtonNode",
        "//submodules/SwitchNode:SwitchNode",
        "//submodules/AnimatedStickerNode:AnimatedStickerNode",
        "//submodules/TelegramAnimatedStickerNode:TelegramAnimatedStickerNode",
        "//submodules/CheckNode:CheckNode",
        "//submodules/SegmentedControlNode:SegmentedControlNode",
        "//submodules/AccountContext:AccountContext",
        "//submodules/AnimationUI:AnimationUI",
        "//submodules/ShimmerEffect:ShimmerEffect",
        "//submodules/ManagedAnimationNode:ManagedAnimationNode",
        "//submodules/AvatarNode",
        "//submodules/TelegramCore",
        "//submodules/ComponentFlow",
        "//submodules/TelegramUI/Components/TabSelectorComponent",
        "//submodules/Components/ComponentDisplayAdapters",
        "//submodules/TelegramUI/Components/TextNodeWithEntities",
        "//submodules/TelegramUI/Components/ListItemComponentAdaptor",
        "//submodules/TelegramUI/Components/GlassBackgroundComponent",
        "//submodules/TelegramUI/Components/GlassControls",
        "//submodules/TelegramUI/Components/HorizontalTabsComponent",
        "//submodules/TelegramUI/Components/SideColumnLayout",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ItemListUITestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":ItemListUI",
        "//submodules/Display:Display",
        "//submodules/SwitchNode:SwitchNode",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15.
ios_test_runner(
    name = "ItemListUITestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "ItemListUITests",
    minimum_os_version = "15.0",
    runner = ":ItemListUITestRunner",
    deps = [
        ":ItemListUITestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
