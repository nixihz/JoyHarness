#include "ds5_shm.h"

#include <string.h>
#include <unistd.h>

size_t ds5_shm_size(void) {
    size_t page = (size_t)getpagesize();
    return (sizeof(ds5_shm_layout) + page - 1) / page * page;
}

static bool region_ok(const void *mem, size_t size) {
    return mem && (uintptr_t)mem % _Alignof(ds5_shm_layout) == 0 && size >= ds5_shm_size();
}

bool ds5_shm_format(void *mem, size_t size) {
    if (!region_ok(mem, size))
        return false;
    ds5_shm_layout *l = mem;
    memset(&l->header, 0, sizeof l->header);
    if (!ds5_ring_format(&l->speaker, l->speaker_samples, DS5_SHM_SPEAKER_CAPACITY, DS5_SHM_SPEAKER_BOUND) ||
        !ds5_ring_format(&l->mic, l->mic_samples, DS5_SHM_MIC_CAPACITY, DS5_SHM_MIC_BOUND))
        return false;
    l->header.version = DS5_SHM_VERSION;
    l->header.size = ds5_shm_size();
    l->header.speaker_capacity = DS5_SHM_SPEAKER_CAPACITY;
    l->header.speaker_bound = DS5_SHM_SPEAKER_BOUND;
    l->header.mic_capacity = DS5_SHM_MIC_CAPACITY;
    l->header.mic_bound = DS5_SHM_MIC_BOUND;
    atomic_init(&l->header.mic_session_start, 0);
    atomic_thread_fence(memory_order_release); // magic last: a region with the magic is fully formatted
    l->header.magic = DS5_SHM_MAGIC;
    return true;
}

bool ds5_shm_check(const void *mem, size_t size) {
    if (!region_ok(mem, size))
        return false;
    const ds5_shm_header *h = &((const ds5_shm_layout *)mem)->header;
    return h->magic == DS5_SHM_MAGIC && h->version == DS5_SHM_VERSION && h->size == ds5_shm_size() &&
           h->speaker_capacity == DS5_SHM_SPEAKER_CAPACITY && h->speaker_bound == DS5_SHM_SPEAKER_BOUND &&
           h->mic_capacity == DS5_SHM_MIC_CAPACITY && h->mic_bound == DS5_SHM_MIC_BOUND;
}

void ds5_shm_speaker_view(void *mem, ds5_ring *out) {
    ds5_shm_layout *l = mem;
    ds5_ring_view(out, &l->speaker, l->speaker_samples, DS5_SHM_SPEAKER_CAPACITY, DS5_SHM_SPEAKER_BOUND);
}

void ds5_shm_mic_view(void *mem, ds5_ring *out) {
    ds5_shm_layout *l = mem;
    ds5_ring_view(out, &l->mic, l->mic_samples, DS5_SHM_MIC_CAPACITY, DS5_SHM_MIC_BOUND);
}

void ds5_shm_set_mic_session(void *mem, uint64_t pos) {
    atomic_store_explicit(&((ds5_shm_layout *)mem)->header.mic_session_start, pos, memory_order_release);
}

uint64_t ds5_shm_mic_session(void *mem) {
    return atomic_load_explicit(&((ds5_shm_layout *)mem)->header.mic_session_start, memory_order_acquire);
}
