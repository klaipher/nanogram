load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "ChatControllerInteraction",
    module_name = "ChatControllerInteraction",
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
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/ChatPresentationInterfaceState:ChatPresentationInterfaceState",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/TextSelectionNode:TextSelectionNode",
        "//submodules/ContextUI:ContextUI",
        "//submodules/ChatInterfaceState:ChatInterfaceState",
        "//submodules/UndoUI:UndoUI",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TextFormat:TextFormat",
        "//submodules/WallpaperBackgroundNode:WallpaperBackgroundNode",
        "//submodules/TelegramUI/Components/AnimationCache:AnimationCache",
        "//submodules/TelegramUI/Components/MultiAnimationRenderer:MultiAnimationRenderer",
        "//submodules/TelegramUI/Components/Chat/ChatRowPrep:ChatRowPrep",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Host (macOS) test of the unread range arithmetic, which runs on server read marks. Compiles only that file.
swift_test(
    name = "UnreadMessageRangeTests",
    srcs = [
        "Sources/UnreadMessageRange.swift",
        "Tests/UnreadMessageRangeTests.swift",
    ],
    copts = [
        "-warnings-as-errors",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ChatControllerInteractionTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ], exclude = [
        "Tests/UnreadMessageRangeTests.swift",
    ]),
    deps = [
        ":ChatControllerInteraction",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15.
ios_test_runner(
    name = "ChatControllerInteractionTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "ChatControllerInteractionTests",
    minimum_os_version = "15.0",
    runner = ":ChatControllerInteractionTestRunner",
    deps = [
        ":ChatControllerInteractionTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
