// Umbrella bridging header for MKDJ's C/C++ interop layer (the single header
// swiftc imports). Carries the SoundTouch adapter alongside Signalsmith
// Stretch and the beep-suppression counter.
#include "soundtouch_shim.h"
#include "beep_guard.h"
#include "ffmpeg_shim.h"
#include "mk_atomic.h"
