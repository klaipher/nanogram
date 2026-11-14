
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_cc//cc:objc_library.bzl", "objc_library")

headers = [
    "decode.h",
    "encode.h",
    "types.h",
]

libs = [
    "webp",
    "sharpyuv",
]

# libwebp v1.6.0 (tag commit 4fa21912338357f89e4fd51cf2368325b59e9bd9)
filegroup(
    name = "libwebp_sources",
    srcs = glob([
        "libwebp/**/*"
    ]),
)

genrule(
    name = "webp_build",
    srcs = [
        "build-webp-bazel.sh",
        ":libwebp_sources",
    ],
    cmd_bash = 
    """
    set -ex

    if [ "$(TARGET_CPU)" == "ios_arm64" ]; then
        BUILD_ARCH="arm64"
    elif [ "$(TARGET_CPU)" == "ios_sim_arm64" ]; then
        BUILD_ARCH="sim_arm64"
    elif [ "$(TARGET_CPU)" == "ios_x86_64" ]; then
        BUILD_ARCH="x86_64"
    elif [ "$(TARGET_CPU)" == "darwin_arm64" ]; then
        BUILD_ARCH="macos_arm64"
    else
        echo "Unsupported architecture $(TARGET_CPU)"
        exit 1
    fi

    BUILD_DIR="$(RULEDIR)/build_$${BUILD_ARCH}"
    rm -rf "$$BUILD_DIR"
    mkdir -p "$$BUILD_DIR"

    CMAKE_BIN_DIR="$$(pwd)/$$(dirname $(execpath @cmake//:cmake))"
    NINJA_BIN_DIR="$$(pwd)/$$(dirname $(execpath @ninja//:ninja))"

    cp $(location :build-webp-bazel.sh) "$$BUILD_DIR/"

    SOURCE_PATH="third-party/webp/libwebp"

    cp -R "$$SOURCE_PATH" "$$BUILD_DIR/"

    mkdir -p "$$BUILD_DIR/Public/libwebp"

    PATH="$$CMAKE_BIN_DIR:$$NINJA_BIN_DIR:$$PATH" sh $$BUILD_DIR/build-webp-bazel.sh $$BUILD_ARCH "$$BUILD_DIR/libwebp" "$$BUILD_DIR"
    """ +
    "\n".join([
        "cp -f \"$$BUILD_DIR/libwebp/src/webp/{}\" \"$(location Public/webp/{})\"".format(header, header) for header in headers
    ]) +
    "\n" +
    "\n".join([
        "cp -f \"$$BUILD_DIR/build/lib{}.a\" \"$(location Public/webp/lib/lib{}.a)\"".format(lib, lib) for lib in libs
    ]) +
    "\n" + "rm -rf \"$$BUILD_DIR\"",
    outs = ["Public/webp/" + x for x in headers] +
    ["Public/webp/lib/lib{}.a".format(x) for x in libs],
    tools = [
        "@cmake//:all",
        "@cmake//:cmake",
        "@ninja//:ninja",
    ],
    visibility = [
        "//visibility:public",
    ]
)

cc_library(
    name = "webp_lib",
    srcs = [":Public/webp/lib/lib" + x + ".a" for x in libs],
)

objc_library(
    name = "webp",
    module_name = "webp",
    enable_modules = True,
    hdrs = [":Public/webp/" + x for x in headers],
    includes = [
        "Public",
    ],
    deps = [
        ":webp_lib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
