/*
 * VirtualAndroid libva_gfx: AndroidPipeFuncs adapter registered with the
 * engine's goldfish pipe core (engine/qemu/include/hw/android/android_pipe.h,
 * used header-only; the engine's functions are reached via VaGfxEngineOps).
 */
#include "hw/android/android_pipe.h"
#include "va_gfx_internal.h"

#include <stddef.h>

_Static_assert(sizeof(AndroidPipeBuffer) == 2 * sizeof(void *),
               "AndroidPipeBuffer layout must be {data, size}");
_Static_assert(offsetof(AndroidPipeBuffer, size) == sizeof(void *),
               "AndroidPipeBuffer layout must be {data, size}");

static void *shim_init(void *hwpipe, void *service_opaque, const char *args)
{
    return vagfx_pipe_open(hwpipe, (const char *)service_opaque, args);
}

static void shim_close(void *pipe)
{
    vagfx_pipe_close((VaGfxPipe *)pipe);
}

static int shim_send(void *pipe, const AndroidPipeBuffer *buffers, int n)
{
    return vagfx_pipe_send((VaGfxPipe *)pipe, buffers, n);
}

static int shim_recv(void *pipe, AndroidPipeBuffer *buffers, int n)
{
    return vagfx_pipe_recv((VaGfxPipe *)pipe, buffers, n);
}

static unsigned shim_poll(void *pipe)
{
    return vagfx_pipe_poll((VaGfxPipe *)pipe);
}

static void shim_wake_on(void *pipe, int flags)
{
    vagfx_pipe_wake_on((VaGfxPipe *)pipe, flags);
}

static const AndroidPipeFuncs kVaGfxPipeFuncs = {
    .init = shim_init,
    .close = shim_close,
    .sendBuffers = shim_send,
    .recvBuffers = shim_recv,
    .poll = shim_poll,
    .wakeOn = shim_wake_on,
    /* No snapshot support yet: the engine closes these pipes on load. */
    .save = NULL,
    .load = NULL,
};

/*
 * Every graphics pipe the API 33 goldfish-opengl guest opens:
 *   opengles       HostConnection/QemuPipeStream (GLES, renderControl, Vulkan)
 *   GLProcessPipe  per-process resource tracking (ProcessPipe.cpp)
 *   refcount       gralloc colorbuffer refcounting (RefCountPipe feature)
 */
static const char *const kServices[] = { "opengles", "GLProcessPipe", "refcount" };

void vagfx_shim_register_services(const VaGfxEngineOps *engine)
{
    for (size_t i = 0; i < sizeof(kServices) / sizeof(kServices[0]); i++) {
        engine->pipe_add_type(kServices[i], (void *)kServices[i], &kVaGfxPipeFuncs);
    }
}
