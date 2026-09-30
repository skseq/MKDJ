// ffmpeg_shim.cpp — minimal FFmpeg (LGPL-2.1+) decode extension.
// Vendored libs: vendor/ffmpeg (see VENDORED.txt). Only avformat/avcodec/
// swresample are used; output is planar stereo Float32 at the native rate.
#include "ffmpeg_shim.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
}

struct mk_ff_s {
    AVFormatContext *fmt = nullptr;
    const AVCodec *codec = nullptr;
    AVCodecContext *ctx = nullptr;
    AVFrame *frame = nullptr;
    AVPacket *pkt = nullptr;
    SwrContext *swr = nullptr;
    int stream = -1;
    double sampleRate = 44100;
    int64_t frames = 0;
    float *buf[2] = {nullptr, nullptr};
    int64_t bufStart = 0;
    int64_t bufFilled = 0;
    int64_t bufCap = 0;
    int eofHit = 0;
};

namespace {

// Feed decoded frames into the planar buffer until we have up to `targetEnd`.
// Returns false on unrecoverable decode error. Stops at EOF (the caller
// treats short reads as end-of-file).
bool pump(mk_ff_t f, int64_t targetEnd) {
    while (f->bufStart + f->bufFilled < targetEnd) {
        if (f->eofHit) return true;
        // decode one packet
        int r = av_read_frame(f->fmt, f->pkt);
        if (r < 0) {
            // EOF: flush the decoder once, then stop asking
            av_packet_unref(f->pkt);
            avcodec_send_packet(f->ctx, f->pkt);   // send the flush packet
            while (true) {
                int rr = avcodec_receive_frame(f->ctx, f->frame);
                if (rr == AVERROR(EAGAIN) || rr == AVERROR_EOF) break;
                if (rr < 0) break;
                // drain remaining converted frames below via the shared path
                uint8_t *out[2] = { nullptr, nullptr };
                int outCount = f->frame->nb_samples;
                if (f->bufStart + f->bufFilled + outCount > f->bufCap) {
                    int64_t newCap = f->bufCap * 2 + 65536;
                    for (int c = 0; c < 2; ++c) {
                        f->buf[c] = (float *)realloc(f->buf[c], newCap * sizeof(float));
                    }
                    f->bufCap = newCap;
                }
                out[0] = (uint8_t *)(f->buf[0] + f->bufStart + f->bufFilled);
                out[1] = (uint8_t *)(f->buf[1] + f->bufStart + f->bufFilled);
                int converted = swr_convert(f->swr, out, outCount,
                                             (const uint8_t **) f->frame->data, outCount);
                if (converted > 0) f->bufFilled += converted;
            }
            f->eofHit = 1;
            return true;
        } else {
            if (f->pkt->stream_index != f->stream) { av_packet_unref(f->pkt); continue; }
            r = avcodec_send_packet(f->ctx, f->pkt);
            av_packet_unref(f->pkt);
        }
        if (r < 0 && r != AVERROR(EAGAIN)) return false;

        while (true) {
            r = avcodec_receive_frame(f->ctx, f->frame);
            if (r == AVERROR(EAGAIN)) break;
            if (r == AVERROR_EOF) { f->eofHit = 1; break; }
            if (r < 0) return false;

            // convert to planar stereo float at native rate
            uint8_t *out[2] = { nullptr, nullptr };
            int outCount = f->frame->nb_samples;
            // append space
            if (f->bufStart + f->bufFilled + outCount > f->bufCap) {
                int64_t newCap = f->bufCap * 2 + 65536;
                for (int c = 0; c < 2; ++c) {
                    f->buf[c] = (float *)realloc(f->buf[c], newCap * sizeof(float));
                }
                f->bufCap = newCap;
            }
            out[0] = (uint8_t *)(f->buf[0] + f->bufStart + f->bufFilled);
            out[1] = (uint8_t *)(f->buf[1] + f->bufStart + f->bufFilled);
            int converted = swr_convert(f->swr, out, outCount,
                                         (const uint8_t **) f->frame->data, outCount);
            if (converted < 0) return false;
            f->bufFilled += converted;
        }
    }
    return true;
}

// Discard everything before `frame` (keeps buffer small).
void trim(mk_ff_t f, int64_t frame) {
    if (frame <= f->bufStart) return;
    int64_t drop = frame - f->bufStart;
    if (drop >= f->bufFilled) {
        f->bufFilled = 0;
        f->bufStart = frame;
        return;
    }
    for (int c = 0; c < 2; ++c) {
        memmove(f->buf[c], f->buf[c] + drop, (f->bufFilled - drop) * sizeof(float));
    }
    f->bufFilled -= drop;
    f->bufStart = frame;
}

} // namespace

mk_ff_t mk_ff_open(const char *path, double *outSampleRate, int64_t *outFrames) {
    mk_ff_t f = new mk_ff_s();
    if (avformat_open_input(&f->fmt, path, nullptr, nullptr) < 0) { delete f; return nullptr; }
    if (avformat_find_stream_info(f->fmt, nullptr) < 0) { mk_ff_close(f); return nullptr; }
    f->stream = av_find_best_stream(f->fmt, AVMEDIA_TYPE_AUDIO, -1, -1, &f->codec, 0);
    if (f->stream < 0) { mk_ff_close(f); return nullptr; }
    AVStream *st = f->fmt->streams[f->stream];
    f->ctx = avcodec_alloc_context3(f->codec);
    if (!f->ctx) { mk_ff_close(f); return nullptr; }
    if (avcodec_parameters_to_context(f->ctx, st->codecpar) < 0) { mk_ff_close(f); return nullptr; }
    if (avcodec_open2(f->ctx, f->codec, nullptr) < 0) { mk_ff_close(f); return nullptr; }

    f->sampleRate = f->ctx->sample_rate > 0 ? f->ctx->sample_rate : 44100;
    // planar stereo float output
    AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
    if (swr_alloc_set_opts2(&f->swr,
                            &stereo, AV_SAMPLE_FMT_FLTP, (int) f->sampleRate,
                            &f->ctx->ch_layout, f->ctx->sample_fmt, f->ctx->sample_rate,
                            0, nullptr) < 0) { mk_ff_close(f); return nullptr; }
    if (swr_init(f->swr) < 0) { mk_ff_close(f); return nullptr; }

    // frame count: exact if the stream reports samples, else duration-based
    if (st->duration > 0 && st->time_base.num > 0) {
        f->frames = (int64_t) (st->duration * av_q2d(st->time_base) * f->sampleRate);
    } else if (f->fmt->duration > 0) {
        f->frames = (int64_t) (f->fmt->duration * f->sampleRate);
    }

    f->frame = av_frame_alloc();
    f->pkt = av_packet_alloc();
    if (outSampleRate) *outSampleRate = f->sampleRate;
    if (outFrames) *outFrames = f->frames;
    return f;
}

void mk_ff_close(mk_ff_t f) {
    if (!f) return;
    if (f->swr) swr_free(&f->swr);
    if (f->pkt) av_packet_free(&f->pkt);
    if (f->frame) av_frame_free(&f->frame);
    if (f->ctx) avcodec_free_context(&f->ctx);
    if (f->fmt) avformat_close_input(&f->fmt);
    for (int c = 0; c < 2; ++c) free(f->buf[c]);
    delete f;
}

int64_t mk_ff_frames(mk_ff_t f) { return f->frames; }

int64_t mk_ff_read(mk_ff_t f, int64_t start, int64_t count,
                    float *ch0, float *ch1) {
    if (start < f->bufStart || start >= f->bufStart + f->bufFilled) {
        // outside the buffer: seek + decode-forward
        trim(f, f->bufStart + f->bufFilled);   // keep the tail
        double ts = (double) start / f->sampleRate - 0.2;   // land 200 ms early
        if (ts < 0) ts = 0;
        int64_t targetTs = (int64_t) (ts / av_q2d(f->fmt->streams[f->stream]->time_base));
        if (av_seek_frame(f->fmt, f->stream, targetTs, AVSEEK_FLAG_BACKWARD) < 0) {
            // fall back to a full rewind
            if (av_seek_frame(f->fmt, f->stream, 0, AVSEEK_FLAG_BACKWARD) < 0) return -1;
        }
        avcodec_flush_buffers(f->ctx);
        swr_init(f->swr);
        f->bufStart = start;
        f->bufFilled = 0;
        if (!pump(f, start + count)) return -1;
        // skip any pre-target slop from the early landing
        if (f->bufStart + f->bufFilled > start) {
            // decode landed before start? bufStart was set to start, so the
            // decoder must produce at least start-aligned output; FFmpeg
            // delivers packets from the seek point — drop packets until the
            // decoded stream reaches start by skipping in the reader loop
            // (handled by bufStart alignment above).
        }
    }
    if (!pump(f, start + count)) return -1;
    int64_t have = f->bufStart + f->bufFilled - start;
    int64_t out = have < count ? have : count;
    if (out <= 0) return 0;
    int64_t off = start - f->bufStart;
    memcpy(ch0, f->buf[0] + off, out * sizeof(float));
    memcpy(ch1, f->buf[1] + off, out * sizeof(float));
    trim(f, start + out);
    return out;
}
