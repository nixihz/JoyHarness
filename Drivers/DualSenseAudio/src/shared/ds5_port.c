#include "ds5_shm.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

struct ds5_port {
    void *mem;
    ds5_ring speaker; // this port is the writer
    ds5_ring mic;     // this port is the reader
    // Reader-side state, process-local.
    uint64_t mic_session_seen;
    bool mic_primed;
};

ds5_port *ds5_port_attach(void *mem, size_t size) {
    if (!ds5_shm_check(mem, size))
        return NULL;
    ds5_port *p = calloc(1, sizeof *p);
    if (!p)
        return NULL;
    p->mem = mem;
    ds5_shm_speaker_view(mem, &p->speaker);
    ds5_shm_mic_view(mem, &p->mic);
    // Mic audio queued before this attach belongs to an earlier reader: start at the newest sample.
    p->mic_session_seen = ds5_shm_mic_session(mem);
    ds5_ring_skip_to(&p->mic, ds5_ring_write_pos(&p->mic));
    p->mic_primed = false;
    return p;
}

void ds5_port_detach(ds5_port *p) {
    free(p);
}

// mono[i] = tanh(DS5_SPEAKER_BOOST * (L + R) / 2 * gain): +6 dB makeup gain through a soft limiter, so the output
// never leaves [-1, 1]. NaN becomes 0.
static void downmix_boost(const float *stereo, float *mono, uint32_t frames, float gain) {
    for (uint32_t i = 0; i < frames; i++) {
        float v = (stereo[2 * i] + stereo[2 * i + 1]) * 0.5f * gain;
        mono[i] = isnan(v) ? 0.0f : tanhf(DS5_SPEAKER_BOOST * v);
    }
}

void ds5_port_speaker_write(ds5_port *p, const float *stereo, uint32_t frames, float gain, bool mute) {
    if (!p || !stereo)
        return;
    if (frames > p->speaker.bound) {
        // Only the newest `bound` frames would survive in the ring anyway.
        stereo += 2 * (size_t)(frames - p->speaker.bound);
        frames = p->speaker.bound;
    }
    if (mute)
        gain = 0.0f;
    float mono[DS5_SPEAKER_WRITE_CHUNK];
    while (frames > 0) {
        uint32_t n = frames < DS5_SPEAKER_WRITE_CHUNK ? frames : DS5_SPEAKER_WRITE_CHUNK;
        downmix_boost(stereo, mono, n, gain);
        ds5_ring_write(&p->speaker, mono, n);
        stereo += 2 * (size_t)n;
        frames -= n;
    }
}

uint32_t ds5_port_mic_read(ds5_port *p, float *mono, uint32_t frames) {
    if (!mono || frames == 0)
        return 0;
    if (!p) {
        memset(mono, 0, frames * sizeof *mono);
        return 0;
    }
    uint64_t session = ds5_shm_mic_session(p->mem);
    if (session != p->mic_session_seen) {
        // A new mic session started: drop what is left of the previous one and prebuffer again.
        p->mic_session_seen = session;
        ds5_ring_skip_to(&p->mic, session);
        p->mic_primed = false;
    }
    if (!p->mic_primed) {
        if (ds5_ring_available(&p->mic) < DS5_MIC_PREBUFFER_FRAMES) {
            memset(mono, 0, frames * sizeof *mono);
            return 0;
        }
        p->mic_primed = true;
    }
    uint32_t got = ds5_ring_read(&p->mic, mono, frames);
    if (got < frames) {
        memset(mono + got, 0, (frames - got) * sizeof *mono);
        p->mic_primed = false; // underrun: prebuffer again
    }
    return got;
}
