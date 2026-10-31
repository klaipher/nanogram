
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
    srcs = glob([
        "Sources/*.c",
        "Sources/*.h",
        "Sources/x86/*.h",
    ]),
    hdrs = glob([
        "PublicHeaders/**/*.h",
    ]),
    includes = [
      "PublicHeaders",
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
