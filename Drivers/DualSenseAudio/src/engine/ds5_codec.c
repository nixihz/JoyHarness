#include "ds5_codec.h"

#include <string.h>

enum {
    SAMPLE_RATE = 48000,
    SPEAKER_BITRATE = 24800,
    MIC_MAX_DECODE = 960, // room for the largest frame a malformed-but-valid packet could carry
};

OpusEncoder *ds5_speaker_encoder_create(void) {
    int err = OPUS_OK;
    OpusEncoder *enc = opus_encoder_create(SAMPLE_RATE, 1, OPUS_APPLICATION_AUDIO, &err);
    if (!enc || err != OPUS_OK)
        return NULL;
    if (opus_encoder_ctl(enc, OPUS_SET_BITRATE(SPEAKER_BITRATE)) != OPUS_OK ||
        opus_encoder_ctl(enc, OPUS_SET_VBR(0)) != OPUS_OK ||
        opus_encoder_ctl(enc, OPUS_SET_EXPERT_FRAME_DURATION(OPUS_FRAMESIZE_10_MS)) != OPUS_OK) {
        opus_encoder_destroy(enc);
        return NULL;
    }
    return enc;
}

void ds5_speaker_encoder_reset(OpusEncoder *enc) {
    opus_encoder_ctl(enc, OPUS_RESET_STATE);
}

static bool encode_frame(OpusEncoder *enc, const float *mono512, uint8_t frame[DS5_SPEAKER_OPUS_BYTES]) {
    float pcm[DS5_OPUS_FRAME_SAMPLES];
    ds5_compress_512_to_480(mono512, pcm);
    opus_int32 n = opus_encode_float(enc, pcm, DS5_OPUS_FRAME_SAMPLES, frame, DS5_SPEAKER_OPUS_BYTES);
    if (n == DS5_SPEAKER_OPUS_BYTES)
        return true;
    memset(frame, 0, DS5_SPEAKER_OPUS_BYTES);
    return false;
}

bool ds5_speaker_encode_report(OpusEncoder *enc, const float mono[DS5_SPEAKER_FRAMES_PER_REPORT],
                               uint8_t frame1[DS5_SPEAKER_OPUS_BYTES], uint8_t frame2[DS5_SPEAKER_OPUS_BYTES]) {
    bool ok1 = encode_frame(enc, mono, frame1);
    bool ok2 = encode_frame(enc, mono + DS5_SPEAKER_FRAME_INPUT, frame2);
    return ok1 && ok2;
}

bool ds5_mic_decoder_init(ds5_mic_decoder *m) {
    int err = OPUS_OK;
    m->dec = opus_decoder_create(SAMPLE_RATE, 1, &err);
    m->last_counter = -1;
    if (m->dec && err == OPUS_OK)
        return true;
    if (m->dec)
        opus_decoder_destroy(m->dec);
    m->dec = NULL;
    return false;
}

void ds5_mic_decoder_free(ds5_mic_decoder *m) {
    if (m->dec)
        opus_decoder_destroy(m->dec);
    m->dec = NULL;
}

void ds5_mic_decoder_reset(ds5_mic_decoder *m) {
    opus_decoder_ctl(m->dec, OPUS_RESET_STATE);
    m->last_counter = -1;
}

// Synthesizes one PLC frame; returns true if a frame went to the sink.
static bool conceal_frame(ds5_mic_decoder *m, ds5_pcm_sink sink, void *ctx) {
    float pcm[DS5_OPUS_FRAME_SAMPLES];
    int n = opus_decode_float(m->dec, NULL, 0, pcm, DS5_OPUS_FRAME_SAMPLES, 0);
    if (n <= 0)
        return false;
    sink(ctx, pcm, (uint32_t)n);
    return true;
}

ds5_mic_result ds5_mic_decoder_push(ds5_mic_decoder *m, const uint8_t *report, size_t len, ds5_pcm_sink sink,
                                    void *ctx) {
    ds5_mic_result res = {0, 0, false};
    uint8_t counter = report[2];
    ds5_mic_gap gap = ds5_mic_gap_decide(m->last_counter, counter);
    m->last_counter = counter;

    if (gap.reset) {
        opus_decoder_ctl(m->dec, OPUS_RESET_STATE);
        res.reset = true;
    }
    for (uint8_t i = 0; i < gap.conceal; i++)
        res.concealed += conceal_frame(m, sink, ctx);

    float pcm[MIC_MAX_DECODE];
    int n = opus_decode_float(m->dec, report + DS5_MIC_OPUS_OFFSET, DS5_MIC_OPUS_BYTES, pcm, MIC_MAX_DECODE, 0);
    if (n > 0) {
        sink(ctx, pcm, (uint32_t)n);
        res.received = 1;
    } else {
        res.concealed += conceal_frame(m, sink, ctx);
    }
    return res;
}
