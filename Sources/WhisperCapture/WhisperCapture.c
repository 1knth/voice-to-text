#include "WhisperCapture.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <limits.h>

struct WhisperCaptureRing {
    uint32_t capacity;
    _Atomic(uint32_t) read_position;
    _Atomic(uint32_t) write_position;
};

WhisperCaptureRing *whisper_capture_create(uint32_t capacity) {
    // Power of two keeps slot indexing continuous across uint32 counter wrap.
    if (!capacity || (capacity & (capacity - 1)) || capacity > INT32_MAX) return NULL;
    WhisperCaptureRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    ring->capacity = capacity;
    atomic_init(&ring->read_position, 0);
    atomic_init(&ring->write_position, 0);
    // Never put an implementation's hidden atomic lock on the audio thread.
    if (!atomic_is_lock_free(&ring->read_position) || !atomic_is_lock_free(&ring->write_position)) {
        free(ring); return NULL;
    }
    return ring;
}
void whisper_capture_destroy(WhisperCaptureRing *ring) { free(ring); }
int32_t whisper_capture_begin_write(WhisperCaptureRing *ring) {
    uint32_t write = atomic_load_explicit(&ring->write_position, memory_order_relaxed);
    uint32_t read = atomic_load_explicit(&ring->read_position, memory_order_acquire);
    if ((uint32_t)(write - read) >= ring->capacity) return -1;
    return (int32_t)(write & (ring->capacity - 1));
}
void whisper_capture_commit_write(WhisperCaptureRing *ring) {
    uint32_t write = atomic_load_explicit(&ring->write_position, memory_order_relaxed);
    atomic_store_explicit(&ring->write_position, write + 1, memory_order_release);
}
int32_t whisper_capture_begin_read(WhisperCaptureRing *ring) {
    uint32_t read = atomic_load_explicit(&ring->read_position, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&ring->write_position, memory_order_acquire);
    if (read == write) return -1;
    return (int32_t)(read & (ring->capacity - 1));
}
void whisper_capture_commit_read(WhisperCaptureRing *ring) {
    uint32_t read = atomic_load_explicit(&ring->read_position, memory_order_relaxed);
    atomic_store_explicit(&ring->read_position, read + 1, memory_order_release);
}
