// arm64 stub: SoundTouch's cpu detection is x86-only (cpu_detect_x86.cpp
// defines detectCPUextensions at GLOBAL scope — FIRFilter/TDStretch link
// against that); on Apple silicon we report no SIMD extensions.
#include "STTypes.h"
extern "C++" uint detectCPUextensions(void);
uint detectCPUextensions(void) { return 0u; }
