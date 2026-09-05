#pragma once
#include <cstddef>
#include <cstdint>

// A description of one VideoHeader layout, filled in by each side's own header.
struct HeaderLayout {
    size_t size;
    size_t off_magic;
    size_t off_input_width;
    size_t off_perf_quality;
    size_t off_intensity;
    size_t off_mv_mode;
    size_t off_color_flags;
    size_t off_reserved_thresh;
    uint32_t display_referred_bit;
};

HeaderLayout pluginLayout();
HeaderLayout workerLayout();
