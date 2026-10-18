// Lock-free single-producer / single-consumer float ring that can live in memory shared between processes.
//
// The ring's state (ds5_ring_state) and its samples sit at fixed places in the shared region and contain no
// pointers; each process works through its own local view (ds5_ring), whose geometry comes from the caller's
// compile-time layout, never from shared memory, so indices are always masked into range.
//
// The writer never blocks or fails: it always appends, overwriting the oldest samples. The reader keeps at
// most `bound` samples queued: when the writer is more than `bound` ahead, the reader drops the oldest.
// The capacity is a power of two >= 2 * bound, so a writer can only overwrite samples the reader is copying
// when it gets (capacity - bound) samples ahead during one copy; that case is detected seqlock-style (the
// writer publishes the end of the region it is about to overwrite before touching it) and the read is
// retried, so readers never return torn data.
//
// Every function except ds5_ring_format is real-time safe. Writer-side and reader-side functions may each be
// called from one thread at a time (possibly in different processes); the two sides may run concurrently.
#pragma once

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_INT_LOCK_FREE == 2,
               "cross-process rings need lock-free (address-free) atomics");

#define DS5_CACHE_LINE 128

// Shared state. Writer-owned and reader-owned fields sit on separate cache lines.
typedef struct {
    _Alignas(DS5_CACHE_LINE) uint32_t capacity; // set by ds5_ring_format; informational
    uint32_t bound;
    _Alignas(DS5_CACHE_LINE) _Atomic uint64_t claim; // writer: end of the region being written
    _Atomic uint64_t wpos;                           // writer: end of the published samples
    _Alignas(DS5_CACHE_LINE) _Atomic uint64_t rpos;  // reader: next sample to read
    _Atomic uint64_t dropped;                        // reader: samples dropped because the writer ran ahead
} ds5_ring_state;

// Process-local view.
typedef struct {
    ds5_ring_state *state;
    _Atomic float *samples;
    uint32_t capacity; // power of two
    uint32_t mask;
    uint32_t bound;
} ds5_ring;

// True when capacity is a power of two, bound > 0 and capacity >= 2 * bound.
bool ds5_ring_geometry_ok(uint32_t capacity, uint32_t bound);
// Resets state and zeroes `capacity` samples. No other thread may use the ring. False on bad geometry.
bool ds5_ring_format(ds5_ring_state *state, _Atomic float *samples, uint32_t capacity, uint32_t bound);
// Builds a local view; capacity and bound must be the geometry the ring was formatted with.
// False on bad geometry (the view is left unusable).
bool ds5_ring_view(ds5_ring *r, ds5_ring_state *state, _Atomic float *samples, uint32_t capacity, uint32_t bound);

// Writer side. Appends n samples; when n > bound only the newest `bound` are stored (the rest count as
// written, so the reader drops them).
void ds5_ring_write(const ds5_ring *r, const float *src, uint32_t n);
// Total samples ever written (published). Any thread.
uint64_t ds5_ring_write_pos(const ds5_ring *r);

// Reader side. Samples queued for the reader, at most `bound`.
uint32_t ds5_ring_available(const ds5_ring *r);
// Copies up to n of the oldest queued samples (after dropping anything beyond `bound`). Returns the number
// copied; never zero-fills.
uint32_t ds5_ring_read(const ds5_ring *r, float *dst, uint32_t n);
// Discards every sample before absolute position pos, clamped to the write position (no-op if already past
// it); not counted as dropped.
void ds5_ring_skip_to(const ds5_ring *r, uint64_t pos);
// Total samples dropped by the reader because of the bound. Any thread.
uint64_t ds5_ring_dropped(const ds5_ring *r);
