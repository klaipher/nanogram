load("//build-system/bazel-utils:swift_strict.bzl", "strict_swift_library", "strict_swift_test")

# The watch's part of "Send Report": asks the paired watch for its report over WatchConnectivity and keeps the last
# copy the watch transferred in the background. The payload type is shared with the watch app
# (Telegram/WatchApp/Shared).
strict_swift_library(
    name = "WatchReport",
    module_name = "WatchReport",
    srcs = glob(["Sources/**/*.swift"]) + ["//Telegram/WatchApp:Shared/WatchReportPayload.swift"],
    visibility = ["//visibility:public"],
)

# Host (macOS) test of the payload and of choosing between the live reply and the stored copy.
strict_swift_test(
    name = "WatchReportTests",
    srcs = glob(["Tests/**/*.swift"]),
    deps = [":WatchReport"],
)
