/*
 * VirtualAndroid: development "platform plugin" interface (macOS only).
 *
 * On iOS the app links the engine and calls va_host_set_callbacks() and the
 * va_engine_* functions directly. A standalone qemu-system-aarch64 on macOS
 * has no platform, so for development the engine can load one at startup:
 *
 *   VA_HOST_PLATFORM=/path/to/libva_host_macos.dylib qemu-system-aarch64 ...
 *
 * After machine init the engine dlopen()s the library and calls its
 * va_platform_attach() with the engine entry points (QEMU doesn't export
 * its symbols, so they are passed as a table). The plugin then installs
 * callbacks through api->set_callbacks() and pushes events with the other
 * members, from any thread, exactly like the iOS app does.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef VA_HOST_PLUGIN_H
#define VA_HOST_PLUGIN_H

#include "va_host.h"

#ifdef __cplusplus
extern "C" {
#endif

#define VA_ENGINE_API_VERSION 1

typedef struct VaEngineApi {
    uint32_t version;             /* VA_ENGINE_API_VERSION */
    void (*set_callbacks)(const VaHostCallbacks *callbacks);
    void (*sensor_event)(VaSensorType type, const float *values, int count,
                         int64_t timestamp_ns);
    void (*location_update)(const VaLocation *location);
    void (*battery_changed)(void);
    void (*clipboard_from_host)(const char *utf8, size_t len);
    void (*touch)(const VaTouchPoint *points, int count);
    void (*key)(uint32_t linux_keycode, bool down);
    void (*set_display_rotation)(int degrees);
    /* Development extras (not in va_host.h). */
    void (*fingerprint_touch)(int finger_id);
} VaEngineApi;

#define VA_PLATFORM_ATTACH_SYMBOL "va_platform_attach"
typedef void (*VaPlatformAttachFn)(const VaEngineApi *api);

#ifdef __cplusplus
}
#endif

#endif /* VA_HOST_PLUGIN_H */
