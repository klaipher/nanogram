load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_cc//cc:objc_library.bzl", "objc_library")

# libjpeg-turbo, built from the official release archive pinned in MODULE.bazel (`libjpeg_turbo_tar_gz`). Only
# //submodules/MozjpegBinding uses it; see that module and CLAUDE.md ("JPEG library").

VERSION = "3.2.1"

headers = [
    "turbojpeg.h",
    "jpeglib.h",
    "jmorecfg.h",
]

libs = [
    "jpeg",
    "turbojpeg",
]

genrule(
    name = "libjpeg_turbo_build",
    srcs = [
        "build-libjpeg-turbo-bazel.sh",
        "@libjpeg_turbo_tar_gz//file",
        "@cmake_tar_gz//file",
    ],
    cmd_bash =
    """
    set -ex

    if [ "$(TARGET_CPU)" == "ios_arm64" ]; then
        BUILD_ARCH="arm64"
    elif [ "$(TARGET_CPU)" == "ios_sim_arm64" ]; then
        BUILD_ARCH="sim_arm64"
    elif [ "$(TARGET_CPU)" == "darwin_arm64" ]; then
        BUILD_ARCH="macos_arm64"
    else
        echo "Unsupported architecture $(TARGET_CPU)"
        exit 1
    fi

    BUILD_DIR="$(RULEDIR)/build_$${BUILD_ARCH}"
    rm -rf "$$BUILD_DIR"
    mkdir -p "$$BUILD_DIR"

    CMAKE_DIR="$$(pwd)/$$BUILD_DIR/cmake"
    mkdir -p "$$CMAKE_DIR"
    tar -xzf "$(location @cmake_tar_gz//file)" -C "$$CMAKE_DIR"

    tar -xzf "$(location @libjpeg_turbo_tar_gz//file)" -C "$$BUILD_DIR"
    SOURCE_DIR="$$(pwd)/$$BUILD_DIR/libjpeg-turbo-""" + VERSION + """"

    cp $(location :build-libjpeg-turbo-bazel.sh) "$$BUILD_DIR/"

    PATH="$$PATH:$$CMAKE_DIR/cmake-4.1.2-macos-universal/CMake.app/Contents/bin" sh $$BUILD_DIR/build-libjpeg-turbo-bazel.sh $$BUILD_ARCH "$$SOURCE_DIR" "$$BUILD_DIR"
    """ +
    "\n".join([
        "cp -f \"$$SOURCE_DIR/src/{}\" \"$(location Public/libjpeg-turbo/{})\"".format(header, header) for header in headers
    ]) +
    "\n" +
    "\n".join([
        "cp -f \"$$BUILD_DIR/build/lib{}.a\" \"$(location Public/libjpeg-turbo/lib/lib{}.a)\"".format(lib, lib) for lib in libs
    ]) +
    "\n" + "cp -f \"$$BUILD_DIR/build/jconfig.h\" \"$(location Public/libjpeg-turbo/jconfig.h)\"" +
    "\n" + "rm -rf \"$$BUILD_DIR\"",
    outs = ["Public/libjpeg-turbo/" + x for x in headers] +
    ["Public/libjpeg-turbo/jconfig.h"] +
    ["Public/libjpeg-turbo/lib/lib{}.a".format(x) for x in libs],
    visibility = [
        "//visibility:public",
    ],
)

cc_library(
    name = "libjpeg_turbo_lib",
    srcs = [":Public/libjpeg-turbo/lib/lib" + x + ".a" for x in libs],
)

objc_library(
    name = "libjpeg_turbo",
    module_name = "libjpeg_turbo",
    enable_modules = True,
    hdrs = [":Public/libjpeg-turbo/" + x for x in headers] + [":Public/libjpeg-turbo/jconfig.h"],
    includes = [
        "Public",
    ],
    deps = [
        ":libjpeg_turbo_lib",
    ],
    visibility = [
        "//submodules/MozjpegBinding:__pkg__",
    ],
)
