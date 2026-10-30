"""The strictest Swift settings this toolchain supports, for code written in this fork.

Telegram's own modules compile in the Swift 5 language mode with -warnings-as-errors.
Moving them to Swift 6 means fixing tens of thousands of concurrency diagnostics
(measured 2026-10-30: at least 24,480 across 563 of 732 modules) and conflicting with
every upstream sync, so they stay as they are. New modules, and existing ones that
already compile cleanly, use this preset instead:

    load("//build-system/bazel-utils:swift_strict.bzl", "strict_swift_library")

    strict_swift_library(
        name = "MyFeature",
        module_name = "MyFeature",
        srcs = glob(["Sources/**/*.swift"]),
        deps = [...],
        visibility = ["//visibility:public"],
    )

`tools/dev/tg new-module <path>` scaffolds a module that uses it.

Existing Telegram modules that already compile cleanly in the Swift 6 language mode use
`swift6_library` instead: Swift 6 mode and -warnings-as-errors, without the Swift 7
features below, which would need source edits in Telegram's files (and so conflicts on
every upstream sync). `tools/dev/tg strict-report` shows which modules qualify.
"""

load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

# Upcoming features that are not yet on in the Swift 6 language mode (they are slated
# for Swift 7). `xcrun swift-frontend -print-supported-features` lists them; re-check
# after every Xcode update and add new ones here.
_SWIFT_7_UPCOMING_FEATURES = [
    "ExistentialAny",
    "InternalImportsByDefault",
    "MemberImportVisibility",
    "InferIsolatedConformances",
    "NonisolatedNonsendingByDefault",
    "ImmutableWeakCaptures",
]

SWIFT_6_COPTS = [
    "-swift-version",
    "6",
    "-warnings-as-errors",
]

SWIFT_STRICT_COPTS = SWIFT_6_COPTS + [
    # Unsafe pointers, unowned(unsafe) and the like must be marked with `unsafe`.
    "-strict-memory-safety",
] + [
    flag
    for feature in _SWIFT_7_UPCOMING_FEATURES
    for flag in ("-enable-upcoming-feature", feature)
]

def strict_swift_library(name, copts = [], **kwargs):
    """A swift_library compiled with SWIFT_STRICT_COPTS (extra `copts` come after)."""
    swift_library(name = name, copts = SWIFT_STRICT_COPTS + copts, **kwargs)

def strict_swift_test(name, copts = [], **kwargs):
    """A swift_test compiled with SWIFT_STRICT_COPTS (extra `copts` come after)."""
    swift_test(name = name, copts = SWIFT_STRICT_COPTS + copts, **kwargs)

def swift6_library(name, copts = [], **kwargs):
    """A swift_library compiled in the Swift 6 language mode with -warnings-as-errors."""
    swift_library(name = name, copts = SWIFT_6_COPTS + copts, **kwargs)
