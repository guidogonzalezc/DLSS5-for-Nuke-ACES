#include "protocol_layout.h"
#include "Protocol.h"

HeaderLayout workerLayout() {
    HeaderLayout l;
    l.size                 = sizeof(VideoHeader);
    l.off_magic            = offsetof(VideoHeader, magic);
    l.off_input_width      = offsetof(VideoHeader, input_width);
    l.off_perf_quality     = offsetof(VideoHeader, perf_quality);
    l.off_intensity        = offsetof(VideoHeader, intensity);
    l.off_mv_mode          = offsetof(VideoHeader, mv_mode);
    l.off_color_flags      = offsetof(VideoHeader, color_flags);
    l.off_reserved_thresh  = offsetof(VideoHeader, _reserved_thresh);
    l.display_referred_bit = COLOR_DISPLAY_REFERRED;
    return l;
}
