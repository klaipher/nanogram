load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# App Intents, entities and the App Shortcuts provider. Linked into the app (Shortcuts, Siri, Spotlight) and into the
# widget extension (configuration intent, Control Center button, Live Activity buttons). Not strict: the AppIntents
# macros and static metadata do not compile cleanly under the Swift 6 strict settings.
swift_library(
    name = "NanogramAppIntents",
    module_name = "NanogramAppIntents",
    srcs = glob(["Sources/**/*.swift"]),
    deps = [
        "//submodules/NanogramGlance:NanogramGlance",
    ],
    visibility = ["//visibility:public"],
)
