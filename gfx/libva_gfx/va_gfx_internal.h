/*
 * VirtualAndroid libva_gfx: internal glue between the engine-facing C shim
 * (va_gfx_pipe_shim.c, compiled against QEMU's android_pipe.h) and the
 * gfxstream/aemu-facing C++ side (va_gfx.cpp, compiled against aemu's
 * android_pipe_*.h). The two pipe headers define identically laid out but
 * conflicting types, so they never meet in one translation unit; buffers
 * cross this boundary as `const void *` (both are {uint8_t *data; size_t size}).
 */
#ifndef VA_GFX_INTERNAL_H
#define VA_GFX_INTERNAL_H

#include "va_gfx.h"

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VaGfxPipe VaGfxPipe;

/* Implemented in va_gfx.cpp. All are called with the BQL held. */
VaGfxPipe *vagfx_pipe_open(void *hwpipe, const char *service, const char *args);
void vagfx_pipe_close(VaGfxPipe *pipe);
int vagfx_pipe_send(VaGfxPipe *pipe, const void *buffers, int num_buffers);
int vagfx_pipe_recv(VaGfxPipe *pipe, void *buffers, int num_buffers);
unsigned vagfx_pipe_poll(VaGfxPipe *pipe);
void vagfx_pipe_wake_on(VaGfxPipe *pipe, int flags);

/* Implemented in va_gfx_pipe_shim.c. */
void vagfx_shim_register_services(const VaGfxEngineOps *engine);

/* Implemented in va_gfx_present.cpp (Apple: IOSurface frames). */
void vagfx_present_init(int width, int height, VaGfxPresentFn fn, void *opaque);
/* Readback path: copy CPU pixels into a pooled IOSurface and present it. */
void vagfx_present_frame(int width, int height, int ydir, const unsigned char *bgra);
/* Zero-copy path: get a free pooled IOSurface (an IOSurfaceRef, owned by the
 * pool; NULL if all are held), render into it, then submit it. |generation|
 * changes whenever the pool is recreated (cached GPU objects must go). */
void *vagfx_present_acquire(int width, int height, uint64_t *generation);
void vagfx_present_submit(void *iosurface, int width, int height);
/* The surface's current retain count is its idle level (e.g. ANGLE retains it). */
void vagfx_present_mark_idle(void *iosurface);
void vagfx_present_teardown(void);

/* Implemented in va_gfx_present_gl.cpp (ANGLE zero-copy presentation). */
bool vagfx_present_gl_enable(const char *angle_glesv2_path);
void vagfx_present_gl_disable(void);

/* Implemented in va_gfx.cpp: switch to the readback path (from any thread). */
void vagfx_request_readback_fallback(void);

#ifdef __cplusplus
}
#endif

#endif /* VA_GFX_INTERNAL_H */
