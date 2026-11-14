load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@rules_cc//cc:cc_test.bzl", "cc_test")

load(
    "@build_bazel_rules_apple//apple:resources.bzl",
    "apple_resource_bundle",
    "apple_resource_group",
)
load("//build-system/bazel-utils:plist_fragment.bzl",
    "plist_fragment",
)

filegroup(
    name = "LibprismaResources",
    srcs = [
        "libprisma/libprisma/grammars.dat",
    ],
    visibility = ["//visibility:public"],
)

plist_fragment(
    name = "LibprismaInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>org.telegram.Libprisma</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>Libprisma</string>
    """
)

apple_resource_bundle(
    name = "LibprismaBundle",
    infoplists = [
        ":LibprismaInfoPlist",
    ],
    resources = [
        ":LibprismaResources",
    ],
)
 
objc_library(
    name = "libprisma",
    enable_modules = True,
    module_name = "libprisma",
    # Everything comes from the klaipher/libprisma submodule (nanogram): the C++ core in libprisma/libprisma and the
    # one Objective-C++ glue for iOS and macOS in libprisma/apple. `libprisma/Syntaxer.h` keeps its import path.
    srcs = glob([
        "libprisma/libprisma/*.cpp",
        "libprisma/libprisma/*.h",
    ]) + [
        "libprisma/apple/Syntaxer.mm",
    ],
    hdrs = [
        "libprisma/apple/Syntaxer.h",
    ],
    include_prefix = "libprisma",
    strip_include_prefix = "libprisma/apple",
    data = [
        ":LibprismaBundle",
    ],
    copts = [
        "-DBOOST_REGEX_MAX_BLOCKS=1536",
        "-Ithird-party/libprisma/libprisma/libprisma",
    ],
    deps = [
        "//third-party/boost_regex",
    ],
    sdk_frameworks = [
        "Foundation",
        "UIKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Host C++ regression test for the code-block highlighter. Compiles only the
# pure-C++ core (not Syntaxer.mm, which needs UIKit) plus the header-only
# boost_regex, and highlights the real shipped grammars.dat. Runs on the host
# via `bazel test`, like the tgcalls cc_tests. See Tests/*.cpp for the case.
cc_test(
    name = "SyntaxHighlighterTests",
    srcs = [
        "Tests/SyntaxHighlighterRecursionTests.cpp",
        "libprisma/libprisma/SyntaxHighlighter.cpp",
        "libprisma/libprisma/SyntaxHighlighter.h",
        "libprisma/libprisma/LanguageTree.cpp",
        "libprisma/libprisma/LanguageTree.h",
        "libprisma/libprisma/TokenList.cpp",
        "libprisma/libprisma/TokenList.h",
        "libprisma/libprisma/Highlight.cpp",
        "libprisma/libprisma/Highlight.h",
        "libprisma/libprisma/UnicodeEscapes.h",
    ],
    copts = [
        "-std=c++17",
        "-O2",
        "-DBOOST_REGEX_MAX_BLOCKS=1536",
        "-Ithird-party/libprisma/libprisma/libprisma",
    ],
    data = [
        "libprisma/libprisma/grammars.dat",
    ],
    args = [
        "$(location libprisma/libprisma/grammars.dat)",
    ],
    deps = [
        "//third-party/boost_regex",
    ],
    visibility = [
        "//visibility:public",
    ],
)
