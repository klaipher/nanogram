
load("@rules_cc//cc:objc_library.bzl", "objc_library")

config_setting(
    name = "debug_build",
    values = {
        "compilation_mode": "dbg",
    },
)

# Pixel and coefficient loops run per frame; at -O0 they are several times slower,
# which also makes debug-build timings of the animation cache meaningless.
# Release builds keep their default flags.
optimization_flags = select({
    ":debug_build": [
        "-O2",
    ],
    "//conditions:default": [],
})

objc_library(
    name = "ImageDCT",
    enable_modules = True,
    module_name = "ImageDCT",
    srcs = glob([
        "Sources/**/*.m",
        "Sources/**/*.mm",
        "Sources/**/*.c",
        "Sources/**/*.cpp",
        "Sources/**/*.h",
    ]),
    hdrs = glob([
        "PublicHeaders/**/*.h",
    ]),
    includes = [
        "PublicHeaders",
    ],
    copts = optimization_flags,
    sdk_frameworks = [
        "Foundation",
        "Accelerate",
    ],
    visibility = [
        "//visibility:public",
    ],
)
