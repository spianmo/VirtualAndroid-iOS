/*
 * VirtualAndroid: host GPU renderer (gfxstream) wrapper.
 *
 * libva_gfx hosts the gfxstream renderer and registers the goldfish pipe
 * services the guest's emulation GLES/Vulkan drivers connect to
 * ("opengles", "GLProcessPipe", "refcount", ...) through the AndroidPipe ABI
 * in engine/qemu/include/hw/android/android_pipe.h.
 *
 * Backends: macOS = ANGLE(Metal) or native CGL for GLES, MoltenVK for Vulkan;
 *           iOS   = ANGLE(Metal) for GLES, MoltenVK for Vulkan.
 */
#ifndef VA_GFX_H
#define VA_GFX_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VaGfxConfig {
    int display_width;            /* guest display, pixels (e.g. 1080) */
    int display_height;           /* e.g. 2340 */
    int display_dpi;              /* e.g. 440 */
    int refresh_hz;               /* e.g. 60 */
    const char *gles_backend;     /* "angle" (default) or "native" (macOS CGL) */
    bool enable_vulkan;
} VaGfxConfig;

/*
 * A composed guest frame. On Apple platforms iosurface is an IOSurfaceRef
 * (retained for the duration of the callback; CFRetain it to keep it).
 */
typedef struct VaGfxFrame {
    void *iosurface;
    int width;
    int height;
    int rotation_deg;
    uint64_t frame_number;
} VaGfxFrame;

typedef void (*VaGfxPresentFn)(void *opaque, const VaGfxFrame *frame);

/* Call once, before the guest boots (after android_pipe core is ready). */
int va_gfx_init(const VaGfxConfig *config, VaGfxPresentFn present, void *opaque);

/* Registers the pipe services with android_pipe_add_type(). */
void va_gfx_register_pipe_services(void);

/* The guest-visible renderer strings, for boot properties/logging. */
const char *va_gfx_renderer_string(void);

void va_gfx_teardown(void);

#ifdef __cplusplus
}
#endif

#endif /* VA_GFX_H */
