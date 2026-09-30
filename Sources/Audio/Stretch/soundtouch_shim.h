// soundtouch_shim.h — extern-C wrapper around SoundTouch 2.4.1 (LGPL,
// vendored) for MKDJ. Third time-stretch engine. SoundTouch is a
// put/receive streaming API with tempo/pitch set independently — the adapter
// owns one instance per deck on the worker queue, like the Signalsmith path.
#ifndef soundtouch_shim_h
#define soundtouch_shim_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mk_stouch_s *mk_stouch_t;

mk_stouch_t mk_stouch_create(int channels, int sampleRate);
void mk_stouch_destroy(mk_stouch_t s);
void mk_stouch_reset(mk_stouch_t s);

/// tempo = playback speed multiplier (1.0 = unchanged); pitch in semitones,
/// independent of tempo (SoundTouch's own keylock separation).
void mk_stouch_set_tempo(mk_stouch_t s, double tempo);
void mk_stouch_set_pitch_semitones(mk_stouch_t s, double semitones);

/// Feed deinterleaved channel pointers (like AVAudioPCMBuffer).
void mk_stouch_put(mk_stouch_t s, const float *const *in, int32_t frames);

/// Pull up to maxFrames of deinterleaved output; returns frames produced
/// (0 when nothing ready — the caller retries).
int32_t mk_stouch_receive(mk_stouch_t s, float *const *out, int32_t maxFrames);

/// Move the internal remainder to the output queue (call once at EOF, then
/// receive until empty).
void mk_stouch_flush_drain(mk_stouch_t s);

/// Receive (kept for completeness/possible future callers).
int32_t mk_stouch_flush(mk_stouch_t s, float *const *out, int32_t maxFrames);

/// Nominal initial latency in INPUT frames (for position-lead calibration).
int32_t mk_stouch_latency(mk_stouch_t s);

#ifdef __cplusplus
}
#endif

#endif
