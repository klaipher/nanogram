
genrule(
    name = "flatc",
    srcs = [
        "@flatbuffers_zip//file",
    ],
    cmd_bash =
"""
set -x
    core_count=`PATH="$$PATH:/usr/sbin" sysctl -n hw.logicalcpu`
    BUILD_DIR="$(RULEDIR)/build"
    rm -rf "$$BUILD_DIR"
    mkdir -p "$$BUILD_DIR"

    CMAKE_BIN_DIR="$$(pwd)/$$(dirname $(execpath @cmake//:cmake))"

    tar -xzf "$(location @flatbuffers_zip//file)" --directory "$$BUILD_DIR"
    pushd "$$BUILD_DIR/flatbuffers-25.12.19"
    mkdir build
    cd build
    PATH="$$CMAKE_BIN_DIR:$$PATH" cmake .. -DCMAKE_BUILD_TYPE=Release -DFLATBUFFERS_BUILD_TESTS=0 -DFLATBUFFERS_INSTALL=0 -DFLATBUFFERS_BUILD_FLATLIB=0 -DFLATBUFFERS_STATIC_FLATC=0
    make -j $$core_count
    popd

    cp "$$BUILD_DIR/flatbuffers-25.12.19/build/flatc" "$(location flatc_bin)"
""",
    outs = [
        "flatc_bin",
    ],
    tools = [
        "@cmake//:all",
        "@cmake//:cmake",
    ],
    visibility = [
        "//visibility:public",
    ]
)
