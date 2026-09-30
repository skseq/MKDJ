// mk_dsp_lock.h — one lock for ALL engine-owned DSP state.
//
// AUDIT RULE — no exceptions:
//   Every shim entry point that touches engine-owned DSP state (stretch
//   instances shared between the engine queue and producer threads) takes
//   StretchLock for its entire call. This includes reset/seek/config calls
//   that only LOOK read-only — a reset racing a producer's process() is the
//   crash both the Signalsmith and SoundTouch backends hit: concurrent
//   clear()+putSamples() corrupts the heap, and the poisoned buffer blows up
//   later in caulk's allocator.
//
// When adding a new DSP backend: every entry point gets StretchLock. If an
// entry point must not block the render path, take a copy of state under the
// lock instead — never skip the lock.
#ifndef mk_dsp_lock_h
#define mk_dsp_lock_h

#include <pthread.h>

static pthread_mutex_t mk_dsp_mutex = PTHREAD_MUTEX_INITIALIZER;

struct StretchLock {
    StretchLock() { pthread_mutex_lock(&mk_dsp_mutex); }
    ~StretchLock() { pthread_mutex_unlock(&mk_dsp_mutex); }
};

#endif
