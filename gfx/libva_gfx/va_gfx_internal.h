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
void vagfx_present_frame(int width, int height, int ydir, const unsigned char *bgra);
void vagfx_present_teardown(void);

#ifdef __cplusplus
}
#endif

#endif /* VA_GFX_INTERNAL_H */
