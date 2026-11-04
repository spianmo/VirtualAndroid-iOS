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
#include <stddef.h>
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

struct AndroidPipeFuncs;  /* engine/qemu/include/hw/android/android_pipe.h */
struct AndroidPipeStream; /* idem */

/*
 * Engine entry points handed to libva_gfx, so the library never links
 * against the QEMU binary/framework (QEMU loads libva_gfx with dlopen and
 * resolves the va_gfx_* symbols with dlsym).
 */
typedef struct VaGfxEngineOps {
    void (*pipe_add_type)(const char *service_name, void *service_opaque,
                          const struct AndroidPipeFuncs *funcs);
    void (*pipe_host_close)(void *hwpipe);
    void (*pipe_host_signal_wake)(void *hwpipe, unsigned flags);
    /* Big QEMU lock, required around pipe_host_* from renderer threads. */
    void (*bql_lock)(void);
    void (*bql_unlock)(void);
    /* goldfish_sync device (guest sync fences for GL/Vulkan). */
    uint64_t (*sync_create_timeline)(void);
    int (*sync_create_fence)(uint64_t timeline, uint32_t point);
    void (*sync_timeline_inc)(uint64_t timeline, uint32_t count);
    void (*sync_destroy_timeline)(uint64_t timeline);
    /*
     * Guest asks the host to wait on a renderer sync object and then bump a
     * timeline; the engine forwards such requests to this callback.
     */
    void (*sync_register_trigger_wait)(void (*trigger_wait)(uint64_t glsync,
                                                            uint64_t thread,
                                                            uint64_t timeline));
    /*
     * (gfx, M4) Snapshot stream helpers used by the graphics pipes'
     * AndroidPipeFuncs.save/load: set them to android_pipe_stream_put_buffer /
     * android_pipe_stream_get_buffer. If either is NULL, the graphics pipes
     * register save/load = NULL (they are closed on load, as before M4).
     */
    void (*pipe_stream_put_buffer)(struct AndroidPipeStream *s, const void *buf,
                                   size_t len);
    size_t (*pipe_stream_get_buffer)(struct AndroidPipeStream *s, void *buf,
                                     size_t len);
} VaGfxEngineOps;

/* Call once, before the guest boots (after the android_pipe core is ready). */
int va_gfx_init(const VaGfxConfig *config, const VaGfxEngineOps *engine,
                VaGfxPresentFn present, void *opaque);

/* Registers the pipe services through engine->pipe_add_type(). */
void va_gfx_register_pipe_services(void);

/* The guest-visible renderer strings, for boot properties/logging. */
const char *va_gfx_renderer_string(void);

/*
 * (gfx addition) Max GLES version the host renderer offers the guest, valid
 * after va_gfx_init(). Use it for bootconfig androidboot.opengles.version =
 * (major << 16) | minor. Returns 0 on success.
 */
int va_gfx_get_gles_version(int *major, int *minor);

/*
 * ---- Snapshot (M4, see docs/SNAPSHOT.md) ----
 * The engine calls these from the QEMU main thread with the VM stopped and
 * the BQL held, as its own migration section that is ordered BEFORE the
 * goldfish pipe device:
 *   save: va_gfx_snapshot_save() runs before any graphics pipe's
 *         AndroidPipeFuncs.save();
 *   load: va_gfx_snapshot_load() runs before any graphics pipe's
 *         AndroidPipeFuncs.load(), into a freshly va_gfx_init()ed renderer
 *         that has not served a guest yet.
 * Renderer threads may be blocked waiting for the BQL (pipe wakes); the
 * implementation must not deadlock on that.
 * Small state goes through io (it lands in the migration stream). Bulk data
 * (color buffers, textures) may be written as files under aux_dir, which the
 * engine creates and keeps for exactly as long as the snapshot.
 * After a successful load, present the last guest frame again (the guest will
 * not repost until something changes). All return 0 on success, -1 on error;
 * a failed load leaves the renderer unusable (the engine then cold-boots).
 */
typedef struct VaGfxSnapshotIo {
    void *opaque;
    int (*write)(void *opaque, const void *buf, size_t len);
    int (*read)(void *opaque, void *buf, size_t len); /* exactly len bytes */
} VaGfxSnapshotIo;

int va_gfx_snapshot_save(const VaGfxSnapshotIo *io, const char *aux_dir);
int va_gfx_snapshot_load(const VaGfxSnapshotIo *io, const char *aux_dir);

void va_gfx_teardown(void);

#ifdef __cplusplus
}
#endif

#endif /* VA_GFX_H */
