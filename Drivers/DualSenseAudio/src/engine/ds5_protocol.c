#include "ds5_protocol.h"

#include <string.h>

enum { BT_OUTPUT_HEADER = 0xA2 };

static uint32_t crc32_update(uint32_t state, const uint8_t *p, size_t len) {
    for (size_t i = 0; i < len; i++) {
        state ^= p[i];
        for (int b = 0; b < 8; b++)
            state = (state >> 1) ^ (0xEDB88320u & (0u - (state & 1u)));
    }
    return state;
}

uint32_t ds5_crc32(uint32_t crc, const void *data, size_t len) {
    return ~crc32_update(~crc, data, len);
}

uint32_t ds5_report_crc(const uint8_t *report, size_t len) {
    const uint8_t header = BT_OUTPUT_HEADER;
    uint32_t crc = ds5_crc32(0, &header, 1);
    return ds5_crc32(crc, report, len - 4);
}

void ds5_report_seal(uint8_t *report, size_t len) {
    uint32_t crc = ds5_report_crc(report, len);
    for (int i = 0; i < 4; i++)
        report[len - 4 + i] = (uint8_t)(crc >> (8 * i));
}

// Clears the report and writes the id and the next sequence number.
static void begin_report(uint8_t *out, size_t len, uint8_t id, ds5_counters *c) {
    memset(out, 0, len);
    out[0] = id;
    out[1] = (uint8_t)((c->seq & 0x0F) << 4);
    c->seq++;
}

void ds5_build_config(uint8_t out[DS5_CONFIG_REPORT_LEN], ds5_counters *c) {
    begin_report(out, DS5_CONFIG_REPORT_LEN, DS5_CONFIG_REPORT_ID, c);
    out[2] = 0x10;
    out[3] = 0xE0;
    out[4] = 0x82;
    out[8] = 0x7F; // speaker volume: hardware maximum
    out[9] = 0x40;
    out[10] = 0x31;
    out[40] = 0x07; // SpeakerCompPreGain: maximum
    ds5_report_seal(out, DS5_CONFIG_REPORT_LEN);
}

void ds5_build_mic_toggle(uint8_t out[DS5_MIC_TOGGLE_REPORT_LEN], ds5_counters *c, bool open) {
    begin_report(out, DS5_MIC_TOGGLE_REPORT_LEN, DS5_MIC_TOGGLE_REPORT_ID, c);
    out[2] = 0x91;
    out[3] = 7;
    out[4] = open ? 0xFF : 0xFE;
    out[9] = 48;
    out[10] = c->session++;
    out[11] = 0x92;
    out[12] = 64;
    ds5_report_seal(out, DS5_MIC_TOGGLE_REPORT_LEN);
}

void ds5_build_speaker(uint8_t out[DS5_SPEAKER_REPORT_LEN], ds5_counters *c, bool mic_open,
                       const uint8_t frame1[DS5_SPEAKER_OPUS_BYTES], const uint8_t frame2[DS5_SPEAKER_OPUS_BYTES]) {
    c->session += 2;
    begin_report(out, DS5_SPEAKER_REPORT_LEN, DS5_SPEAKER_REPORT_ID, c);
    out[2] = 0x91;
    out[3] = 6;
    out[4] = mic_open ? 0x7F : 0x7E;
    out[5] = out[6] = out[7] = out[8] = 48;
    out[9] = c->session;
    out[10] = 0xD3;
    out[11] = DS5_SPEAKER_OPUS_BYTES;
    memcpy(out + 12, frame1, DS5_SPEAKER_OPUS_BYTES);
    memcpy(out + 12 + DS5_SPEAKER_OPUS_BYTES, frame2, DS5_SPEAKER_OPUS_BYTES);
    ds5_report_seal(out, DS5_SPEAKER_REPORT_LEN);
}

bool ds5_is_mic_report(const uint8_t *report, size_t len) {
    return report && len >= DS5_MIC_REPORT_MIN_LEN && report[0] == DS5_INPUT_REPORT_ID && (report[1] & 0x02);
}

ds5_mic_gap ds5_mic_gap_decide(int last, uint8_t counter) {
    ds5_mic_gap gap = {0, false};
    if (last < 0)
        return gap;
    uint8_t g = (uint8_t)(counter - (uint8_t)last);
    if (g == 0 || g > DS5_MIC_MAX_CONCEAL_GAP)
        gap.reset = true;
    else
        gap.conceal = (uint8_t)(g - 1);
    return gap;
}

ds5_speaker_tick ds5_speaker_tick_decide(bool primed, uint32_t available) {
    if (!primed && available < DS5_SPEAKER_PREBUFFER_FRAMES)
        return (ds5_speaker_tick){0, false, false};
    if (available >= DS5_SPEAKER_FRAMES_PER_REPORT)
        return (ds5_speaker_tick){DS5_SPEAKER_FRAMES_PER_REPORT, true, true};
    return (ds5_speaker_tick){available, true, false};
}

void ds5_compress_512_to_480(const float in[DS5_SPEAKER_FRAME_INPUT], float out[DS5_OPUS_FRAME_SAMPLES]) {
    enum { SPAN_IN = DS5_SPEAKER_FRAME_INPUT - 1, SPAN_OUT = DS5_OPUS_FRAME_SAMPLES - 1 };
    for (uint32_t i = 0; i < DS5_OPUS_FRAME_SAMPLES; i++) {
        uint32_t pos = i * SPAN_IN;
        uint32_t lo = pos / SPAN_OUT;
        uint32_t rem = pos % SPAN_OUT;
        if (rem == 0)
            out[i] = in[lo]; // also keeps lo + 1 in range at lo == 511
        else
            out[i] = in[lo] + (in[lo + 1] - in[lo]) * (float)rem / (float)SPAN_OUT;
    }
}
