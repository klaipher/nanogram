"""Host tests for the header-only policy code under tgcalls/tgcalls."""

load("@rules_cc//cc:cc_test.bzl", "cc_test")

def policy_cc_test(name, src, headers):
    """A cc_test over `src` and the pure headers it includes (paths under tgcalls/tgcalls).

    tgcalls_core stays out so these build in seconds; the headers must not need WebRTC, FFmpeg
    or any platform code."""
    cc_test(
        name = name,
        srcs = [src] + ["tgcalls/tgcalls/" + header for header in headers],
        copts = [
            "-Isubmodules/TgVoipWebrtc/tgcalls/tgcalls",
            "-std=c++17",
            "-Wall",
            "-Werror",
        ],
    )
