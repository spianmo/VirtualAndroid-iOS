#include "VARingBuffer.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct VARingBuffer {
    int16_t *data;
    size_t mask;
    _Atomic size_t head; /* next write index (producer) */
    _Atomic size_t tail; /* next read index (consumer) */
};

VARingBuffer *va_ring_create(size_t capacity)
{
    size_t cap = 1;
    while (cap < capacity) {
        cap <<= 1;
    }
    VARingBuffer *ring = calloc(1, sizeof(*ring));
    if (!ring) {
        return NULL;
    }
    ring->data = calloc(cap, sizeof(int16_t));
    if (!ring->data) {
        free(ring);
        return NULL;
    }
    ring->mask = cap - 1;
    atomic_init(&ring->head, 0);
    atomic_init(&ring->tail, 0);
    return ring;
}

void va_ring_destroy(VARingBuffer *ring)
{
    if (ring) {
        free(ring->data);
        free(ring);
    }
}

size_t va_ring_available(const VARingBuffer *ring)
{
    size_t head = atomic_load_explicit(&((VARingBuffer *)ring)->head, memory_order_acquire);
    size_t tail = atomic_load_explicit(&((VARingBuffer *)ring)->tail, memory_order_acquire);
    return head - tail;
}

size_t va_ring_space(const VARingBuffer *ring)
{
    return ring->mask + 1 - va_ring_available(ring);
}

size_t va_ring_write(VARingBuffer *ring, const int16_t *src, size_t count)
{
    size_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    size_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    size_t space = ring->mask + 1 - (head - tail);
    if (count > space) {
        count = space;
    }
    size_t start = head & ring->mask;
    size_t first = ring->mask + 1 - start;
    if (first > count) {
        first = count;
    }
    memcpy(ring->data + start, src, first * sizeof(int16_t));
    memcpy(ring->data, src + first, (count - first) * sizeof(int16_t));
    atomic_store_explicit(&ring->head, head + count, memory_order_release);
    return count;
}

size_t va_ring_read(VARingBuffer *ring, int16_t *dst, size_t count)
{
    size_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    size_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    size_t avail = head - tail;
    if (count > avail) {
        count = avail;
    }
    size_t start = tail & ring->mask;
    size_t first = ring->mask + 1 - start;
    if (first > count) {
        first = count;
    }
    memcpy(dst, ring->data + start, first * sizeof(int16_t));
    memcpy(dst + first, ring->data, (count - first) * sizeof(int16_t));
    atomic_store_explicit(&ring->tail, tail + count, memory_order_release);
    return count;
}

void va_ring_reset(VARingBuffer *ring)
{
    atomic_store(&ring->head, 0);
    atomic_store(&ring->tail, 0);
}
