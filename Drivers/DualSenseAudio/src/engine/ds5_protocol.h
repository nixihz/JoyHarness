// DualSense Bluetooth audio wire protocol: report builders, CRC, mic gap policy, the speaker jitter-buffer policy
// and the speaker resampler.
// Pure functions (no IOKit, no allocation, no locking); the byte layouts are the hardware-verified ones.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define DS5_VENDOR_ID 0x054C
#define DS5_PRODUCT_ID 0x0CE6

enum {
    // A: audio config (state) report.
    DS5_CONFIG_REPORT_ID = 0x31,
    DS5_CONFIG_REPORT_LEN = 78,
    // B: mic session toggle.
    DS5_MIC_TOGGLE_REPORT_ID = 0x32,
    DS5_MIC_TOGGLE_REPORT_LEN = 142,
    // C: speaker audio, one 3-DH1 baseband packet.
    DS5_SPEAKER_REPORT_ID = 0x31,
    DS5_SPEAKER_REPORT_LEN = 78,
    DS5_SPEAKER_OPUS_BYTES = 31,          // bytes per speaker Opus frame
    DS5_SPEAKER_FRAME_INPUT = 512,        // 48 kHz input frames consumed per Opus frame
    DS5_SPEAKER_FRAMES_PER_REPORT = 1024, // two Opus frames per report
    DS5_SPEAKER_PREBUFFER_FRAMES = 2048,  // speaker frames queued before the sender starts consuming them
    DS5_OPUS_FRAME_SAMPLES = 480,         // samples in one 10 ms Opus frame at 48 kHz

    // Input reports.
    DS5_INPUT_REPORT_ID = 0x31,
    DS5_INPUT_REPORT_BUFFER = 1024,       // registration buffer (>= 547 bytes)
    DS5_MIC_OPUS_OFFSET = 3,
    DS5_MIC_OPUS_BYTES = 71,
    DS5_MIC_REPORT_MIN_LEN = DS5_MIC_OPUS_OFFSET + DS5_MIC_OPUS_BYTES,
    DS5_MIC_MAX_CONCEAL_GAP = 10,         // counter gaps up to this are concealed, larger ones reset

    // Feature report read on connect (calibration; harmless, switches the controller to full reports).
    DS5_FEATURE_CALIBRATION_ID = 0x05,
    DS5_FEATURE_CALIBRATION_LEN = 41,
};

// Counters shared by every output report. Callers serialize access (one instance per controller link).
typedef struct {
    uint8_t seq;     // next output sequence number; only the low nibble goes on the wire
    uint8_t session; // session counter carried by the session packet of mic/speaker reports
} ds5_counters;

// Standard reflected CRC-32 (poly 0xEDB88320, init/final xor 0xFFFFFFFF), chainable:
// ds5_crc32(ds5_crc32(0, a, n), b, m) == CRC of a||b.  ds5_crc32(0, "123456789", 9) == 0xCBF43926.
uint32_t ds5_crc32(uint32_t crc, const void *data, size_t len);
// Output report CRC: CRC-32 over the byte 0xA2 followed by report[0 .. len-5].
uint32_t ds5_report_crc(const uint8_t *report, size_t len);
// Stores ds5_report_crc(report, len) little-endian in report[len-4 .. len-1].
void ds5_report_seal(uint8_t *report, size_t len);

// Builders write the complete report including its CRC. Each consumes one sequence number:
// out[1] = (c->seq & 0x0F) << 4, then c->seq++.
// A: [0]=0x31 [1]=seq<<4 [2]=0x10 [3]=0xE0 [4]=0x82 [8]=0x7F [9]=0x40 [10]=0x31 [40]=0x07, all else 0.
void ds5_build_config(uint8_t out[DS5_CONFIG_REPORT_LEN], ds5_counters *c);
// B: [0]=0x32 [1]=seq<<4 [2]=0x91 [3]=7 [4]=open?0xFF:0xFE [9]=48 [10]=c->session (then c->session += 1)
//    [11]=0x92 [12]=64, all else 0.
void ds5_build_mic_toggle(uint8_t out[DS5_MIC_TOGGLE_REPORT_LEN], ds5_counters *c, bool open);
// C: c->session += 2 first, then [0]=0x31 [1]=seq<<4 [2]=0x91 [3]=6 [4]=mic_open?0x7F:0x7E [5..8]=48
//    [9]=c->session [10]=0xD3 [11]=31 [12..42]=frame1 [43..73]=frame2.
void ds5_build_speaker(uint8_t out[DS5_SPEAKER_REPORT_LEN], ds5_counters *c, bool mic_open,
                       const uint8_t frame1[DS5_SPEAKER_OPUS_BYTES], const uint8_t frame2[DS5_SPEAKER_OPUS_BYTES]);

// True for a mic frame input report: len >= DS5_MIC_REPORT_MIN_LEN, [0] == 0x31 and ([1] & 0x02).
bool ds5_is_mic_report(const uint8_t *report, size_t len);

// What to do before decoding a mic frame whose counter (report[2]) is `counter`.
typedef struct {
    uint8_t conceal; // frames to synthesize with Opus PLC before decoding the new frame (0..9)
    bool reset;      // reset the decoder (OPUS_RESET_STATE) first; never combined with conceal
} ds5_mic_gap;
// last < 0: first frame of a session -> {0, false}. Otherwise g = (counter - last) & 0xFF:
// g == 1 -> {0, false}; 1 < g <= 10 -> {g - 1, false}; g == 0 or g > 10 -> {0, true}.
// (g == 0 means a whole 256-frame wrap was lost or the frame repeated; either way nothing is concealed.)
ds5_mic_gap ds5_mic_gap_decide(int last, uint8_t counter);

// What the speaker sender does in one tick. It collects DS5_SPEAKER_PREBUFFER_FRAMES before it starts consuming the
// speaker ring (at every speaker start and after every underrun), sending silent reports meanwhile.
typedef struct {
    uint32_t read; // frames to take from the speaker ring (0..1024); the rest of the report is zero-filled
    bool play;     // this tick plays ring audio, so any shortfall counts as an underrun; false: priming silence
    bool primed;   // state for the next tick; play && !primed means this tick underran and the sender rebuffers
} ds5_speaker_tick;
// primed: state after the previous tick (false at speaker start); available: frames queued in the speaker ring.
// Not primed: available < 2048 -> {0, false, false}; available >= 2048 -> {1024, true, true}.
// Primed:     available >= 1024 -> {1024, true, true}; available < 1024 -> {available, true, false}.
ds5_speaker_tick ds5_speaker_tick_decide(bool primed, uint32_t available);

// Linear time-compress 512 -> 480: out[i] = lerp(in, i * 511 / 479), with the position computed in exact
// integer arithmetic (lo = i*511 / 479, frac = (i*511 % 479) / 479), so out[0] == in[0] and out[479] == in[511].
void ds5_compress_512_to_480(const float in[DS5_SPEAKER_FRAME_INPUT], float out[DS5_OPUS_FRAME_SAMPLES]);
