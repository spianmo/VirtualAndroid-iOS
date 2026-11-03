/*
 * VirtualAndroid: drop-in loader for libva_gfx, for engine/qemu/hw/android/.
 * Copy ranchu_gfx.{c,h} there (owner: board) and add gfx/include to the
 * include path (va_gfx.h). See gfx/README.md.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef HW_ANDROID_RANCHU_GFX_H
#define HW_ANDROID_RANCHU_GFX_H

#include <stdbool.h>
#include "va_gfx.h"

typedef struct RanchuGfxOptions {
    const char *lib_path;   /* NULL: $VA_GFX_LIB, then next to the executable */
    int width, height, dpi, refresh_hz;
    const char *gles_backend; /* NULL = "angle" */
    bool enable_vulkan;
} RanchuGfxOptions;

/*
 * Machine init (after the pipe core and goldfish_sync exist, before the guest
 * runs): dlopen libva_gfx, create the renderer and register the opengles,
 * GLProcessPipe and refcount pipe services. |present| runs on a renderer
 * thread without the BQL (see VaGfxPresentFn in va_gfx.h).
 */
bool ranchu_gfx_init(const RanchuGfxOptions *opts, VaGfxPresentFn present, void *opaque);

/* Value for bootconfig androidboot.opengles.version, e.g. 196608 (GLES 3.0). */
int ranchu_gfx_opengles_version(void);

/* Renderer description for logs ("" before init). */
const char *ranchu_gfx_renderer(void);

void ranchu_gfx_teardown(void);

#endif /* HW_ANDROID_RANCHU_GFX_H */
