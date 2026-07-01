/*
 * buffer_pool.c — Zero-allocation, cache-line-aligned frame buffer pool.
 *
 * A fixed array of buffers guarded by per-buffer atomic in-use flags. Producers
 * acquire() (non-blocking; returns NULL when drained so the caller drops the
 * frame instead of stalling the camera thread) and consumers release(). No
 * allocation happens on the hot path, so frame delivery never touches the Dart
 * garbage collector.
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#include "camera_pro_core.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define CAMERA_PRO_POOL_MAX 64
#define CAMERA_PRO_ALIGN    64  /* cache line, good for NEON/SSE loads */

typedef struct {
    uint8_t*   data;
    int32_t    capacity;
    atomic_int in_use;   /* 0 = free, 1 = handed out */
} pool_buffer_t;

struct camera_pro_buffer_pool {
    pool_buffer_t buffers[CAMERA_PRO_POOL_MAX];
    int32_t       count;
    int32_t       buffer_size;
};

/* Round n up to the next multiple of `align` (align must be a power of two). */
static int32_t round_up(int32_t n, int32_t align) {
    return (n + align - 1) & ~(align - 1);
}

camera_pro_buffer_pool_t*
camera_pro_buffer_pool_create(int32_t buffer_size, int32_t buffer_count) {
    if (buffer_size <= 0 || buffer_count <= 0 || buffer_count > CAMERA_PRO_POOL_MAX) {
        return NULL;
    }

    camera_pro_buffer_pool_t* pool =
        (camera_pro_buffer_pool_t*)calloc(1, sizeof(camera_pro_buffer_pool_t));
    if (!pool) return NULL;

    pool->count = buffer_count;
    pool->buffer_size = round_up(buffer_size, CAMERA_PRO_ALIGN);

    for (int32_t i = 0; i < buffer_count; i++) {
        /* aligned_alloc requires size to be a multiple of the alignment. */
        pool->buffers[i].data = (uint8_t*)aligned_alloc(CAMERA_PRO_ALIGN, (size_t)pool->buffer_size);
        if (!pool->buffers[i].data) {
            /* Roll back partial allocation. */
            for (int32_t j = 0; j < i; j++) free(pool->buffers[j].data);
            free(pool);
            return NULL;
        }
        pool->buffers[i].capacity = pool->buffer_size;
        atomic_store_explicit(&pool->buffers[i].in_use, 0, memory_order_relaxed);
    }
    return pool;
}

uint8_t*
camera_pro_buffer_pool_acquire(camera_pro_buffer_pool_t* pool, int32_t* out_size) {
    if (!pool) return NULL;
    for (int32_t i = 0; i < pool->count; i++) {
        int expected = 0;
        if (atomic_compare_exchange_strong_explicit(
                &pool->buffers[i].in_use, &expected, 1,
                memory_order_acquire, memory_order_relaxed)) {
            if (out_size) *out_size = pool->buffers[i].capacity;
            return pool->buffers[i].data;
        }
    }
    /* Pool drained — the caller should drop this frame. */
    if (out_size) *out_size = 0;
    return NULL;
}

void
camera_pro_buffer_pool_release(camera_pro_buffer_pool_t* pool, uint8_t* buffer) {
    if (!pool || !buffer) return;
    for (int32_t i = 0; i < pool->count; i++) {
        if (pool->buffers[i].data == buffer) {
            atomic_store_explicit(&pool->buffers[i].in_use, 0, memory_order_release);
            return;
        }
    }
}

int32_t
camera_pro_buffer_pool_available(camera_pro_buffer_pool_t* pool) {
    if (!pool) return 0;
    int32_t free_count = 0;
    for (int32_t i = 0; i < pool->count; i++) {
        if (atomic_load_explicit(&pool->buffers[i].in_use, memory_order_relaxed) == 0) {
            free_count++;
        }
    }
    return free_count;
}

int32_t
camera_pro_buffer_pool_capacity(camera_pro_buffer_pool_t* pool) {
    return pool ? pool->count : 0;
}

void
camera_pro_buffer_pool_destroy(camera_pro_buffer_pool_t* pool) {
    if (!pool) return;
    for (int32_t i = 0; i < pool->count; i++) {
        free(pool->buffers[i].data);
    }
    free(pool);
}
