load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "ChatMessageItemView",
    module_name = "ChatMessageItemView",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/TelegramCore",
        "//submodules/AccountContext",
        "//submodules/LocalizedPeerData",
        "//submodules/ContextUI",
        "//submodules/ChatListUI",
        "//submodules/TelegramPresentationData",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramUI/Components/ChatControllerInteraction",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemCommon",
        "//submodules/TextFormat",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItem",
        "//submodules/TelegramUI/Components/Chat/ChatMessageTransitionNode",
        "//submodules/TelegramAnimatedStickerNode",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Only the Foundation-only date formatter is compiled into the test module, so the test does not
# link the whole chat item stack.
swift_library(
    name = "ChatMessageItemViewTestsLib",
    module_name = "ChatMessageItemViewTestsLib",
    testonly = True,
    srcs = [
        "Sources/ChatMessageAccessibilityDateFormatter.swift",
    ] + glob([
        "Tests/**/*.swift",
    ]),
)

ios_test_runner(
    name = "ChatMessageItemViewTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "ChatMessageItemViewTests",
    minimum_os_version = "15.0",
    runner = ":ChatMessageItemViewTestRunner",
    deps = [
        ":ChatMessageItemViewTestsLib",
    ],
)
