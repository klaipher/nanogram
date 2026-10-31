 
load("@rules_cc//cc:objc_library.bzl", "objc_library")

objc_library(
    name = "ZipArchive",
    enable_modules = True,
    module_name = "ZipArchive",
    srcs = glob([
        "Sources/*.m",
        "Sources/minizip/*.h",
        "Sources/minizip/*.c",
    ]),
    hdrs = glob([
        "PublicHeaders/**/*.h",
    ]),
    includes = [
      "PublicHeaders",
    ],
    # SSZipArchive 2.6.0 (minizip-ng 3.0.10); defines mirror upstream Package.swift.
    copts = [
        "-DHAVE_ARC4RANDOM_BUF",
        "-DHAVE_INTTYPES_H",
        "-DHAVE_PKCRYPT",
        "-DHAVE_STDINT_H",
        "-DHAVE_WZAES",
        "-DHAVE_ZLIB",
        "-DZLIB_COMPAT",
    ],
    sdk_frameworks = [
      "Foundation",
      "Security",
    ],
    sdk_dylibs = [
      "libz",
    ],
    visibility = [
        "//visibility:public",
    ],
)
