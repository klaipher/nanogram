load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "MediaEditorBottomControls",
    module_name = "MediaEditorBottomControls",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Display",
        "//submodules/ComponentFlow",
        "//submodules/TelegramUI/Components/GlassBackgroundComponent",
        "//submodules/TelegramUI/Components/PlainButtonComponent",
        "//submodules/Components/BundleIconComponent",
        "//submodules/ContextUI",
        "//submodules/TelegramUI/Components/ContextReferenceButtonComponent",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "MediaEditorBottomControlsTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":MediaEditorBottomControls",
        "//submodules/Display",
        "//submodules/ComponentFlow",
        "//submodules/TelegramUI/Components/ContextReferenceButtonComponent",
    ],
)

ios_test_runner(
    name = "MediaEditorBottomControlsTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "MediaEditorBottomControlsTests",
    minimum_os_version = "15.0",
    runner = ":MediaEditorBottomControlsTestRunner",
    deps = [
        ":MediaEditorBottomControlsTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
