/*
 * VirtualAndroid: drop-in loader for libva_gfx (see ranchu_gfx.h).
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qemu/main-loop.h"
#include "hw/android/android_pipe.h"
#include "hw/android/goldfish_sync.h"
#include "ranchu_gfx.h"

#include <dlfcn.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

static struct {
    void *lib;
    int (*init)(const VaGfxConfig *, const VaGfxEngineOps *, VaGfxPresentFn, void *);
    void (*register_pipe_services)(void);
    const char *(*renderer_string)(void);
    int (*get_gles_version)(int *, int *);
    void (*teardown)(void);
    int gles_version;
} s_gfx;

static void ranchu_gfx_bql_lock(void)
{
    bql_lock();
}

static void ranchu_gfx_bql_unlock(void)
{
    bql_unlock();
}

static void *ranchu_gfx_dlopen(const char *explicit_path)
{
    const char *env = getenv("VA_GFX_LIB");
    char exe[PATH_MAX] = "";
    char *dir = NULL;
    void *h = NULL;

    if (explicit_path) {
        return dlopen(explicit_path, RTLD_NOW | RTLD_LOCAL);
    }
    if (env && *env) {
        return dlopen(env, RTLD_NOW | RTLD_LOCAL);
    }
#ifdef __APPLE__
    {
        uint32_t sz = sizeof(exe);
        if (_NSGetExecutablePath(exe, &sz) == 0) {
            dir = g_path_get_dirname(exe);
        }
    }
#endif
    if (dir) {
        /* iOS app: App.app/Frameworks/; macOS: next to the binary. */
        const char *rel[] = {
            "Frameworks/va_gfx.framework/va_gfx",
            "../Frameworks/va_gfx.framework/va_gfx",
            "libva_gfx.dylib",
            "../lib/libva_gfx.dylib",
        };
        for (size_t i = 0; i < G_N_ELEMENTS(rel) && !h; i++) {
            g_autofree char *p = g_build_filename(dir, rel[i], NULL);
            if (access(p, R_OK) == 0) {
                h = dlopen(p, RTLD_NOW | RTLD_LOCAL);
            }
        }
        g_free(dir);
    }
    if (!h) {
        h = dlopen("libva_gfx.dylib", RTLD_NOW | RTLD_LOCAL);
    }
    return h;
}

bool ranchu_gfx_init(const RanchuGfxOptions *opts, VaGfxPresentFn present, void *opaque)
{
    static const VaGfxEngineOps ops = {
        .pipe_add_type = android_pipe_add_type,
        .pipe_host_close = android_pipe_host_close,
        .pipe_host_signal_wake = android_pipe_host_signal_wake,
        .bql_lock = ranchu_gfx_bql_lock,
        .bql_unlock = ranchu_gfx_bql_unlock,
        .sync_create_timeline = goldfish_sync_create_timeline,
        .sync_create_fence = goldfish_sync_create_fence,
        .sync_timeline_inc = goldfish_sync_timeline_inc,
        .sync_destroy_timeline = goldfish_sync_destroy_timeline,
        .sync_register_trigger_wait = goldfish_sync_register_trigger_wait,
    };
    VaGfxConfig cfg = {
        .display_width = opts->width,
        .display_height = opts->height,
        .display_dpi = opts->dpi,
        .refresh_hz = opts->refresh_hz,
        .gles_backend = opts->gles_backend ? opts->gles_backend : "angle",
        .enable_vulkan = opts->enable_vulkan,
    };
    int maj = 2, min = 0;

    if (s_gfx.lib) {
        return true;
    }
    s_gfx.lib = ranchu_gfx_dlopen(opts->lib_path);
    if (!s_gfx.lib) {
        error_report("ranchu: cannot load libva_gfx: %s", dlerror());
        return false;
    }
    s_gfx.init = dlsym(s_gfx.lib, "va_gfx_init");
    s_gfx.register_pipe_services = dlsym(s_gfx.lib, "va_gfx_register_pipe_services");
    s_gfx.renderer_string = dlsym(s_gfx.lib, "va_gfx_renderer_string");
    s_gfx.get_gles_version = dlsym(s_gfx.lib, "va_gfx_get_gles_version");
    s_gfx.teardown = dlsym(s_gfx.lib, "va_gfx_teardown");
    if (!s_gfx.init || !s_gfx.register_pipe_services || !s_gfx.renderer_string ||
        !s_gfx.teardown) {
        error_report("ranchu: libva_gfx is missing va_gfx_* entry points");
        dlclose(s_gfx.lib);
        memset(&s_gfx, 0, sizeof(s_gfx));
        return false;
    }
    if (s_gfx.init(&cfg, &ops, present, opaque) != 0) {
        error_report("ranchu: va_gfx_init failed (no host GPU renderer)");
        return false;
    }
    s_gfx.register_pipe_services();
    if (s_gfx.get_gles_version) {
        s_gfx.get_gles_version(&maj, &min);
    }
    s_gfx.gles_version = (maj << 16) | min;
    info_report("ranchu: host renderer %s, guest GLES %d.%d", s_gfx.renderer_string(), maj, min);
    return true;
}

int ranchu_gfx_opengles_version(void)
{
    return s_gfx.gles_version ? s_gfx.gles_version : 0x30000;
}

const char *ranchu_gfx_renderer(void)
{
    return s_gfx.renderer_string ? s_gfx.renderer_string() : "";
}

void ranchu_gfx_teardown(void)
{
    if (s_gfx.teardown) {
        s_gfx.teardown();
    }
}
