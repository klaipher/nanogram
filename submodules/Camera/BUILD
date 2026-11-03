load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")
load(
    "@build_bazel_rules_apple//apple:resources.bzl",
    "apple_resource_bundle",
    "apple_resource_group",
)
load("//build-system/bazel-utils:plist_fragment.bzl",
    "plist_fragment",
)

filegroup(
    name = "CameraMetalResources",
    srcs = glob([
        "MetalResources/**/*.*",
    ]),
    visibility = ["//visibility:public"],
)

plist_fragment(
    name = "CameraBundleInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>org.telegram.Camera</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>Camera</string>
    """
)

apple_resource_bundle(
    name = "CameraBundle",
    infoplists = [
        ":CameraBundleInfoPlist",
    ],
    resources = [
        ":CameraMetalResources",
    ],
    visibility = ["//visibility:public"],
)

swift_library(
    name = "Camera",
    module_name = "Camera",
    srcs = glob([
        "Sources/**/*.swift",
    ], exclude = [
        "Sources/CameraMultitaskingPolicy.swift",
        "Sources/CameraTabletPolicy.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Utils/DeviceModel",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "CameraTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ], exclude = [
        "Tests/CameraMultitaskingPolicyTests.swift",
        "Tests/CameraTabletPolicyTests.swift",
    ]),
    deps = [
        ":Camera",
    ],
)

ios_test_runner(
    name = "CameraTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "CameraTests",
    minimum_os_version = "15.0",
    runner = ":CameraTestRunner",
    deps = [
        ":CameraTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# iPad: the in-app cameras keep running in Split View and Stage Manager (A-4). Its own module, shared by CameraNeo and
# CameraLegacy, so that its test builds without the rest of Camera.
swift_library(
    name = "CameraMultitaskingPolicy",
    module_name = "CameraMultitaskingPolicy",
    srcs = [
        "Sources/CameraMultitaskingPolicy.swift",
        "Sources/CameraTabletPolicy.swift",
    ],
    copts = [
        "-warnings-as-errors",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "CameraMultitaskingPolicyTestsLib",
    testonly = True,
    srcs = [
        "Tests/CameraMultitaskingPolicyTests.swift",
        "Tests/CameraTabletPolicyTests.swift",
    ],
    deps = [
        ":CameraMultitaskingPolicy",
    ],
)

ios_unit_test(
    name = "CameraMultitaskingPolicyTests",
    minimum_os_version = "15.0",
    runner = ":CameraTestRunner",
    deps = [
        ":CameraMultitaskingPolicyTestsLib",
    ],
)
