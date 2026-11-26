#pragma once

#include <algorithm>
#include <cstdio>
#include <string>

namespace cpu_profiler {

/// Call-tree levels indented by two spaces each. The main-thread tree is up to 128 frames deep, and a full indent put
/// up to 256 spaces in front of a frame: about two thirds of every Debug "Frame hitches" stack (2026-11-11, ~55 KB
/// each). Deeper lines keep this indent and print their depth, so the levels read by eye look as before.
constexpr int callTreeIndentLevels = 12;

/// The text in front of a call-tree frame: the sample count, then the indent, then past `callTreeIndentLevels` the
/// depth as `NNN| `.
inline std::string callTreeLinePrefix(int count, int depth) {
    const int levels = std::max(0, std::min(depth, callTreeIndentLevels));
    char buffer[64];
    int length = 0;
    if (depth > callTreeIndentLevels) {
        length = std::snprintf(buffer, sizeof(buffer), "  %5d  %*s%3d| ", count, levels * 2, "", depth);
    } else {
        length = std::snprintf(buffer, sizeof(buffer), "  %5d  %*s", count, levels * 2, "");
    }
    if (length <= 0) {
        return std::string();
    }
    return std::string(buffer, (size_t)std::min(length, (int)sizeof(buffer) - 1));
}

}  // namespace cpu_profiler
