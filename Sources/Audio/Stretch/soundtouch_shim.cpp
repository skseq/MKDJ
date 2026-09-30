// soundtouch_shim.cpp — SoundTouch 2.4.1 adapter (LGPL; vendored).
// SoundTouch consumes/produces INTERLEAVED samples; MKDJ pipelines are
// deinterleaved per-channel — the adapter converts both directions.
#include "soundtouch_shim.h"
#include "vendor/soundtouch/SoundTouch.h"
#include "mk_dsp_lock.h"
#include <vector>

using soundtouch::SoundTouch;

namespace {
struct Interleaved {
    std::vector<float> buf;
};
}

struct mk_stouch_s {
    SoundTouch st;
    int channels;
    std::vector<float> inter;   // scratch for interleave/deinterleave
};

mk_stouch_t mk_stouch_create(int channels, int sampleRate) {
    StretchLock _lock;
    auto *s = new mk_stouch_s();
    s->channels = channels;
    s->st.setSampleRate(sampleRate);
    s->st.setChannels(channels);
    return s;
}

void mk_stouch_destroy(mk_stouch_t s) {
    StretchLock _lock; delete s; }

void mk_stouch_reset(mk_stouch_t s) {
    StretchLock _lock;
    s->st.clear();
}

void mk_stouch_set_tempo(mk_stouch_t s, double tempo) {
    StretchLock _lock;
    s->st.setTempo(tempo);
}

void mk_stouch_set_pitch_semitones(mk_stouch_t s, double semitones) {
    StretchLock _lock;
    s->st.setPitchSemiTones(semitones);
}

void mk_stouch_put(mk_stouch_t s, const float *const *in, int32_t frames) {
    StretchLock _lock;
    if (frames <= 0) return;
    s->inter.resize(static_cast<size_t>(frames) * s->channels);
    for (int c = 0; c < s->channels; ++c) {
        float *dst = s->inter.data() + c;
        const float *src = in[c];
        for (int i = 0; i < frames; ++i) {
            dst[static_cast<size_t>(i) * s->channels] = src[i];
        }
    }
    s->st.putSamples(s->inter.data(), static_cast<uint>(frames));
}

int32_t mk_stouch_receive(mk_stouch_t s, float *const *out, int32_t maxFrames) {
    StretchLock _lock;
    if (maxFrames <= 0) return 0;
    uint avail = s->st.numSamples();
    uint take = avail < static_cast<uint>(maxFrames) ? avail : static_cast<uint>(maxFrames);
    if (take == 0) return 0;
    s->inter.resize(static_cast<size_t>(take) * s->channels);
    uint got = s->st.receiveSamples(s->inter.data(), take);
    for (int c = 0; c < s->channels; ++c) {
        float *dst = out[c];
        const float *src = s->inter.data() + c;
        for (uint i = 0; i < got; ++i) {
            dst[i] = src[static_cast<size_t>(i) * s->channels];
        }
    }
    return static_cast<int32_t>(got);
}

int32_t mk_stouch_flush(mk_stouch_t s, float *const *out, int32_t maxFrames) {
    StretchLock _lock;
    s->st.flush();
    return mk_stouch_receive(s, out, maxFrames);
}

void mk_stouch_flush_drain(mk_stouch_t s) {
    StretchLock _lock;
    s->st.flush();
}

int32_t mk_stouch_latency(mk_stouch_t s) {
    StretchLock _lock;
    return s->st.getSetting(SETTING_INITIAL_LATENCY);
}
