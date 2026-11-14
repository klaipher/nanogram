load("//build-system/bazel-utils:swift_strict.bzl", "strict_swift_library", "strict_swift_test")

# Pure model, privacy policy and app-group store shared by the app, the widget extension and the App Intents.
strict_swift_library(
    name = "NanogramGlance",
    module_name = "NanogramGlance",
    srcs = glob(["Sources/**/*.swift"]),
    deps = [],
    visibility = ["//visibility:public"],
)

# Runs on the Mac: ./build-input/bazel-<version>-darwin-arm64 test //submodules/NanogramGlance:NanogramGlanceTests
strict_swift_test(
    name = "NanogramGlanceTests",
    srcs = glob(["Tests/**/*.swift"]),
    deps = [":NanogramGlance"],
)
