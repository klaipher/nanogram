
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
# the same commit Android pins. Built with the shared options (shared/opus/opus-options.sh): OSCE speech enhancement
# (LACE + NoLACE + bandwidth extension, no deep PLC) compiled in and off until a caller raises the decoder complexity.
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
        # The option list and the model fetch script live in nanogram-deps (the `shared/` submodule), one source for iOS
        # and Mac. The model archive is pinned in MODULE.bazel (opus_models_tar_gz) like libjpeg-turbo's.
        "//shared/opus:opus-options.sh",
        "//shared/opus:fetch-models.sh",
        "@opus_models_tar_gz//file",
        ":opus_sources",
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
        exit 1
    fi

    BUILD_DIR="$(RULEDIR)/build_$${BUILD_ARCH}"
    rm -rf "$$BUILD_DIR"
    mkdir -p "$$BUILD_DIR"

    if [ "$${BUILD_ARCH}" = "linux_x86_64" ] || [ "$${BUILD_ARCH}" = "linux_arm64" ]; then
        EXTRA_PATH=""
    else
        CMAKE_BIN_DIR="$$(pwd)/$$(dirname $(execpath @cmake//:cmake))"
        NINJA_BIN_DIR="$$(pwd)/$$(dirname $(execpath @ninja//:ninja))"
        EXTRA_PATH="$$CMAKE_BIN_DIR:$$NINJA_BIN_DIR"
    fi

    cp $(location :build-opus-bazel.sh) "$$BUILD_DIR/"
    cp $(location //shared/opus:opus-options.sh) "$$BUILD_DIR/"
    cp $(location //shared/opus:fetch-models.sh) "$$BUILD_DIR/"

    SOURCE_PATH="third-party/opus/opus"

    cp -R "$$SOURCE_PATH" "$$BUILD_DIR/"

    # The OSCE speech enhancer (opt-in "Enhance voice messages") compiles the model weights into libopus: verify the pinned
    # archive, check it matches the opus pin (autogen.sh) and extract only the needed files into this build COPY, never
    # into the submodule. The Watch app does not use this target.
    rm -rf "$$BUILD_DIR/opus/.git"
    sh "$$BUILD_DIR/fetch-models.sh" --archive "$(location @opus_models_tar_gz//file)" "$$BUILD_DIR/opus"

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
    ]) +
    "\n" + "rm -rf \"$$BUILD_DIR\"",
    outs = ["Public/opus/" + x for x in headers] +
    ["Public/opus/lib/lib{}.a".format(x) for x in libs],
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
    name = "opus_lib",
    srcs = [":Public/opus/lib/lib" + x + ".a" for x in libs],
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
