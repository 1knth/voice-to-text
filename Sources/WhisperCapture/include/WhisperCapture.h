#ifndef WHISPER_CAPTURE_H
#define WHISPER_CAPTURE_H
#include <stdint.h>

// First-party bounded single-producer/single-consumer slot queue.
// Producer fills a slot before publishing; consumer releases only after reading.
// No allocation, locks, waits or audio data inside queue operations.
typedef struct WhisperCaptureRing WhisperCaptureRing;
WhisperCaptureRing *whisper_capture_create(uint32_t capacity);
void whisper_capture_destroy(WhisperCaptureRing *ring);
int32_t whisper_capture_begin_write(WhisperCaptureRing *ring);
void whisper_capture_commit_write(WhisperCaptureRing *ring);
int32_t whisper_capture_begin_read(WhisperCaptureRing *ring);
void whisper_capture_commit_read(WhisperCaptureRing *ring);
// Lock-free latest-value mailbox for scalar UI telemetry from the audio producer.
int whisper_level_is_lock_free(void);
void whisper_level_store(float level);
float whisper_level_load(void);
// Frame-rate-independent asymmetric response, with long pauses capped at 50 ms.
double whisper_level_step(double current, double target, double delta);
#endif
