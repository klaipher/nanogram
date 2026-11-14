load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "CreateBotScreen",
    module_name = "CreateBotScreen",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Display",
        "//submodules/TelegramPresentationData",
        "//submodules/ComponentFlow",
        "//submodules/Components/ViewControllerComponent",
        "//submodules/Components/ComponentDisplayAdapters",
        "//submodules/AccountContext",
        "//submodules/Components/MultilineTextComponent",
        "//submodules/Components/BalancedTextComponent",
        "//submodules/TelegramUI/Components/ButtonComponent",
        "//submodules/Components/BundleIconComponent",
        "//submodules/TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/PresentationDataUtils",
        "//submodules/Components/ResizableSheetComponent",
        "//submodules/TelegramUI/Components/GlassBarButtonComponent",
        "//submodules/TelegramUI/Components/PlainButtonComponent",
        "//submodules/TelegramUI/Components/ListSectionComponent",
        "//submodules/TelegramUI/Components/AvatarComponent",
        "//submodules/TelegramUI/Components/ListMultilineTextFieldItemComponent",
        "//submodules/Markdown",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "CreateBotScreenTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":CreateBotScreen",
        "//submodules/TelegramCore",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15.
ios_test_runner(
    name = "CreateBotScreenTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "CreateBotScreenTests",
    minimum_os_version = "26.0",
    runner = ":CreateBotScreenTestRunner",
    deps = [
        ":CreateBotScreenTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
