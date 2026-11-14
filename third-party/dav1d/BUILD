
load("@rules_cc//cc:cc_library.bzl", "cc_library")

generated_headers = [
    "vcs_version.h",
]

headers = [
    "compat/msvc/stdatomic.h",
    "compat/gcc/stdatomic.h",
    "compat/getopt.h",
    "common/dump.h",
    "common/frame.h",
    "common/bitdepth.h",
    "common/attributes.h",
    "common/validate.h",
    "common/intops.h",
    "dav1d/picture.h",
    "dav1d/version.h",
    "dav1d/data.h",
    "dav1d/headers.h",
    "dav1d/common.h",
    "dav1d/dav1d.h",
]

libs = [
    "dav1d",
]

filegroup(
    name = "dav1d_sources",
    srcs = glob([
        "dav1d/**/*"
    ]),
)

genrule(
    name = "dav1d_build",
    srcs = [
        "build-dav1d-bazel.sh",
        "arm64-iPhoneSimulator.meson",
        ":dav1d_sources",
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
    elif [ "$(TARGET_CPU)" == "k8" ] || [ "$(TARGET_CPU)" == "x86_64" ]; then
        BUILD_ARCH="linux_x86_64"
    elif [ "$(TARGET_CPU)" == "aarch64" ] || [ "$(TARGET_CPU)" == "arm64" ]; then
        BUILD_ARCH="linux_arm64"
    else
        echo "Unsupported architecture $(TARGET_CPU)"
        exit 1
    fi

    BUILD_DIR="$(RULEDIR)/build_$${BUILD_ARCH}"
    rm -rf "$$BUILD_DIR"
    mkdir -p "$$BUILD_DIR"

    # Pinned meson and ninja are extracted once as external repos (MODULE.bazel). Absolute paths: the build script cd's.
    # The pinned ninja is a macOS binary, so Linux targets keep the host tools.
    if [ "$${BUILD_ARCH}" = "linux_x86_64" ] || [ "$${BUILD_ARCH}" = "linux_arm64" ]; then
        EXTRA_PATH=""
    else
        MESON_DIR="$$(pwd)/$$(dirname $(execpath @meson//:meson.py))"
        NINJA_DIR="$$(pwd)/$$(dirname $(execpath @ninja//:ninja))"
        EXTRA_PATH="$$MESON_DIR:$$NINJA_DIR"
    fi

    cp $(location :build-dav1d-bazel.sh) "$$BUILD_DIR/"
    cp $(location :arm64-iPhoneSimulator.meson) "$$BUILD_DIR/"

    SOURCE_PATH="third-party/dav1d/dav1d"

    cp -R "$$SOURCE_PATH" "$$BUILD_DIR/"

    mkdir -p "$$BUILD_DIR/Public/dav1d"
    mkdir -p "$$BUILD_DIR/Public/compat"
    mkdir -p "$$BUILD_DIR/Public/common"

    if [ -n "$$EXTRA_PATH" ]; then
        PATH="$$EXTRA_PATH:$$PATH" bash $$BUILD_DIR/build-dav1d-bazel.sh $$BUILD_ARCH "$$BUILD_DIR"
    else
        bash $$BUILD_DIR/build-dav1d-bazel.sh $$BUILD_ARCH "$$BUILD_DIR"
    fi
    """ +
    "\n".join([
        "cp -f \"$$BUILD_DIR/dav1d/build/include/{}\" \"$(location Public/{})\"".format(header, header) for header in generated_headers
    ]) +
    "\n" +
    "\n".join([
        "cp -f \"$$BUILD_DIR/dav1d/include/{}\" \"$(location Public/{})\"".format(header, header) for header in headers
    ]) +
    "\n" +
    "\n".join([
        "cp -f \"$$BUILD_DIR/dav1d/build/src/lib{}.a\" \"$(location Public/dav1d/lib/lib{}.a)\"".format(lib, lib) for lib in libs
    ]) +
    "\n" + "rm -rf \"$$BUILD_DIR\"",
    outs = ["Public/" + x for x in generated_headers] +
    ["Public/" + x for x in headers] +
    ["Public/dav1d/lib/lib{}.a".format(x) for x in libs],
    tools = [
        "@meson//:all",
        "@meson//:meson.py",
        "@ninja//:ninja",
    ],
    visibility = [
        "//visibility:public",
    ]
)

cc_library(
    name = "dav1d_lib",
    srcs = [":Public/dav1d/lib/lib" + x + ".a" for x in libs]
)

cc_library(
    name = "dav1d",
    hdrs = [":Public/" + x for x in generated_headers],
    includes = [
        "Public",
    ],
    deps = [
        ":dav1d_lib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

