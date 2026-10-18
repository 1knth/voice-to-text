#include "WhisperCapture.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <limits.h>
#include <math.h>

static _Atomic(uint32_t) latest_level_bits;

int whisper_level_is_lock_free(void) {
    return atomic_is_lock_free(&latest_level_bits);
}

void whisper_level_store(float level) {
    union { float value; uint32_t bits; } encoded = { .value = level };
    atomic_store_explicit(&latest_level_bits, encoded.bits, memory_order_relaxed);
}

float whisper_level_load(void) {
    union { float value; uint32_t bits; } encoded = { .bits = atomic_load_explicit(&latest_level_bits, memory_order_relaxed) };
    return encoded.value;
}

double whisper_level_step(double current, double target, double delta) {
    if (delta < 0) delta = 0;
    if (delta > 0.05) delta = 0.05;
    const double time_constant = target > current ? 0.055 : 0.14;
    return current + (target - current) * (1.0 - exp(-delta / time_constant));
}

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
