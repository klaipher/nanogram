
load("@rules_cc//cc:cc_library.bzl", "cc_library")

# rnnoise 0.2 already prefixes most internals with rnn_; rename the remaining
# generic external names so they cannot collide with other C code in the app.
replace_symbol_list = [
    "compute_rnn",
    "eband20ms",
    "init_rnnoise",
]

cc_library(
    name = "rnnoise",
    # Sources: the klaipher/rnnoise submodule (nanogram: xiph v0.2 + portability headers, denoise.c hardening and the
    # trimmed built-in model). The training and dump tools in src/ have their own main() and are not built.
    srcs = glob([
        "rnnoise/src/*.c",
        "rnnoise/src/*.h",
        "rnnoise/src/x86/*.h",
    ], exclude = [
        "rnnoise/src/dump_features.c",
        "rnnoise/src/dump_rnnoise_tables.c",
        "rnnoise/src/write_weights.c",
    ]),
    hdrs = [
        "rnnoise/include/rnnoise.h",
    ],
    includes = [
        "rnnoise/include",
    ],
    copts = [
        "-D{name}=rnnoise_{name}".format(name = name) for name in replace_symbol_list
    ] + [
        "-O2",
    ],
    visibility = [
        "//visibility:public",
    ],
)
