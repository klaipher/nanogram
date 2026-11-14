# Copyright (c) 2016, Google Inc.
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
# SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION
# OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
# CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE. */

load("@rules_cc//cc:cc_binary.bzl", "cc_binary")
load("@rules_cc//cc:cc_library.bzl", "cc_library")

load(
    ":BUILD.generated.bzl",
    "bcm_internal_headers",
    "bcm_sources",
    "bcm_sources_asm",
    "bssl_internal_headers",
    "bssl_sources",
    "crypto_headers",
    "crypto_internal_headers",
    "crypto_sources",
    "crypto_sources_asm",
    "ssl_headers",
    "ssl_internal_headers",
    "ssl_sources",
)

licenses(["notice"])

exports_files(
    ["LICENSE"] + crypto_headers + ssl_headers,
)

# The flags and the asm select below follow upstream's src/util/util.bzl.
# Upstream's own BUILD.bazel is deleted in the klaipher/boringssl fork (it would
# make src/ a Bazel package of its own): it splits each library into public and
# *_internal targets, while consumers here (e.g. //Telegram:TelegramUIFramework
# linkopts, //third-party/td) need :crypto itself to produce the single static
# archive.
#
# By default, the C files will expect assembly files, if any, to be linked in
# with the build. This default can be flipped with -DOPENSSL_NO_ASM. If building
# in a configuration where we have no assembly optimizations, -DOPENSSL_NO_ASM
# has no effect, and either value is fine.
#
# Like C files, assembly files are wrapped in #ifdef (or NASM equivalent), so it
# is safe to include a file for the wrong platform in the build. It will just
# output an empty object file. However, we need some platform selectors to
# distinguish between gas or NASM syntax.
#
# These two selects for asm_sources and asm_copts must be kept in sync.
#
# TODO(https://crbug.com/boringssl/531): Enable assembly for Windows.
asm_sources = select({
    "@platforms//os:windows": [],
    "//conditions:default": bcm_sources_asm + crypto_sources_asm,
})
asm_copts = select({
    "@platforms//os:windows": ["-DOPENSSL_NO_ASM"],
    "//conditions:default": [],
})

# Configure C, C++, and common flags for GCC-compatible toolchains.
gcc_copts = [
    # This list of warnings should match those in the top-level CMakeLists.txt.
    "-Wall",
    "-Werror",
    "-Wformat=2",
    "-Wmissing-field-initializers",
    "-Wshadow",
    "-Wsign-compare",
    "-Wtype-limits",
    "-Wvla",
    "-Wwrite-strings",
    "-fno-common",
    "-fno-strict-aliasing",
]
gcc_conlyopts = [
    "-std=c11",
    "-Wmissing-prototypes",
    "-Wold-style-definition",
    "-Wstrict-prototypes",
]
gcc_cxxopts = [
    # BoringSSL requires C++17 (CMAKE_CXX_STANDARD in src/CMakeLists.txt).
    "-std=c++17",
    "-Wmissing-declarations",
    "-Wnon-virtual-dtor",
]

boringssl_copts = [
    "-DBORINGSSL_IMPLEMENTATION",
] + select({
    # We assume that non-Windows builds use a GCC-compatible toolchain and that
    # Windows builds do not.
    "@platforms//os:windows": [],
    "//conditions:default": gcc_copts,
}) + select({
    # This is needed on glibc systems to get rwlock in pthreads, but it should
    # not be set on Apple platforms or FreeBSD, where it instead disables APIs
    # we use.
    # See compat(5), sys/cdefs.h, and https://crbug.com/boringssl/471
    "@platforms//os:linux": ["-D_XOPEN_SOURCE=700"],
    # Without WIN32_LEAN_AND_MEAN, <windows.h> pulls in wincrypt.h, which
    # conflicts with our <openssl/x509.h>.
    "@platforms//os:windows": ["-DWIN32_LEAN_AND_MEAN", "-utf-8"],
    "//conditions:default": [],
}) + asm_copts

boringssl_conlyopts = select({
    "@platforms//os:windows": ["/std:c11"],
    "//conditions:default": gcc_conlyopts,
})

boringssl_cxxopts = select({
    "@platforms//os:windows": ["/std:c++17"],
    "//conditions:default": gcc_cxxopts,
})

# Some build tools don't support multiple targets declaring the same headers directory

genrule(
    name = "copy_ssl_headers",
    srcs = ssl_headers,
    cmd_bash = 
    """
    set -ex
    """ + "\n".join([
        "cp $(location {}) $(location :ssl_headers/{})".format(x, x)
        for x in ssl_headers
    ]),
    outs = [
        ":ssl_headers/{}".format(x) for x in ssl_headers
    ],
    visibility = [
        "//visibility:public",
    ]
)

cc_library(
    name = "ssl_headers",
    srcs = [],
    hdrs = [
        ":ssl_headers/{}".format(x) for x in ssl_headers
    ],
    includes = [
        "ssl_headers/src/include",
    ],
)

cc_library(
    name = "crypto",
    srcs = bcm_sources + crypto_sources + bcm_internal_headers + crypto_internal_headers + asm_sources,
    hdrs = crypto_headers,
    copts = boringssl_copts,
    conlyopts = boringssl_conlyopts,
    cxxopts = boringssl_cxxopts,
    includes = ["src/include"],
    linkopts = select({
        "@platforms//os:windows": [
            "-defaultlib:advapi32.lib",
            "-defaultlib:ws2_32.lib",
        ],
        "//conditions:default": ["-pthread"],
    }),
    visibility = ["//visibility:public"],
    linkstatic = 1,
)

cc_library(
    name = "ssl",
    # libssl also includes libcrypto's internal headers.
    srcs = ssl_sources + ssl_internal_headers + bcm_internal_headers + crypto_internal_headers,
    # hdrs, not srcs: //third-party/webrtc includes these too, and only hdrs propagate.
    hdrs = ssl_headers,
    copts = boringssl_copts,
    conlyopts = boringssl_conlyopts,
    cxxopts = boringssl_cxxopts,
    visibility = ["//visibility:public"],
    deps = [
        ":crypto",
        ":ssl_headers",
    ],
)

cc_binary(
    name = "bssl",
    srcs = bssl_sources + bssl_internal_headers,
    copts = boringssl_copts,
    conlyopts = boringssl_conlyopts,
    cxxopts = boringssl_cxxopts,
    visibility = ["//visibility:public"],
    deps = [":ssl"],
)
