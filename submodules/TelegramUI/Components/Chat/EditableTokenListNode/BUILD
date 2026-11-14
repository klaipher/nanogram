load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "EditableTokenListNode",
    module_name = "EditableTokenListNode",
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
        "//submodules/TelegramPresentationData",
        "//submodules/AvatarNode",
        "//submodules/AccountContext",
        "//submodules/TelegramUI/Components/GlassBackgroundComponent",
        "//submodules/ComponentFlow",
        "//submodules/Components/ComponentDisplayAdapters",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "EditableTokenListNodeTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":EditableTokenListNode",
        "//submodules/AvatarNode",
        "//submodules/TelegramCore",
        "//submodules/Postbox",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15.
ios_test_runner(
    name = "EditableTokenListNodeTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "EditableTokenListNodeTests",
    minimum_os_version = "26.0",
    runner = ":EditableTokenListNodeTestRunner",
    deps = [
        ":EditableTokenListNodeTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
