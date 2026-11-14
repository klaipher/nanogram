load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")

filegroup(
    name = "yasm_sources",
    srcs = glob([
        "yasm-1.3.0/**/*"
    ]),
)

genrule(
    name = "yasm",
    srcs = [
        ":yasm_sources",
    ],
    cmd_bash =
"""
set -x
    core_count=$$(nproc 2>/dev/null || PATH="$$PATH:/usr/sbin" sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
    BUILD_DIR="$(RULEDIR)/build"
    rm -rf "$$BUILD_DIR"
    mkdir -p "$$BUILD_DIR"

    CMAKE_BIN="$$(pwd)/$(execpath @cmake//:cmake)"
    NINJA_BIN_DIR="$$(pwd)/$$(dirname $(execpath @ninja//:ninja))"
    export PATH="$$(dirname "$$CMAKE_BIN"):$$NINJA_BIN_DIR:$$PATH"

    SOURCE_PATH="third-party/yasm/yasm-1.3.0"
    cp -R "$$SOURCE_PATH" "$$BUILD_DIR/"

    pushd "$$BUILD_DIR/yasm-1.3.0"
    mkdir build
    cd build
    "$$CMAKE_BIN" -G Ninja .. -DYASM_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DPYTHON_EXECUTABLE="$$(which python3)"
    "$$CMAKE_BIN" --build . --parallel $$core_count
    popd

    tar -cf "$(location yasm.tar)" -C "$$BUILD_DIR/yasm-1.3.0/build" .
    rm -rf "$$BUILD_DIR"
""",
    outs = [
        "yasm.tar",
    ],
    tools = [
        "@cmake//:all",
        "@cmake//:cmake",
        "@ninja//:ninja",
    ],
    visibility = [
        "//visibility:public",
    ]
)
