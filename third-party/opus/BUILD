
load("@rules_cc//cc:cc_library.bzl", "cc_library")

headers = [
    "opus.h",
    "opus_defines.h",
    "opus_multistream.h",
    "opus_projection.h",
    "opus_types.h",
]

libs = [
    "opus",
]

# libopus v1.6.1 (tag commit 22244de5a79bd1d6d623c32e72bf1954b56235be) from the xiph/opus submodule in opus/,
# the same commit Android pins.
filegroup(
    name = "opus_sources",
    srcs = glob(
        ["opus/**/*"],
        # dotfiles (opus/.git holds a per-worktree gitdir path) would change the action digest per worktree
        exclude = [
            "opus/**/.*",
        ],
    ),
)

genrule(
    name = "opus_build",
    srcs = [
        "build-opus-bazel.sh",
        "opus-cmake-args.sh",
        ":opus_sources",
        "@cmake_tar_gz//file",
        "@ninja-mac_zip//file",
    ],
    cmd_bash =
    """
    set -ex

    if [ "$(TARGET_CPU)" == "ios_armv7" ]; then
        BUILD_ARCH="armv7"
    elif [ "$(TARGET_CPU)" == "ios_arm64" ]; then
        BUILD_ARCH="arm64"
    elif [ "$(TARGET_CPU)" == "ios_sim_arm64" ]; then
        BUILD_ARCH="sim_arm64"
    elif [ "$(TARGET_CPU)" == "ios_x86_64" ]; then
        BUILD_ARCH="x86_64"
    elif [ "$(TARGET_CPU)" == "k8" ] || [ "$(TARGET_CPU)" == "x86_64" ]; then
        BUILD_ARCH="linux_x86_64"
    elif [ "$(TARGET_CPU)" == "aarch64" ] || [ "$(TARGET_CPU)" == "arm64" ]; then
        BUILD_ARCH="linux_arm64"
    elif [ "$(TARGET_CPU)" == "darwin_arm64" ]; then
        BUILD_ARCH="macos_arm64"
    else
        echo "Unsupported architecture $(TARGET_CPU)"
    fi

    BUILD_DIR="$(RULEDIR)/build_$${BUILD_ARCH}"
    rm -rf "$$BUILD_DIR"
    mkdir -p "$$BUILD_DIR"

    if [ "$${BUILD_ARCH}" = "linux_x86_64" ] || [ "$${BUILD_ARCH}" = "linux_arm64" ]; then
        EXTRA_PATH=""
    else
        CMAKE_DIR="$$(pwd)/$$BUILD_DIR/cmake"
        mkdir -p "$$CMAKE_DIR"
        tar -xzf "$(location @cmake_tar_gz//file)" -C "$$CMAKE_DIR"

        NINJA_DIR="$$(pwd)/$$BUILD_DIR/ninja"
        mkdir -p "$$NINJA_DIR"
        unzip "$(location @ninja-mac_zip//file)" -d "$$NINJA_DIR"
        EXTRA_PATH="$$CMAKE_DIR/cmake-4.1.2-macos-universal/CMake.app/Contents/bin:$$NINJA_DIR"
    fi

    cp $(location :build-opus-bazel.sh) "$$BUILD_DIR/"
    cp $(location :opus-cmake-args.sh) "$$BUILD_DIR/"

    SOURCE_PATH="third-party/opus/opus"

    cp -R "$$SOURCE_PATH" "$$BUILD_DIR/"

    mkdir -p "$$BUILD_DIR/Public/opus"

    if [ -n "$$EXTRA_PATH" ]; then
        PATH="$$EXTRA_PATH:$$PATH" sh $$BUILD_DIR/build-opus-bazel.sh $$BUILD_ARCH "$$BUILD_DIR/opus" "$$BUILD_DIR"
    else
        sh $$BUILD_DIR/build-opus-bazel.sh $$BUILD_ARCH "$$BUILD_DIR/opus" "$$BUILD_DIR"
    fi
    """ +
    "\n".join([
        "cp -f \"$$BUILD_DIR/opus/include/{}\" \"$(location Public/opus/{})\"".format(header, header) for header in headers
    ]) +
    "\n" +
    "\n".join([
        "cp -f \"$$BUILD_DIR/build/lib{}.a\" \"$(location Public/opus/lib/lib{}.a)\"".format(lib, lib) for lib in libs
    ]),
    outs = ["Public/opus/" + x for x in headers] +
    ["Public/opus/lib/lib{}.a".format(x) for x in libs],
    visibility = [
        "//visibility:public",
    ]
)

cc_library(
    name = "opus_lib",
    srcs = [":Public/opus/lib/lib" + x + ".a" for x in libs],
)

cc_library(
    name = "opus_cc",
    hdrs = [":Public/opus/" + x for x in headers],
    includes = [
        "Public",
    ],
    deps = [
        ":opus_lib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

cc_library(
    name = "opus",
    hdrs = [":Public/opus/" + x for x in headers],
    includes = [
        "Public",
    ],
    deps = [
        ":opus_lib",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# The same headers with Public/opus on the include path, for sources that include <opus_multistream.h> without the
# opus/ prefix (xiph/opusfile).
cc_library(
    name = "opus_flat_headers",
    hdrs = [":Public/opus/" + x for x in headers],
    includes = [
        "Public/opus",
    ],
    deps = [
        ":opus_lib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
