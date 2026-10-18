// Opus side of the DualSense audio protocol: the speaker encoder and the gap-concealing mic decoder.
// No IOKit; each object is used by one thread at a time.
#pragma once

#include "ds5_protocol.h"

#include <opus.h>

// Speaker encoder: opus_encoder_create(48000, 1, OPUS_APPLICATION_AUDIO), OPUS_SET_BITRATE(24800),
// OPUS_SET_VBR(0), OPUS_SET_EXPERT_FRAME_DURATION(OPUS_FRAMESIZE_10_MS). NULL on failure.
OpusEncoder *ds5_speaker_encoder_create(void);
void ds5_speaker_encoder_reset(OpusEncoder *enc); // OPUS_RESET_STATE
// Encodes one report's audio: mono[0..511] and mono[512..1023] are each compressed 512 -> 480
// (ds5_compress_512_to_480) and encoded with opus_encode_float(enc, pcm, 480, frameN, 31).
// Returns true when both frames encoded to exactly DS5_SPEAKER_OPUS_BYTES; on any failure the affected
// frame is zero-filled and false is returned. Real-time safe (no allocation).
bool ds5_speaker_encode_report(OpusEncoder *enc, const float mono[DS5_SPEAKER_FRAMES_PER_REPORT],
                               uint8_t frame1[DS5_SPEAKER_OPUS_BYTES], uint8_t frame2[DS5_SPEAKER_OPUS_BYTES]);

// Receives each decoded or concealed block of mono float PCM at 48 kHz (normally 480 frames).
typedef void (*ds5_pcm_sink)(void *ctx, const float *pcm, uint32_t frames);

typedef struct {
    OpusDecoder *dec;  // opus_decoder_create(48000, 1)
    int last_counter;  // mic frame counter of the previous frame; -1 before the first frame of a session
} ds5_mic_decoder;

// Outcome of one mic input report.
typedef struct {
    uint32_t received;  // 1 when the report's Opus packet decoded, else 0
    uint32_t concealed; // PLC frames synthesized: counter-gap concealment plus 1 if the packet failed to decode
    bool reset;         // the decoder was reset for a large gap (or a repeated counter)
} ds5_mic_result;

bool ds5_mic_decoder_init(ds5_mic_decoder *m); // false if Opus allocation fails
void ds5_mic_decoder_free(ds5_mic_decoder *m);
void ds5_mic_decoder_reset(ds5_mic_decoder *m); // OPUS_RESET_STATE and last_counter = -1 (new session)
// Handles one input report for which ds5_is_mic_report() is true. Applies ds5_mic_gap_decide(): conceals
// with opus_decode_float(dec, NULL, 0, pcm, 480, 0) or resets, then decodes report[3..73] (71 bytes); a
// packet that fails to decode is replaced by one PLC frame. Every block goes to sink in stream order.
ds5_mic_result ds5_mic_decoder_push(ds5_mic_decoder *m, const uint8_t *report, size_t len, ds5_pcm_sink sink,
                                    void *ctx);
