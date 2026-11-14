load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "ShareItems",
    module_name = "ShareItems",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SSignalKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/Display:Display",
        "//submodules/LegacyComponents:LegacyComponents",
        "//submodules/LocalMediaResources:LocalMediaResources",
        "//submodules/Pdf:Pdf",
        "//submodules/AccountContext:AccountContext",
    	"//submodules/ShareItems/Impl:ShareItemsImpl",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "ShareItemsTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":ShareItems",
        "//submodules/ShareItems/Impl:ShareItemsImpl",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
)

ios_test_runner(
    name = "ShareItemsTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "ShareItemsTests",
    minimum_os_version = "26.0",
    runner = ":ShareItemsTestRunner",
    deps = [
        ":ShareItemsTestsLib",
    ],
)
