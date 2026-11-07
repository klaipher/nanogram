load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application", "ios_unit_test")
load("//build-system/bazel-utils:plist_fragment.bzl", "plist_fragment")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "WebProxyTransport",
    module_name = "WebProxyTransport",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "WebProxyTransportTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":WebProxyTransport",
    ],
)

# The carrier tests make real WKWebViews. In a hostless test process (`simctl spawn -s` on a shut-down device, with no
# lsd) WebKit's BrowserEngineKit lookups block on LaunchServices on the iOS 27.2 simulator: every test passes, then the
# Swift concurrency pool is starved and the process never exits (the run times out). A bare app host gives the tests a
# booted simulator and a UIApplication.
swift_library(
    name = "WebProxyTransportTestHostLib",
    testonly = True,
    srcs = glob([
        "TestHost/*.swift",
    ]),
    # main.m finds the app classes by name only; keep the linker from dropping them.
    alwayslink = True,
)

plist_fragment(
    name = "WebProxyTransportTestHostInfoPlist",
    extension = "plist",
    template = """
    <key>CFBundleIdentifier</key>
    <string>org.telegram.WebProxyTransportTestHost</string>
    <key>CFBundleName</key>
    <string>WebProxyTransportTestHost</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>UILaunchScreen</key>
    <dict/>
    <key>UIApplicationSceneManifest</key>
    <dict>
        <key>UIApplicationSupportsMultipleScenes</key>
        <false/>
        <key>UISceneConfigurations</key>
        <dict>
            <key>UIWindowSceneSessionRoleApplication</key>
            <array>
                <dict>
                    <key>UISceneConfigurationName</key>
                    <string>Default</string>
                    <key>UISceneDelegateClassName</key>
                    <string>SceneDelegate</string>
                </dict>
            </array>
        </dict>
    </dict>
    """
)

ios_application(
    name = "WebProxyTransportTestHost",
    testonly = True,
    bundle_id = "org.telegram.WebProxyTransportTestHost",
    families = ["iphone"],
    minimum_os_version = "15.0",
    infoplists = [":WebProxyTransportTestHostInfoPlist"],
    deps = [
        "//Tests/Common:Main",
        ":WebProxyTransportTestHostLib",
    ],
)

# 27.0, not 26.5: the carrier's geolocation and file-panel refusals are gated on
# `@available(iOS 27.0)` / `@available(iOS 18.4)`, and WebProxyCarrierDelegateTests can
# only check a binding the runtime actually exposes. On 26.5 the geolocation assertion
# silently does not run - verified by misspelling the selector and watching the suite
# still pass. Everything else here is OS-agnostic.
ios_test_runner(
    name = "WebProxyTransportTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "WebProxyTransportTests",
    minimum_os_version = "15.0",
    runner = ":WebProxyTransportTestRunner",
    test_host = ":WebProxyTransportTestHost",
    deps = [
        ":WebProxyTransportTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
