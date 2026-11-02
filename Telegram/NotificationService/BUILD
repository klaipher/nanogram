load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "NotificationServiceExtensionLib",
    module_name = "NotificationServiceExtensionLib",
    srcs = glob([
        "Sources/*.swift",
    ]),
    deps = [
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/BuildConfig:BuildConfig",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/EncryptionProvider:EncryptionProvider",
        "//submodules/AppLockState:AppLockState",
        "//submodules/NotificationsPresentationData:NotificationsPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/OpenSSLEncryptionProvider:OpenSSLEncryptionProvider",
        "//submodules/WebPBinding:WebPBinding",
        "//submodules/LottieBinding:LottieBinding",
        "//submodules/LottieSettings:LottieSettings",
        "//submodules/GZip:GZip",
        "//submodules/PersistentStringHash:PersistentStringHash",
        "//submodules/Utils/RangeSet",
        "//submodules/Media/ConvertOpusToAAC",
        "//submodules/PasscodeCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "NotificationServiceTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":NotificationServiceExtensionLib",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/NotificationsPresentationData:NotificationsPresentationData",
    ],
)

ios_test_runner(
    name = "NotificationServiceTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "NotificationServiceTests",
    minimum_os_version = "15.0",
    runner = ":NotificationServiceTestRunner",
    deps = [
        ":NotificationServiceTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
