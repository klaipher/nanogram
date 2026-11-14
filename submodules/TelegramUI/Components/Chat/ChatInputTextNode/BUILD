load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "ChatInputTextNode",
    module_name = "ChatInputTextNode",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/AppBundle",
        "//submodules/TelegramCore",
        "//submodules/TelegramUI/Components/Chat/ChatInputTextNode/ChatInputTextViewImpl",
        "//submodules/TelegramUI/Components/Chat/MessageInlineBlockBackgroundView",
        "//submodules/AccountContext",
        "//submodules/TelegramUI/Components/TextNodeWithEntities",
        "//submodules/InvisibleInkDustNode",
        "//submodules/TelegramUI/Components/EmojiTextAttachmentView",
        "//submodules/TelegramUI/Components/RichTextEditor:RichTextEditorCore",
        "//submodules/TelegramUI/Components/RichTextEditor:RichTextEditorUIKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ChatInputTextNodeTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":ChatInputTextNode",
        "//submodules/Display",
        "//submodules/TextFormat",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15.
ios_test_runner(
    name = "ChatInputTextNodeTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "ChatInputTextNodeTests",
    minimum_os_version = "26.0",
    runner = ":ChatInputTextNodeTestRunner",
    deps = [
        ":ChatInputTextNodeTestsLib",
    ],
)
