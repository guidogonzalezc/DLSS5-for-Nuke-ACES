// Guards the wire format between the Nuke plug-in and the worker process.
//
// VideoHeader is declared twice -- once in src/WorkerBridge.h and once in
// worker/Protocol.h -- and the two are kept in sync by hand. If they ever drift,
// nothing fails loudly: the worker simply reads the wrong bytes and the picture
// quietly goes wrong. This test compiles both declarations in separate
// translation units and compares their layouts.
//
// It also pins the total size to 96 bytes. That is what upstream shipped, and it
// is why color_flags was carved out of the unused scene-cut reserve rather than
// appended: a plug-in built from this fork still speaks to a worker built from
// upstream (which ignores the field), and an upstream plug-in still speaks to a
// worker built from this fork (which sees zero and keeps the old behaviour).

#include "protocol_layout.h"

#include <cstdio>
#include <cstring>

static int g_failures = 0;

static void check(bool ok, const char* what, const char* detail = "") {
    if (ok) {
        std::printf("  [ ok ] %s\n", what);
    } else {
        ++g_failures;
        std::printf("  [FAIL] %s%s%s\n", what, detail[0] ? " -- " : "", detail);
    }
}

static void checkSize(const char* what, size_t got, size_t want) {
    char detail[128];
    std::snprintf(detail, sizeof(detail), "got %zu, want %zu", got, want);
    check(got == want, what, detail);
}

int main() {
    std::printf("VideoHeader wire-format check\n");
    std::printf("=============================\n\n");

    const HeaderLayout p = pluginLayout();
    const HeaderLayout w = workerLayout();

    std::printf("[1] The two declarations agree\n");
    checkSize("sizeof(VideoHeader) matches", p.size, w.size);
    check(p.off_magic           == w.off_magic,           "magic offset matches");
    check(p.off_input_width     == w.off_input_width,     "input_width offset matches");
    check(p.off_perf_quality    == w.off_perf_quality,    "perf_quality offset matches");
    check(p.off_intensity       == w.off_intensity,       "intensity offset matches");
    check(p.off_mv_mode         == w.off_mv_mode,         "mv_mode offset matches");
    check(p.off_color_flags     == w.off_color_flags,     "color_flags offset matches");
    check(p.off_reserved_thresh == w.off_reserved_thresh, "_reserved_thresh offset matches");
    check(p.display_referred_bit == w.display_referred_bit, "COLOR_DISPLAY_REFERRED matches");

    std::printf("\n[2] Still binary compatible with upstream\n");
    checkSize("VideoHeader is 96 bytes, as upstream shipped it", p.size, 96u);
    checkSize("color_flags sits on the old scene-cut reserve (offset 88)", p.off_color_flags, 88u);
    checkSize("_reserved_thresh is still the last field (offset 92)", p.off_reserved_thresh, 92u);
    check(p.display_referred_bit == 1u, "COLOR_DISPLAY_REFERRED is bit 0");

    std::printf("\n-----------------------------\n");
    std::printf("%s\n", g_failures == 0 ? "wire format OK" : "wire format BROKEN");
    return g_failures == 0 ? 0 : 1;
}
