// Pins the line prefix of the CpuProfiler call tree (Debug "Frame hitches" stacks and the CPU profile).
//
// The main-thread tree is up to 128 frames deep. Indenting every level by two spaces put up to 256 spaces in front of
// a frame, and on 2026-11-11 the indentation was about two thirds of every ~55 KB frame-hitch stack. The indent now
// stops at callTreeIndentLevels; a deeper line keeps that indent and prints its depth instead.
//
// Pure C++ host test, following the CHECK_TRUE + main() pattern of the tgcalls and libprisma cc_tests.

#include "CallTreeLine.h"

#include <cstdio>
#include <string>

static int g_failures = 0;

#define CHECK_TRUE(cond, msg)                                              \
    do {                                                                   \
        if (!(cond)) {                                                     \
            std::fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__,    \
                         __LINE__);                                        \
            ++g_failures;                                                  \
        } else {                                                           \
            std::fprintf(stderr, "ok: %s\n", (msg));                       \
        }                                                                  \
    } while (0)

int main() {
    using cpu_profiler::callTreeIndentLevels;
    using cpu_profiler::callTreeLinePrefix;

    const std::string countColumn = "     12  ";

    // Shallow levels, the ones read by eye, keep the old two spaces per level.
    CHECK_TRUE(callTreeLinePrefix(12, 0) == countColumn, "depth 0 has no indent");
    CHECK_TRUE(callTreeLinePrefix(12, 1) == countColumn + "  ", "depth 1 is indented by two spaces");
    CHECK_TRUE(callTreeLinePrefix(12, 5) == countColumn + std::string(10, ' '), "depth 5 is indented by ten spaces");
    CHECK_TRUE(callTreeLinePrefix(12, callTreeIndentLevels) == countColumn + std::string(callTreeIndentLevels * 2, ' '),
               "the last indented level has no depth number");

    // Past the cap the indent stays and the depth is printed, so deep frames stay unambiguous.
    const std::string capIndent(callTreeIndentLevels * 2, ' ');
    CHECK_TRUE(callTreeLinePrefix(12, callTreeIndentLevels + 1) == countColumn + capIndent + " 13| ",
               "the first level past the cap prints its depth");
    CHECK_TRUE(callTreeLinePrefix(1, 127) == "      1  " + capIndent + "127| ", "depth 127 prints its depth");

    // The count column is unchanged.
    CHECK_TRUE(callTreeLinePrefix(12345, 0) == "  12345  ", "a five-digit count fills the column");

    // No line of a 128-frame tree is wider in front of its frame than the cap plus the depth number.
    {
        bool bounded = true;
        for (int depth = 0; depth <= 128; depth++) {
            if (callTreeLinePrefix(1, depth).size() > countColumn.size() + capIndent.size() + 5) {
                bounded = false;
            }
        }
        CHECK_TRUE(bounded, "the prefix is bounded at every depth of a 128-frame tree");
    }

    // A negative depth is never passed, but must not underflow the indent.
    CHECK_TRUE(callTreeLinePrefix(3, -1) == "      3  ", "a negative depth has no indent");

    if (g_failures == 0) {
        std::fprintf(stderr, "ALL PASS\n");
        return 0;
    }
    std::fprintf(stderr, "%d FAILURE(S)\n", g_failures);
    return 1;
}
