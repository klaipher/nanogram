load("@rules_cc//cc:cc_library.bzl", "cc_library")

# libopusfile v0.12 (a55c164e) from the xiph/opusfile submodule in opusfile/, the same commit Android pins and
# the same source set it builds (http.c needs OP_ENABLE_HTTP and wincerts.c _WIN32, so neither is compiled).
# Upstream includes <opusfile.h>, <ogg/ogg.h> and <opus_multistream.h>; iOS consumers keep <opusfile/opusfile.h>
# through include_prefix.
cc_library(
    name = "opusfile",
    srcs = [
        "opusfile/src/info.c",
        "opusfile/src/internal.c",
        "opusfile/src/internal.h",
        "opusfile/src/opusfile.c",
        "opusfile/src/stream.c",
    ],
    hdrs = [
        "opusfile/include/opusfile.h",
    ],
    include_prefix = "opusfile",
    strip_include_prefix = "opusfile/include",
    includes = [
        "opusfile/include",
    ],
    deps = [
        "//third-party/ogg:ogg",
        "//third-party/opus:opus",
        "//third-party/opus:opus_flat_headers",
    ],
    visibility = [
        "//visibility:public",
    ],
)
