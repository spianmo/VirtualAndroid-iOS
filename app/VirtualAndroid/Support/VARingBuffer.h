// Lock-free single-producer/single-consumer ring buffer of int16 samples.
// Used between engine threads (speaker_write / mic_read) and real-time
// audio threads, where Swift locks are not appropriate.
#ifndef VA_RING_BUFFER_H
#define VA_RING_BUFFER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VARingBuffer VARingBuffer;

/* capacity is in samples (not frames); rounded up to a power of two. */
VARingBuffer *va_ring_create(size_t capacity_samples);
void va_ring_destroy(VARingBuffer *ring);
/* Producer side: returns samples written (<= count). */
size_t va_ring_write(VARingBuffer *ring, const int16_t *src, size_t count);
/* Consumer side: returns samples read (<= count). */
size_t va_ring_read(VARingBuffer *ring, int16_t *dst, size_t count);
size_t va_ring_available(const VARingBuffer *ring);   /* readable samples */
size_t va_ring_space(const VARingBuffer *ring);       /* writable samples */
/* Only safe while neither side is active. */
void va_ring_reset(VARingBuffer *ring);

#ifdef __cplusplus
}
#endif
#endif
