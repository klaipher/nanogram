load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "ChatMediaSend",
    module_name = "ChatMediaSend",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/TelegramUI/Components/MediaEditor",
        "//submodules/TelegramUI/Components/Resources/FetchVideoMediaResource",
        "//submodules/LocalMediaResources",
        "//submodules/TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/AccountContext",
        "//submodules/Display",
        "//submodules/LegacyComponents",
        "//submodules/LegacyMediaPickerUI",
        "//submodules/TextFormat",
        "//submodules/ImageCompression",
        "//submodules/TelegramUI/Components/MediaAssetsContext",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ChatMediaSendTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":ChatMediaSend",
        "//submodules/TelegramUI/Components/MediaEditor",
        "//submodules/TelegramUI/Components/Resources/FetchVideoMediaResource",
        "//submodules/LocalMediaResources",
        "//submodules/LegacyComponents",
        "//submodules/TelegramCore",
        "//submodules/TextFormat",
        "//submodules/Display",
        "//submodules/LegacyMediaPickerUI",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/AccountContext",
    ],
)

ios_test_runner(
    name = "ChatMediaSendTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "ChatMediaSendTests",
    minimum_os_version = "26.0",
    runner = ":ChatMediaSendTestRunner",
    deps = [
        ":ChatMediaSendTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
