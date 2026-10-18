#include "ds5_ring.h"

#include <string.h>

enum { RING_READ_ATTEMPTS = 8 };

bool ds5_ring_geometry_ok(uint32_t capacity, uint32_t bound) {
    return bound > 0 && capacity > 0 && (capacity & (capacity - 1)) == 0 && (uint64_t)bound * 2 <= capacity;
}

bool ds5_ring_format(ds5_ring_state *state, _Atomic float *samples, uint32_t capacity, uint32_t bound) {
    if (!state || !samples || !ds5_ring_geometry_ok(capacity, bound))
        return false;
    memset(state, 0, sizeof *state);
    state->capacity = capacity;
    state->bound = bound;
    atomic_init(&state->claim, 0);
    atomic_init(&state->wpos, 0);
    atomic_init(&state->rpos, 0);
    atomic_init(&state->dropped, 0);
    for (uint32_t i = 0; i < capacity; i++)
        atomic_init(&samples[i], 0.0f);
    return true;
}

bool ds5_ring_view(ds5_ring *r, ds5_ring_state *state, _Atomic float *samples, uint32_t capacity, uint32_t bound) {
    memset(r, 0, sizeof *r);
    if (!state || !samples || !ds5_ring_geometry_ok(capacity, bound))
        return false;
    r->state = state;
    r->samples = samples;
    r->capacity = capacity;
    r->mask = capacity - 1;
    r->bound = bound;
    return true;
}

void ds5_ring_write(const ds5_ring *r, const float *src, uint32_t n) {
    if (n == 0)
        return;
    ds5_ring_state *s = r->state;
    // Only the writer stores wpos, so a relaxed load of our own last value is exact.
    uint64_t w = atomic_load_explicit(&s->wpos, memory_order_relaxed);
    if (n > r->bound) {
        // Older samples would be dropped by the reader anyway; never write more than `bound` at once so a
        // single write cannot overlap itself.
        uint32_t skip = n - r->bound;
        src += skip;
        w += skip;
        n = r->bound;
    }
    // Publish the region we are about to overwrite before touching it (seqlock-style claim). The release
    // fence orders the claim before the sample stores; a reader that observes any new sample also
    // observes this claim (its acquire fence pairs with ours).
    atomic_store_explicit(&s->claim, w + n, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    for (uint32_t i = 0; i < n; i++)
        atomic_store_explicit(&r->samples[(w + i) & r->mask], src[i], memory_order_relaxed);
    atomic_store_explicit(&s->wpos, w + n, memory_order_release);
}

uint64_t ds5_ring_write_pos(const ds5_ring *r) {
    return atomic_load_explicit(&r->state->wpos, memory_order_acquire);
}

uint32_t ds5_ring_available(const ds5_ring *r) {
    uint64_t w = atomic_load_explicit(&r->state->wpos, memory_order_acquire);
    uint64_t rd = atomic_load_explicit(&r->state->rpos, memory_order_relaxed);
    uint64_t avail = w - rd;
    return avail > r->bound ? r->bound : (uint32_t)avail;
}

uint32_t ds5_ring_read(const ds5_ring *r, float *dst, uint32_t n) {
    ds5_ring_state *s = r->state;
    uint64_t rd = atomic_load_explicit(&s->rpos, memory_order_relaxed);
    for (int attempt = 0; attempt < RING_READ_ATTEMPTS; attempt++) {
        uint64_t w = atomic_load_explicit(&s->wpos, memory_order_acquire);
        if (w - rd > r->bound) {
            atomic_fetch_add_explicit(&s->dropped, w - r->bound - rd, memory_order_relaxed);
            rd = w - r->bound;
        }
        uint64_t avail = w - rd;
        uint32_t k = avail < n ? (uint32_t)avail : n;
        for (uint32_t i = 0; i < k; i++)
            dst[i] = atomic_load_explicit(&r->samples[(rd + i) & r->mask], memory_order_relaxed);
        // Validate: a sample at position p is overwritten by the write of p + capacity. If the writer's claim
        // reached past rd + capacity during the copy, the oldest copied samples may be torn.
        atomic_thread_fence(memory_order_acquire);
        uint64_t c = atomic_load_explicit(&s->claim, memory_order_relaxed);
        if (c <= rd + r->capacity) {
            atomic_store_explicit(&s->rpos, rd + k, memory_order_relaxed);
            return k;
        }
        uint64_t valid_from = c - r->capacity;
        atomic_fetch_add_explicit(&s->dropped, valid_from - rd, memory_order_relaxed);
        rd = valid_from;
    }
    // Only reachable with a writer producing far faster than real time; report an underrun this call.
    atomic_store_explicit(&s->rpos, rd, memory_order_relaxed);
    return 0;
}

void ds5_ring_skip_to(const ds5_ring *r, uint64_t pos) {
    uint64_t w = atomic_load_explicit(&r->state->wpos, memory_order_acquire);
    if (pos > w)
        pos = w;
    if (pos > atomic_load_explicit(&r->state->rpos, memory_order_relaxed))
        atomic_store_explicit(&r->state->rpos, pos, memory_order_relaxed);
}

uint64_t ds5_ring_dropped(const ds5_ring *r) {
    return atomic_load_explicit(&r->state->dropped, memory_order_relaxed);
}
