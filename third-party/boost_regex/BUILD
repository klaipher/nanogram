 
# Headers come from the boostorg/regex submodule (regex/, tag boost-1.92.0, 7760ef2a), the same source Android uses.
load("@rules_cc//cc:objc_library.bzl", "objc_library")

objc_library(
    name = "boost_regex",
    enable_modules = True,
    module_name = "boost_regex",
    srcs = glob([
        "Sources/**/*.c",
        "Sources/**/*.cpp",
        "Sources/**/*.h",
        "Sources/**/*.hpp",
    ], allow_empty=True),
    hdrs = glob([
        "regex/include/**/*.h",
        "regex/include/**/*.hpp",
    ], allow_empty=True),
    includes = [
        "regex/include",
    ],
    copts = [
        "-Ithird-party/boost_regex/regex/include",
    ],
    deps = [
    ],
    visibility = [
        "//visibility:public",
    ],
)
