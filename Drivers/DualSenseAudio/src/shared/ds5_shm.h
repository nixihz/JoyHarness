// Layout of the shared audio region (see ds5_shared.h) and the daemon/engine-side accessors.
// Internal to the engine, the daemon, the port implementation and the tests; the plug-in uses ds5_shared.h only.
//
// Everything sits at a fixed offset inside one struct and nothing in the region is a pointer, so each process
// can map it at any address. Ring geometry always comes from the constants below, never from the region.
#pragma once

#include "ds5_ring.h"
#include "ds5_shared.h"

#define DS5_SHM_MAGIC 0x41355344u // "DS5A" in memory order
#define DS5_SHM_VERSION 1u

enum {
    DS5_SHM_SPEAKER_CAPACITY = 16384,
    DS5_SHM_SPEAKER_BOUND = 8192, // ~171 ms of mono speaker audio queued at most
    DS5_SHM_MIC_CAPACITY = 32768,
    DS5_SHM_MIC_BOUND = 9600,          // 200 ms of mono mic audio queued at most
    DS5_MIC_PREBUFFER_FRAMES = 1920,   // 40 ms collected before the first non-silent read after a new
                                       // session, an attach or an underrun
    DS5_SPEAKER_WRITE_CHUNK = 256,     // stack buffer frames for the speaker downmix
};

// Fixed makeup gain of the speaker path: the port sends tanh(DS5_SPEAKER_BOOST * x) for the downmixed, gain-scaled
// sample x (+6 dB for small signals, soft-limited to (-1, 1) instead of clipping).
#define DS5_SPEAKER_BOOST 2.0f

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint64_t size; // ds5_shm_size() of the formatting process
    uint32_t speaker_capacity;
    uint32_t speaker_bound;
    uint32_t mic_capacity;
    uint32_t mic_bound;
    // Mic ring position where the newest mic session starts. The daemon stores it when it opens a session;
    // the port reader discards everything before it and prebuffers again.
    _Alignas(DS5_CACHE_LINE) _Atomic uint64_t mic_session_start;
} ds5_shm_header;

typedef struct {
    ds5_shm_header header;
    ds5_ring_state speaker; // mono 48 kHz; plug-in port writes, daemon sender reads
    ds5_ring_state mic;     // mono 48 kHz; daemon decoder writes, plug-in port reads
    _Atomic float speaker_samples[DS5_SHM_SPEAKER_CAPACITY];
    _Atomic float mic_samples[DS5_SHM_MIC_CAPACITY];
} ds5_shm_layout;

// Local views of a region that passed ds5_shm_check.
void ds5_shm_speaker_view(void *mem, ds5_ring *out);
void ds5_shm_mic_view(void *mem, ds5_ring *out);
// Mic writer: the session starting now begins at mic ring position pos.
void ds5_shm_set_mic_session(void *mem, uint64_t pos);
// Mic reader: start position of the newest session.
uint64_t ds5_shm_mic_session(void *mem);
