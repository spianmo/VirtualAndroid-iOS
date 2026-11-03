/*
 * VirtualAndroid: engine <-> host platform bridge.
 *
 * The "engine" is QEMU plus our Android devices/services running inside the
 * app process. The "platform" is the iOS app (Swift) or the macOS test
 * harness (host/macos). The platform installs callbacks before starting the
 * engine and pushes events with the va_engine_* functions.
 *
 * Threading:
 *  - Callbacks are invoked from engine threads (usually the QEMU main loop
 *    or a vCPU thread). They must not block for long; hop to your own queue.
 *  - va_engine_* functions are thread-safe and may be called from any
 *    thread; the engine queues them into the QEMU main loop.
 *
 * Units follow Android conventions (SI, m/s^2, rad/s, uT, hPa, lux, cm).
 */
#ifndef VA_HOST_H
#define VA_HOST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VA_HOST_ABI_VERSION 1

typedef enum VaSensorType {
    VA_SENSOR_ACCELERATION = 0,   /* m/s^2, x y z, Android device axes */
    VA_SENSOR_GYROSCOPE,          /* rad/s */
    VA_SENSOR_MAGNETIC_FIELD,     /* uT */
    VA_SENSOR_ORIENTATION,        /* degrees: azimuth pitch roll */
    VA_SENSOR_TEMPERATURE,        /* Celsius */
    VA_SENSOR_PROXIMITY,          /* cm */
    VA_SENSOR_LIGHT,              /* lux */
    VA_SENSOR_PRESSURE,           /* hPa */
    VA_SENSOR_HUMIDITY,           /* % */
    VA_SENSOR_GRAVITY,            /* m/s^2 */
    VA_SENSOR_LINEAR_ACCELERATION,/* m/s^2 */
    VA_SENSOR_ROTATION_VECTOR,    /* unit quaternion x y z w */
    VA_SENSOR_COUNT
} VaSensorType;

typedef enum VaGuestState {
    VA_GUEST_STOPPED = 0,
    VA_GUEST_BOOTING,
    VA_GUEST_BOOT_COMPLETED,      /* sys.boot_completed=1 */
    VA_GUEST_PAUSED,
    VA_GUEST_SHUTDOWN,
} VaGuestState;

typedef struct VaBatteryState {
    bool ac_online;
    bool charging;
    int capacity_percent;         /* 0..100 */
    int voltage_mv;
    int temperature_decic;        /* tenths of a degree Celsius */
    bool present;
} VaBatteryState;

typedef struct VaLocation {
    double latitude_deg;
    double longitude_deg;
    double altitude_m;
    float speed_mps;
    float bearing_deg;
    float horizontal_accuracy_m;
    int64_t unix_time_ms;
} VaLocation;

typedef enum VaCameraFacing {
    VA_CAMERA_BACK = 0,
    VA_CAMERA_FRONT = 1,
} VaCameraFacing;

typedef struct VaCameraInfo {
    char name[32];
    VaCameraFacing facing;
    int orientation_deg;
    /* Supported frame sizes, terminated by a 0x0 entry. */
    struct { int width, height; } sizes[16];
} VaCameraInfo;

/* Frames are delivered as NV21 (YUV420SP, VU interleaved) unless noted. */
typedef struct VaCameraFrame {
    int width;
    int height;
    const uint8_t *nv21;          /* width*height*3/2 bytes */
    int64_t timestamp_ns;
} VaCameraFrame;

typedef struct VaTouchPoint {
    int32_t slot;                 /* 0..9, stable while the finger is down */
    bool down;                    /* false = this slot was lifted */
    float x;                      /* 0..1 in guest display space */
    float y;                      /* 0..1 */
    float pressure;               /* 0..1 */
} VaTouchPoint;

typedef struct VaHostCallbacks {
    uint32_t abi_version;         /* = VA_HOST_ABI_VERSION */
    void *opaque;

    void (*log)(void *opaque, int level /* 0=debug 1=info 2=warn 3=error */,
                const char *msg);
    void (*guest_state_changed)(void *opaque, VaGuestState state);

    /* Sensors: the guest asks to start/stop; push samples with
     * va_engine_sensor_event(). delay_ms is the requested period. */
    void (*sensor_set_enabled)(void *opaque, VaSensorType type, bool enabled,
                               uint32_t delay_ms);
    /* Bitmask (1 << VaSensorType) of sensors the platform can provide. */
    uint32_t (*sensor_available_mask)(void *opaque);

    /* GNSS: start/stop delivery of va_engine_location_update(). */
    void (*location_set_enabled)(void *opaque, bool enabled);

    /* Battery: polled by the goldfish battery device. Return false if
     * unknown (engine then reports AC power, 100%). */
    bool (*battery_get)(void *opaque, VaBatteryState *out);

    /* Clipboard: the guest copied text. */
    void (*clipboard_from_guest)(void *opaque, const char *utf8, size_t len);

    /* Camera. camera_count may return 0 to hide all cameras. */
    int (*camera_count)(void *opaque);
    bool (*camera_info)(void *opaque, int index, VaCameraInfo *out);
    bool (*camera_start)(void *opaque, int index, int width, int height);
    void (*camera_stop)(void *opaque, int index);
    /* Copy the latest frame into dst (NV21, width*height*3/2). */
    bool (*camera_read_frame)(void *opaque, int index, uint8_t *dst,
                              size_t dst_len, int64_t *timestamp_ns);

    /* Haptics, if a guest path for it exists. */
    void (*vibrate)(void *opaque, uint32_t duration_ms);

    /* Microphone: the engine pulls PCM16 interleaved frames.
     * Return frames actually written (may be 0). */
    bool (*mic_start)(void *opaque, int sample_rate, int channels);
    void (*mic_stop)(void *opaque);
    size_t (*mic_read)(void *opaque, int16_t *dst, size_t frames);

    /* Speaker: the engine pushes PCM16 interleaved frames. */
    bool (*speaker_start)(void *opaque, int sample_rate, int channels);
    void (*speaker_stop)(void *opaque);
    size_t (*speaker_write)(void *opaque, const int16_t *src, size_t frames);
} VaHostCallbacks;

/* Install before starting the engine. The struct is copied. */
void va_host_set_callbacks(const VaHostCallbacks *callbacks);

/* ---- platform -> engine (thread-safe) ---- */
void va_engine_sensor_event(VaSensorType type, const float *values, int count,
                            int64_t timestamp_ns);
void va_engine_location_update(const VaLocation *location);
void va_engine_battery_changed(void);
void va_engine_clipboard_from_host(const char *utf8, size_t len);
void va_engine_touch(const VaTouchPoint *points, int count);
/* Linux input keycodes (KEY_BACK=158, KEY_HOMEPAGE=172, KEY_POWER=116 ...). */
void va_engine_key(uint32_t linux_keycode, bool down);
void va_engine_set_display_rotation(int degrees /* 0 90 180 270 */);

#ifdef __cplusplus
}
#endif

#endif /* VA_HOST_H */
