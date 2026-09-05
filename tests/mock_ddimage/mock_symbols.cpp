// Definitions for the handful of symbols the mock headers only declare.
#include "DDImage/Iop.h"

namespace DD { namespace Image {
static Knob g_showPanel;
Knob& Knob::showPanel = g_showPanel;
}}
