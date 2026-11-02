load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")
load("//build-system/bazel-utils:plist_fragment.bzl", "plist_fragment")
load("//build-system/bazel-utils:test_simulator.bzl", "TEST_SIMULATOR_DEVICE", "TEST_SIMULATOR_OS")

swift_library(
    name = "LegacyComponentsTestsLib",
    testonly = True,
    srcs = glob([
        "*.swift",
    ]),
    deps = [
        "//submodules/LegacyComponents:LegacyComponents",
        "//submodules/SSignalKit/SSignalKit:SSignalKit",
    ],
    # LegacyComponents leaves these to the app; a test bundle linking it alone needs them.
    linkopts = [
        "-lz",
        "-framework",
        "Accelerate",
        "-framework",
        "AVKit",
    ],
)

# A hostless test process has no UIApplication, and CADisplayLink creation returns nil there, so the
# POP display-link tests run inside this bare app.
swift_library(
    name = "LegacyComponentsTestHostLib",
    srcs = glob([
        "Host/*.swift",
    ]),
    # main.m finds the app classes by name only; keep the linker from dropping them.
    alwayslink = True,
)

plist_fragment(
    name = "LegacyComponentsTestHostInfoPlist",
    extension = "plist",
    template = """
    <key>CFBundleIdentifier</key>
    <string>org.telegram.LegacyComponentsTestHost</string>
    <key>CFBundleName</key>
    <string>LegacyComponentsTestHost</string>
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
    name = "LegacyComponentsTestHost",
    bundle_id = "org.telegram.LegacyComponentsTestHost",
    families = ["iphone"],
    minimum_os_version = "15.0",
    infoplists = [":LegacyComponentsTestHostInfoPlist"],
    deps = [
        "//Tests/Common:Main",
        ":LegacyComponentsTestHostLib",
    ],
)

# The runner MUST pin a real device/OS: the default runner picks an invalid
# device and the test process exits 15.
ios_test_runner(
    name = "LegacyComponentsTestRunner",
    device_type = TEST_SIMULATOR_DEVICE,
    os_version = TEST_SIMULATOR_OS,
)

ios_unit_test(
    name = "LegacyComponentsTests",
    minimum_os_version = "15.0",
    runner = ":LegacyComponentsTestRunner",
    test_host = ":LegacyComponentsTestHost",
    deps = [
        ":LegacyComponentsTestsLib",
    ],
)
