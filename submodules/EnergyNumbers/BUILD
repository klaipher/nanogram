load("//build-system/bazel-utils:swift_strict.bzl", "strict_swift_library", "strict_swift_test")

# CPU and energy numbers from the kernel's counters. The one source file is shared with the watch app
# (Telegram/WatchApp/Shared), which xcodebuild compiles into the watch target.
strict_swift_library(
    name = "EnergyNumbers",
    module_name = "EnergyNumbers",
    srcs = ["//Telegram/WatchApp:Shared/EnergyNumbers.swift"],
    visibility = ["//visibility:public"],
)

# Host (macOS) test; it needs nothing but Foundation.
# Run with `./build-input/bazel-9.3.2-darwin-arm64 test //submodules/EnergyNumbers:EnergyNumbersTests`.
strict_swift_test(
    name = "EnergyNumbersTests",
    srcs = glob(["Tests/**/*.swift"]),
    deps = [":EnergyNumbers"],
)
