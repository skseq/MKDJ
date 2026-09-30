// ffmpeg_shim.h — minimal FFmpeg (LGPL-2.1+) decode extension for MKDJ:
// reads formats CoreAudio can't (ogg/vorbis, ogg/opus, wma,
// amr, mkv audio), converting to planar-stereo Float32 at the file's native
// sample rate (the PullDeck reader's contract). Frame-addressable reads with
// backward-capable seeking: av_seek_frame to just before the target
// timestamp, then decode-forward to the exact sample.
#ifndef ffmpeg_shim_h
#define ffmpeg_shim_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mk_ff_s *mk_ff_t;

// Open a file; returns NULL on unsupported/failed. *outSampleRate gets the
// native rate; *outFrames gets the total frame count (estimated from
// duration when the container lacks an exact count).
mk_ff_t mk_ff_open(const char *path, double *outSampleRate, int64_t *outFrames);

void mk_ff_close(mk_ff_t f);

// Total frames (updated as duration estimates refine).
int64_t mk_ff_frames(mk_ff_t f);

// Read `count` frames starting at absolute frame `start` into the planar
// buffers (ch0, ch1 — mono sources are duplicated to both). Returns frames
// actually read (0 at EOF, -1 on seek/decode error).
int64_t mk_ff_read(mk_ff_t f, int64_t start, int64_t count,
                     float *ch0, float *ch1);

#ifdef __cplusplus
}
#endif

#endif
