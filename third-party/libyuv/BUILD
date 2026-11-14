load("@rules_cc//cc:cc_library.bzl", "cc_library")

# libyuv from https://chromium.googlesource.com/libyuv/libyuv/
# Version 1977, main at 0b8dd2318002db2cc089930d6e2a3ad131eabdb8 (2026-10-29).
# The sources are the klaipher/libyuv submodule in third_party/libyuv (nanogram = that commit minus the upstream
# BUILD.bazel, WORKSPACE.bazel and libyuv.bzl, which would make the submodule its own Bazel package and repository).
# Source lists and per-target flags follow upstream BUILD.gn / libyuv.gni.

config_setting(
    name = "debug_build",
    values = {
        "compilation_mode": "dbg",
    },
)

optimization_flags = select({
    ":debug_build": ["-O2", "-DNDEBUG"],
    "//conditions:default": ["-DNDEBUG"],
})

common_flags = []

arm64_specific_flags = [
    "-DLIBYUV_NEON",
]

x86_64_specific_flags = [
    "-DHAVE_SSE2",
]

arch_specific_cflags = select({
    "@build_bazel_rules_apple//apple:ios_arm64": common_flags + arm64_specific_flags,
    "//build-system:ios_sim_arm64": common_flags + arm64_specific_flags,
    "@build_bazel_rules_apple//apple:ios_x86_64": common_flags + x86_64_specific_flags,
    "//build-system:linux_arm64": common_flags + arm64_specific_flags,
    "//build-system:linux_x86_64": common_flags + x86_64_specific_flags,
    "//conditions:default": common_flags + arm64_specific_flags,
})

# The AArch64 Neon kernels contain dot-product and i8mm instructions; upstream
# builds them with these flags and only calls them after runtime CPU detection.
neon_cflags = select({
    "@build_bazel_rules_apple//apple:ios_x86_64": [],
    "//build-system:linux_x86_64": [],
    "//conditions:default": ["-march=armv8-a+dotprod+i8mm"],
})

# SVE and SME kernels are not built: Apple CPUs have no SVE, libyuv never
# detects it on Apple platforms, and upstream only enables SME on Linux/Android.
# These defines must also be seen by every file that includes the libyuv
# headers, so they are exported through `defines`.
libyuv_defines = [
    "LIBYUV_DISABLE_SVE",
    "LIBYUV_DISABLE_SME",
]

libyuv_copts = [
    "-ffp-contract=fast",
] + arch_specific_cflags + optimization_flags

libyuv_headers = ["third_party/libyuv/" + path for path in [
    "include/libyuv.h",
    "include/libyuv/basic_types.h",
    "include/libyuv/compare.h",
    "include/libyuv/compare_row.h",
    "include/libyuv/convert.h",
    "include/libyuv/convert_argb.h",
    "include/libyuv/convert_from.h",
    "include/libyuv/convert_from_argb.h",
    "include/libyuv/cpu_id.h",
    "include/libyuv/cpu_support.h",
    "include/libyuv/loongson_intrinsics.h",
    "include/libyuv/mjpeg_decoder.h",
    "include/libyuv/planar_functions.h",
    "include/libyuv/rotate.h",
    "include/libyuv/rotate_argb.h",
    "include/libyuv/rotate_row.h",
    "include/libyuv/row.h",
    "include/libyuv/row_sve.h",
    "include/libyuv/scale.h",
    "include/libyuv/scale_argb.h",
    "include/libyuv/scale_rgb.h",
    "include/libyuv/scale_row.h",
    "include/libyuv/scale_uv.h",
    "include/libyuv/version.h",
    "include/libyuv/video_common.h",
]]

cc_library(
    name = "libyuv_neon",
    hdrs = libyuv_headers,
    srcs = ["third_party/libyuv/" + path for path in [
        "source/compare_neon.cc",
        "source/compare_neon64.cc",
        "source/rotate_neon.cc",
        "source/rotate_neon64.cc",
        "source/row_neon.cc",
        "source/row_neon64.cc",
        "source/scale_neon.cc",
        "source/scale_neon64.cc",
    ]],
    includes = [
        "third_party/libyuv/include",
    ],
    defines = libyuv_defines,
    copts = libyuv_copts + neon_cflags,
)

cc_library(
    name = "libyuv",
    hdrs = libyuv_headers,
    srcs = ["third_party/libyuv/" + path for path in [
        "source/compare.cc",
        "source/compare_common.cc",
        "source/compare_gcc.cc",
        "source/compare_hvx.cc",
        "source/compare_wasm.cc",
        "source/compare_win.cc",
        "source/convert.cc",
        "source/convert_argb.cc",
        "source/convert_from.cc",
        "source/convert_from_argb.cc",
        "source/convert_jpeg.cc",
        "source/convert_to_argb.cc",
        "source/convert_to_i420.cc",
        "source/cpu_id.cc",
        "source/mjpeg_decoder.cc",
        "source/mjpeg_validate.cc",
        "source/planar_functions.cc",
        "source/rotate.cc",
        "source/rotate_any.cc",
        "source/rotate_argb.cc",
        "source/rotate_common.cc",
        "source/rotate_gcc.cc",
        "source/rotate_hvx.cc",
        "source/rotate_wasm.cc",
        "source/rotate_win.cc",
        "source/row_any.cc",
        "source/row_common.cc",
        "source/row_gcc.cc",
        "source/row_hvx.cc",
        "source/row_wasm.cc",
        "source/row_win.cc",
        "source/scale.cc",
        "source/scale_any.cc",
        "source/scale_argb.cc",
        "source/scale_common.cc",
        "source/scale_gcc.cc",
        "source/scale_hvx.cc",
        "source/scale_rgb.cc",
        "source/scale_uv.cc",
        "source/scale_wasm.cc",
        "source/scale_win.cc",
        "source/video_common.cc",
    ]],
    includes = [
        "third_party/libyuv/include",
    ],
    defines = libyuv_defines,
    copts = libyuv_copts,
    deps = [
        ":libyuv_neon",
    ],
    visibility = ["//visibility:public"],
)
