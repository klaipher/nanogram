load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

# App Intents, entities and the App Shortcuts provider. Linked into the app (Shortcuts, Siri, Spotlight) and into the
# widget extension (configuration intent, Control Center button, Live Activity buttons). alwayslink: nothing in the app's
# sources references these types, and the linker would drop them (the intents must exist in the app process). Not strict: the AppIntents
# macros and static metadata do not compile cleanly under the Swift 6 strict settings.
swift_library(
    name = "NanogramAppIntents",
    module_name = "NanogramAppIntents",
    srcs = glob(["Sources/**/*.swift"]),
    deps = [
        "//submodules/NanogramGlance:NanogramGlance",
    ],
    alwayslink = True,
    visibility = ["//visibility:public"],
)

# Runs on the Mac: ./build-input/bazel-<version>-darwin-arm64 test //submodules/NanogramAppIntents:NanogramAppIntentsTests
swift_test(
    name = "NanogramAppIntentsTests",
    srcs = glob(["Tests/**/*.swift"]),
    deps = [
        ":NanogramAppIntents",
        "//submodules/NanogramGlance:NanogramGlance",
    ],
)
