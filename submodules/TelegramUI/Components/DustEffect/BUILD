load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

load(
    "@build_bazel_rules_apple//apple:resources.bzl",
    "apple_resource_bundle",
    "apple_resource_group",
)
load("//build-system/bazel-utils:plist_fragment.bzl",
    "plist_fragment",
)

filegroup(
    name = "DustEffectMetalSources",
    srcs = glob([
        "Metal/**/*.metal",
    ]),
    visibility = ["//visibility:public"],
)

plist_fragment(
    name = "DustEffectMetalSourcesBundleInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>org.telegram.DustEffectMetalSources</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>DustEffect</string>
    """
)

apple_resource_bundle(
    name = "DustEffectMetalSourcesBundle",
    infoplists = [
        ":DustEffectMetalSourcesBundleInfoPlist",
    ],
    resources = [
        ":DustEffectMetalSources",
    ],
)

swift_library(
    name = "DustEffect",
    module_name = "DustEffect",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    data = [
        ":DustEffectMetalSourcesBundle",
    ],
    deps = [
        "//submodules/Display",
        "//submodules/MetalEngine",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Host (macOS) test, run with `bazel test` on the Mac's GPU: the effect's timing and an offscreen render of it with the
# real shaders, compiled from source at run time. Only the UIKit-free sources are compiled.
swift_test(
    name = "DustEffectTests",
    srcs = [
        "Sources/DustEffectPolicy.swift",
        "Sources/DustEffectSimulation.swift",
        "Sources/DustFluidSimulation.swift",
        "Tests/DustEffectPolicyTests.swift",
        "Tests/DustEffectRenderTests.swift",
    ],
    copts = [
        "-warnings-as-errors",
    ],
    data = [
        ":DustEffectMetalSources",
    ],
    env = {
        "DUST_EFFECT_METAL_SOURCES": "$(rootpaths :DustEffectMetalSources)",
    },
)
