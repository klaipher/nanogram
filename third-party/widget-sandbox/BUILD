load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_cc//cc:cc_test.bzl", "cc_test")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_bundle", "apple_resource_group")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")
load("//build-system/bazel-utils:plist_fragment.bzl", "plist_fragment")

# The framework is the submodule `widget-sandbox/` (klaipher/widget-sandbox `nanogram`, VENDOR.md); this package keeps the
# iOS glue around it, the host tests and the bundles. The paths below are its layout.
WS = "widget-sandbox"
CORPUS = WS + "/corpus"
CONFORMANCE = WS + "/packages/conformance"
STRESS = WS + "/packages/stress"
FIXTURES = WS + "/packages/core/tests/fixtures"
SANDBOX = WS + "/packages/desktop/sandbox"
PKG = "third-party/widget-sandbox"

# The corpus by folder (names repeat across folders: generated/with-profile and without-profile share 21), at
# widget-sandbox/corpus/<folder>/… in a test bundle. Test data: never in the app.
apple_resource_group(
    name = "WidgetCorpus",
    testonly = True,
    structured_resources = glob([CORPUS + "/**"]),
    visibility = ["//submodules/TelegramUI/Components/MessageWidget:__subpackages__"],
)

# Profile 1's definition (VENDOR.md), for the host test that checks the generated tables against it.
filegroup(
    name = "ProfileJSON",
    testonly = True,
    srcs = [WS + "/packages/core/profile.json"],
    visibility = ["//submodules/TelegramUI/Components/MessageWidget:__subpackages__"],
)

# The Intl parity fixture (VENDOR.md), for WidgetRuntime's host and iOS Intl tests.
filegroup(
    name = "IntlCases",
    testonly = True,
    srcs = [FIXTURES + "/intl-cases.json"],
    visibility = ["//submodules/TelegramUI/Components/MessageWidget:__subpackages__"],
)

# Upstream's IntlBridge is the last section of SandboxEngine.swift ("Intl delegation", after an `import Foundation`): cut
# out at build time, so the submodule stays the only copy of it.
genrule(
    name = "IntlBridgeSource",
    srcs = [WS + "/packages/ios/Sources/WidgetSandbox/SandboxEngine.swift"],
    outs = ["IntlBridge.swift"],
    cmd = "{ printf 'import Foundation\\n\\n'; awk '/^\\/\\/ MARK: - Intl delegation/,0' $(SRCS); } > $@",
)

# widget-sandbox's iOS glue for the `intl` capability (VENDOR.md): upstream's IntlBridge and CLDR plural rules,
# Foundation only, behind our entry point. WidgetRuntime's Intl asks it for every answer that needs locale data.
swift_library(
    name = "WidgetSandboxIntl",
    module_name = "WidgetSandboxIntl",
    srcs = [
        ":IntlBridgeSource",
        WS + "/packages/ios/Sources/WidgetSandbox/PluralRules.swift",
        "ios/WidgetSandboxIntl.swift",
    ],
    visibility = ["//submodules/TelegramUI/Components/MessageWidget:__subpackages__"],
)

# The glue alone against the Intl fixture, on the host's Foundation:
# `./build-input/bazel-9.2.0-darwin-arm64 test //third-party/widget-sandbox:WidgetSandboxIntlTests`.
swift_test(
    name = "WidgetSandboxIntlTests",
    srcs = ["ios/Tests/WidgetSandboxIntlTests.swift"],
    data = [":IntlCases"],
    env = {"WR_INTL_CASES": "$(rootpath :IntlCases)"},
    deps = [":WidgetSandboxIntl"],
)

# The shared gesture policy (VENDOR.md): upstream's C++ copy, who gets a press over a widget. WidgetRuntime's TapState
# runs its arbiter on the primary pointer.
cc_library(
    name = "GesturePolicy",
    srcs = [SANDBOX + "/src/gesture_policy.cpp"],
    hdrs = [SANDBOX + "/include/twidget/gesture_policy.h"],
    strip_include_prefix = SANDBOX + "/include",
    copts = ["-std=c++20"],
    visibility = ["//submodules/TelegramUI/Components/MessageWidget:__subpackages__"],
)

# The policy against the fixture its four copies share:
# `./build-input/bazel-9.2.0-darwin-arm64 test //third-party/widget-sandbox:GesturePolicyTests`.
cc_test(
    name = "GesturePolicyTests",
    srcs = [
        "gesture/GesturePolicyTests.cpp",
        SANDBOX + "/include/twidget/json.h",
    ],
    copts = ["-std=c++20", "-I" + PKG + "/" + SANDBOX + "/include"],
    data = [FIXTURES + "/gesture-policy.json"],
    env = {"WS_GESTURE_POLICY": "$(rootpath " + FIXTURES + "/gesture-policy.json)"},
    deps = [":GesturePolicy"],
)

# The shared SDK policy (VENDOR.md): upstream's C++ copy of what a bridge call may carry. WidgetRuntime's
# `setResizeAnchor` checks its edge with it.
cc_library(
    name = "SdkPolicy",
    srcs = [SANDBOX + "/src/sdk_policy.cpp"],
    hdrs = [
        SANDBOX + "/include/twidget/json.h",
        SANDBOX + "/include/twidget/sdk_policy.h",
        SANDBOX + "/include/twidget/version.h",
    ],
    strip_include_prefix = SANDBOX + "/include",
    copts = ["-std=c++20"],
    visibility = ["//submodules/TelegramUI/Components/MessageWidget:__subpackages__"],
)

# The SDK policy against the fixture its four copies share:
# `./build-input/bazel-9.2.0-darwin-arm64 test //third-party/widget-sandbox:SdkPolicyTests`.
cc_test(
    name = "SdkPolicyTests",
    srcs = ["gesture/SdkPolicyTests.cpp"],
    copts = ["-std=c++20"],
    data = [FIXTURES + "/sdk-policy.json"],
    env = {"WS_SDK_POLICY": "$(rootpath " + FIXTURES + "/sdk-policy.json)"},
    deps = [":SdkPolicy"],
)

# widget-sandbox's CPU quota policy, its C++ copy (packages/desktop/sandbox): WidgetRuntime's event loop decides each step
# with it (the JS quota and the main-thread window).
cc_library(
    name = "CpuBudget",
    srcs = [SANDBOX + "/src/cpu_budget.cpp"],
    hdrs = [SANDBOX + "/include/twidget/cpu_budget.h"],
    strip_include_prefix = SANDBOX + "/include",
    copts = ["-std=c++20"],
    visibility = ["//submodules/TelegramUI/Components/MessageWidget:__subpackages__"],
)

# The CPU quota policy against the fixture its four copies share:
# `./build-input/bazel-9.2.0-darwin-arm64 test //third-party/widget-sandbox:CpuBudgetTests`.
cc_test(
    name = "CpuBudgetTests",
    srcs = [
        "gesture/CpuBudgetTests.cpp",
        SANDBOX + "/include/twidget/json.h",
    ],
    copts = [
        "-std=c++20",
        "-I" + PKG + "/" + SANDBOX + "/include",
    ],
    data = [FIXTURES + "/cpu-budget.json"],
    env = {"WS_CPU_BUDGET": "$(rootpath " + FIXTURES + "/cpu-budget.json)"},
    deps = [":CpuBudget"],
)

# The corpus' documents as plain files, for host tests (WidgetRuntime's measurements).
filegroup(
    name = "CorpusFiles",
    testonly = True,
    srcs = glob([CORPUS + "/**/*.html"]),
    visibility = ["//submodules/TelegramUI/Components/MessageWidget:__subpackages__"],
)

plist_fragment(
    name = "WidgetCorpusInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>org.telegram.WidgetCorpus</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>WidgetCorpus</string>
    """
)

# The widget harness's corpus (Tests/WidgetHarness): every folder but the attacks, at <folder>/…. Never in the app.
apple_resource_bundle(
    name = "WidgetCorpusBundle",
    bundle_name = "WidgetCorpus",
    infoplists = [":WidgetCorpusInfoPlist"],
    structured_resources = glob([CORPUS + "/**"], exclude = [CORPUS + "/attacks/**"]),
    strip_structured_resources_prefixes = [CORPUS],
    visibility = ["//visibility:public"],
)

# The conformance set (CLIENTS.md) at widget-sandbox/packages/conformance/… in a test bundle: the widgets, refs,
# channel.json, manifest.json, catalogue.json and the report tool (not the web harness or its results). Test data: never
# in the app.
apple_resource_group(
    name = "WidgetConformance",
    testonly = True,
    structured_resources = glob([
        CONFORMANCE + "/auto/**",
        CONFORMANCE + "/visual/**",
        CONFORMANCE + "/refs/**",
        CONFORMANCE + "/channel.json",
        CONFORMANCE + "/manifest.json",
        CONFORMANCE + "/catalogue.json",
        CONFORMANCE + "/run.schema.json",
        CONFORMANCE + "/CLIENTS.md",
        CONFORMANCE + "/README.md",
        CONFORMANCE + "/tools/*.mjs",
    ]),
    visibility = ["//submodules/TelegramUI/Components/MessageWidget:__subpackages__"],
)

plist_fragment(
    name = "WidgetConformanceInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>org.telegram.WidgetConformance</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>WidgetConformance</string>
    """
)

# DEBUG app builds only (Debug Settings' conformance insertion into Saved Messages): the widgets, the reference
# pictures posted beside them, and channel.json, at <path>/… without the conformance/ prefix.
apple_resource_bundle(
    name = "WidgetConformanceBundle",
    bundle_name = "WidgetConformance",
    infoplists = [":WidgetConformanceInfoPlist"],
    structured_resources = glob([
        CONFORMANCE + "/auto/**",
        CONFORMANCE + "/visual/**",
        CONFORMANCE + "/refs/visual/**",
        CONFORMANCE + "/channel.json",
        # The conformance runner's test list (Tests/WidgetHarness).
        CONFORMANCE + "/manifest.json",
    ]),
    strip_structured_resources_prefixes = [CONFORMANCE],
    visibility = ["//visibility:public"],
)

plist_fragment(
    name = "WidgetStressInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>org.telegram.WidgetStress</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>WidgetStress</string>
    """
)

# The renderer stress kit (stress/CLIENTS.md, widget-sandbox v0.3.0): manifest.json and widgets/, at the bundle's root,
# for MessageWidgetStress's runner in the widget harness and DEBUG app builds' Debug Settings. Never in a release app.
apple_resource_bundle(
    name = "WidgetStressBundle",
    bundle_name = "WidgetStress",
    infoplists = [":WidgetStressInfoPlist"],
    structured_resources = glob([
        STRESS + "/widgets/**",
        STRESS + "/manifest.json",
    ]),
    strip_structured_resources_prefixes = [STRESS],
    visibility = ["//visibility:public"],
)

config_setting(
    name = "debug_build",
    values = {"compilation_mode": "dbg"},
    visibility = ["//visibility:public"],
)
