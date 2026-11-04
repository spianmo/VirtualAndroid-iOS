/*
 * VirtualAndroid: macOS development platform (VaHostCallbacks).
 *
 * Built as libva_host_macos.dylib and loaded by the engine with
 *   VA_HOST_PLATFORM=/path/libva_host_macos.dylib qemu-system-aarch64 ...
 * (see include/va_host_plugin.h). It stands in for the iOS app:
 *  - sensors: device lying still and upright (the Android emulator's
 *    at-rest values), streamed at the rate the guest asks for;
 *  - GNSS: a fixed location (VA_MAC_LOCATION="lat,lon[,alt]", default
 *    Googleplex), once per second while the guest listens;
 *  - battery: the Mac's real battery through IOKit (AC + 100% on desktops);
 *  - camera: none, or a synthetic 640x480 / 320x240 colour-bar camera with
 *    VA_MAC_FAKE_CAMERA=1;
 *  - clipboard: guest copies are logged (and put on the macOS pasteboard
 *    with VA_MAC_PASTEBOARD=1);
 *  - control socket VA_MAC_CONTROL=/path.sock, one command per line:
 *      clip <text>                 host clipboard -> guest
 *      geo <lat> <lon> [<alt>]     move the fixed location
 *      sensor <type> <v0> [v1 v2]  type: accel gyro mag orient temp prox
 *                                  light pressure humidity
 *      finger <id> | finger off    fingerprint sensor
 *      key <linux keycode>         press + release
 *      battery                     re-poll the battery now
 *    each answered with "ok" or "error: ...".
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>

#include "va_host_plugin.h"

static const VaEngineApi *s_api;
static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;

/* Sensor state (protected by s_lock). */
static float s_values[VA_SENSOR_COUNT][4];
static int s_counts[VA_SENSOR_COUNT];
static bool s_enabled[VA_SENSOR_COUNT];
static uint32_t s_delay_ms[VA_SENSOR_COUNT];
static int64_t s_next_ns[VA_SENSOR_COUNT];

static bool s_location_on;
static VaLocation s_location;
static int64_t s_next_location_ns;

static bool s_fake_camera;
static bool s_camera_on;
static int s_cam_w, s_cam_h;
static uint32_t s_cam_frame;

#define LOG(...) plat_log(1, __VA_ARGS__)
static void plat_log(int level, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));
static void plat_log(int level, const char *fmt, ...)
{
    static const char *const names[] = { "D", "I", "W", "E" };
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "va-macos[%s]: ", names[level & 3]);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

static int64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int64_t unix_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ---- callbacks ---- */

static void cb_log(void *o, int level, const char *msg)
{
    (void)o;
    if (level >= 1 || getenv("VA_SERVICES_DEBUG")) {
        plat_log(level, "engine: %s", msg);
    }
}

static void cb_guest_state(void *o, VaGuestState st)
{
    (void)o;
    static const char *const names[] = { "stopped", "booting",
                                         "boot-completed", "paused",
                                         "shutdown" };
    LOG("guest state: %s", (unsigned)st < 5 ? names[st] : "?");
}

static void cb_sensor_set_enabled(void *o, VaSensorType t, bool on,
                                  uint32_t delay_ms)
{
    (void)o;
    if ((unsigned)t >= VA_SENSOR_COUNT) {
        return;
    }
    pthread_mutex_lock(&s_lock);
    s_enabled[t] = on;
    s_delay_ms[t] = delay_ms < 5 ? 5 : delay_ms;
    s_next_ns[t] = 0;
    pthread_mutex_unlock(&s_lock);
    LOG("sensor %d %s (%u ms)", t, on ? "on" : "off", delay_ms);
}

static uint32_t cb_sensor_mask(void *o)
{
    (void)o;
    return (1u << VA_SENSOR_ACCELERATION) | (1u << VA_SENSOR_GYROSCOPE) |
           (1u << VA_SENSOR_MAGNETIC_FIELD) | (1u << VA_SENSOR_ORIENTATION) |
           (1u << VA_SENSOR_TEMPERATURE) | (1u << VA_SENSOR_PROXIMITY) |
           (1u << VA_SENSOR_LIGHT) | (1u << VA_SENSOR_PRESSURE) |
           (1u << VA_SENSOR_HUMIDITY);
}

static void cb_location_enabled(void *o, bool on)
{
    (void)o;
    pthread_mutex_lock(&s_lock);
    s_location_on = on;
    s_next_location_ns = 0;
    pthread_mutex_unlock(&s_lock);
    LOG("location %s", on ? "on" : "off");
}

static bool cb_battery_get(void *o, VaBatteryState *out)
{
    (void)o;
    bool found = false;
    memset(out, 0, sizeof(*out));
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    CFArrayRef list = info ? IOPSCopyPowerSourcesList(info) : NULL;
    if (list) {
        for (CFIndex i = 0; i < CFArrayGetCount(list) && !found; i++) {
            CFDictionaryRef d = IOPSGetPowerSourceDescription(
                info, CFArrayGetValueAtIndex(list, i));
            if (!d) {
                continue;
            }
            CFStringRef type = CFDictionaryGetValue(d, CFSTR(kIOPSTypeKey));
            if (!type || CFStringCompare(type, CFSTR(kIOPSInternalBatteryType),
                                         0) != kCFCompareEqualTo) {
                continue;
            }
            int cur = 0, max = 100;
            CFNumberRef n = CFDictionaryGetValue(d,
                                                 CFSTR(kIOPSCurrentCapacityKey));
            if (n) {
                CFNumberGetValue(n, kCFNumberIntType, &cur);
            }
            n = CFDictionaryGetValue(d, CFSTR(kIOPSMaxCapacityKey));
            if (n) {
                CFNumberGetValue(n, kCFNumberIntType, &max);
            }
            CFStringRef state = CFDictionaryGetValue(
                d, CFSTR(kIOPSPowerSourceStateKey));
            CFBooleanRef charging = CFDictionaryGetValue(
                d, CFSTR(kIOPSIsChargingKey));
            out->present = true;
            out->capacity_percent = max > 0 ? cur * 100 / max : cur;
            out->ac_online = state &&
                CFStringCompare(state, CFSTR(kIOPSACPowerValue), 0) ==
                    kCFCompareEqualTo;
            out->charging = charging && CFBooleanGetValue(charging);
            out->voltage_mv = 3870;
            out->temperature_decic = 250;
            found = true;
        }
        CFRelease(list);
    }
    if (info) {
        CFRelease(info);
    }
    return found;     /* false on desktops: engine reports AC, 100% */
}

static void cb_clipboard_from_guest(void *o, const char *utf8, size_t len)
{
    (void)o;
    LOG("guest clipboard (%zu bytes): %.*s", len, (int)(len > 200 ? 200 : len),
        utf8);
    if (getenv("VA_MAC_PASTEBOARD")) {
        FILE *f = popen("/usr/bin/pbcopy", "w");
        if (f) {
            fwrite(utf8, 1, len, f);
            pclose(f);
        }
    }
}

static int cb_camera_count(void *o)
{
    (void)o;
    return s_fake_camera ? 1 : 0;
}

static bool cb_camera_info(void *o, int index, VaCameraInfo *out)
{
    (void)o;
    if (!s_fake_camera || index != 0) {
        return false;
    }
    memset(out, 0, sizeof(*out));
    snprintf(out->name, sizeof(out->name), "mac-fake");
    out->facing = VA_CAMERA_BACK;
    out->orientation_deg = 90;
    out->sizes[0].width = 640;
    out->sizes[0].height = 480;
    out->sizes[1].width = 320;
    out->sizes[1].height = 240;
    return true;
}

static bool cb_camera_start(void *o, int index, int w, int h)
{
    (void)o;
    if (!s_fake_camera || index != 0) {
        return false;
    }
    s_camera_on = true;
    s_cam_w = w;
    s_cam_h = h;
    LOG("camera start %dx%d", w, h);
    return true;
}

static void cb_camera_stop(void *o, int index)
{
    (void)o;
    (void)index;
    s_camera_on = false;
    LOG("camera stop");
}

/* Moving vertical colour bars, NV21. */
static bool cb_camera_read_frame(void *o, int index, uint8_t *dst,
                                 size_t len, int64_t *ts)
{
    (void)o;
    static const uint8_t bars[8][3] = {   /* Y, U, V (BT.601) */
        { 235, 128, 128 }, { 210, 16, 146 }, { 170, 166, 16 },
        { 145, 54, 34 }, { 106, 202, 222 }, { 81, 90, 240 },
        { 41, 240, 110 }, { 16, 128, 128 },
    };
    if (!s_camera_on || index != 0) {
        return false;
    }
    int w = s_cam_w, h = s_cam_h;
    if (len < (size_t)w * h * 3 / 2) {
        return false;
    }
    uint32_t shift = s_cam_frame++ * 4;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            dst[y * w + x] = bars[((x + shift) * 8 / w) % 8][0];
        }
    }
    uint8_t *vu = dst + (size_t)w * h;
    for (int y = 0; y < h / 2; y++) {
        for (int x = 0; x < w / 2; x++) {
            const uint8_t *b = bars[((2 * x + shift) * 8 / w) % 8];
            vu[y * w + 2 * x] = b[2];
            vu[y * w + 2 * x + 1] = b[1];
        }
    }
    *ts = now_ns();
    return true;
}

static void cb_vibrate(void *o, uint32_t ms)
{
    (void)o;
    LOG("vibrate %u ms", ms);
}

/* ---- sensor / location ticker ---- */

static void *ticker_main(void *arg)
{
    (void)arg;
    for (;;) {
        int64_t t = now_ns();
        float vals[VA_SENSOR_COUNT][4];
        int counts[VA_SENSOR_COUNT];
        bool due[VA_SENSOR_COUNT];
        bool loc_due = false;
        VaLocation loc;

        pthread_mutex_lock(&s_lock);
        for (int i = 0; i < VA_SENSOR_COUNT; i++) {
            due[i] = s_enabled[i] && t >= s_next_ns[i];
            if (due[i]) {
                s_next_ns[i] = t + (int64_t)s_delay_ms[i] * 1000000;
                memcpy(vals[i], s_values[i], sizeof(vals[i]));
                counts[i] = s_counts[i];
            }
        }
        if (s_location_on && t >= s_next_location_ns) {
            s_next_location_ns = t + 1000000000LL;
            loc = s_location;
            loc.unix_time_ms = unix_ms();
            loc_due = true;
        }
        pthread_mutex_unlock(&s_lock);

        for (int i = 0; i < VA_SENSOR_COUNT; i++) {
            if (due[i]) {
                s_api->sensor_event((VaSensorType)i, vals[i], counts[i], t);
            }
        }
        if (loc_due) {
            s_api->location_update(&loc);
        }
        usleep(5000);
    }
    return NULL;
}

/* ---- control socket ---- */

static int sensor_type_from_name(const char *n)
{
    static const char *const names[] = {
        [VA_SENSOR_ACCELERATION] = "accel", [VA_SENSOR_GYROSCOPE] = "gyro",
        [VA_SENSOR_MAGNETIC_FIELD] = "mag", [VA_SENSOR_ORIENTATION] = "orient",
        [VA_SENSOR_TEMPERATURE] = "temp", [VA_SENSOR_PROXIMITY] = "prox",
        [VA_SENSOR_LIGHT] = "light", [VA_SENSOR_PRESSURE] = "pressure",
        [VA_SENSOR_HUMIDITY] = "humidity", [VA_SENSOR_GRAVITY] = "gravity",
        [VA_SENSOR_LINEAR_ACCELERATION] = "linacc",
        [VA_SENSOR_ROTATION_VECTOR] = "rotvec",
    };
    for (int i = 0; i < VA_SENSOR_COUNT; i++) {
        if (names[i] && !strcmp(n, names[i])) {
            return i;
        }
    }
    return -1;
}

static const char *handle_command(char *line)
{
    char *arg = strchr(line, ' ');
    if (arg) {
        *arg++ = 0;
    }
    if (!strcmp(line, "clip")) {
        const char *text = arg ? arg : "";
        s_api->clipboard_from_host(text, strlen(text));
        return "ok";
    }
    if (!strcmp(line, "geo")) {
        double lat, lon, alt = 5;
        if (!arg || sscanf(arg, "%lf %lf %lf", &lat, &lon, &alt) < 2) {
            return "error: geo <lat> <lon> [<alt>]";
        }
        pthread_mutex_lock(&s_lock);
        s_location.latitude_deg = lat;
        s_location.longitude_deg = lon;
        s_location.altitude_m = alt;
        s_next_location_ns = 0;
        VaLocation loc = s_location;
        pthread_mutex_unlock(&s_lock);
        loc.unix_time_ms = unix_ms();
        s_api->location_update(&loc);
        return "ok";
    }
    if (!strcmp(line, "sensor")) {
        char name[32];
        float v[4] = { 0 };
        int n = arg ? sscanf(arg, "%31s %f %f %f %f", name, &v[0], &v[1],
                             &v[2], &v[3]) : 0;
        int t = n >= 2 ? sensor_type_from_name(name) : -1;
        if (t < 0) {
            return "error: sensor <type> <v0> [v1 v2 v3]";
        }
        pthread_mutex_lock(&s_lock);
        memcpy(s_values[t], v, sizeof(v));
        s_counts[t] = n - 1;
        s_next_ns[t] = 0;
        pthread_mutex_unlock(&s_lock);
        s_api->sensor_event((VaSensorType)t, v, n - 1, now_ns());
        return "ok";
    }
    if (!strcmp(line, "finger")) {
        if (!arg) {
            return "error: finger <id>|off";
        }
        s_api->fingerprint_touch(!strcmp(arg, "off") ? 0 : atoi(arg));
        return "ok";
    }
    if (!strcmp(line, "key")) {
        if (!arg) {
            return "error: key <code>";
        }
        s_api->key((uint32_t)atoi(arg), true);
        s_api->key((uint32_t)atoi(arg), false);
        return "ok";
    }
    if (!strcmp(line, "battery")) {
        s_api->battery_changed();
        return "ok";
    }
    return "error: unknown command";
}

static void *control_main(void *arg)
{
    const char *path = arg;
    int srv = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un sa = { .sun_family = AF_UNIX };
    snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", path);
    unlink(path);
    if (srv < 0 || bind(srv, (struct sockaddr *)&sa, sizeof(sa)) < 0 ||
        listen(srv, 4) < 0) {
        plat_log(3, "control socket %s: %s", path, strerror(errno));
        return NULL;
    }
    LOG("control socket: %s", path);
    for (;;) {
        int fd = accept(srv, NULL, NULL);
        if (fd < 0) {
            continue;
        }
        FILE *in = fdopen(fd, "r+");
        char line[4096];
        while (in && fgets(line, sizeof(line), in)) {
            line[strcspn(line, "\r\n")] = 0;
            if (!line[0]) {
                continue;
            }
            const char *r = handle_command(line);
            fprintf(in, "%s\n", r);
            fflush(in);
        }
        if (in) {
            fclose(in);
        } else {
            close(fd);
        }
    }
    return NULL;
}

/* ---- entry point ---- */

static VaHostCallbacks s_cb = {
    .abi_version = VA_HOST_ABI_VERSION,
    .log = cb_log,
    .guest_state_changed = cb_guest_state,
    .sensor_set_enabled = cb_sensor_set_enabled,
    .sensor_available_mask = cb_sensor_mask,
    .location_set_enabled = cb_location_enabled,
    .battery_get = cb_battery_get,
    .clipboard_from_guest = cb_clipboard_from_guest,
    .camera_count = cb_camera_count,
    .camera_info = cb_camera_info,
    .camera_start = cb_camera_start,
    .camera_stop = cb_camera_stop,
    .camera_read_frame = cb_camera_read_frame,
    .vibrate = cb_vibrate,
};

static void set_value(VaSensorType t, float a, float b, float c, int n)
{
    s_values[t][0] = a;
    s_values[t][1] = b;
    s_values[t][2] = c;
    s_counts[t] = n;
}

__attribute__((visibility("default")))
void va_platform_attach(const VaEngineApi *api)
{
    if (!api || api->version != VA_ENGINE_API_VERSION) {
        plat_log(3, "engine API version mismatch");
        return;
    }
    s_api = api;
    set_value(VA_SENSOR_ACCELERATION, 0, 9.81f, 0, 3);
    set_value(VA_SENSOR_GYROSCOPE, 0, 0, 0, 3);
    set_value(VA_SENSOR_MAGNETIC_FIELD, 0, 5.9f, -48.4f, 3);
    set_value(VA_SENSOR_ORIENTATION, 0, 0, 0, 3);
    set_value(VA_SENSOR_TEMPERATURE, 25, 0, 0, 1);
    set_value(VA_SENSOR_PROXIMITY, 1, 0, 0, 1);
    set_value(VA_SENSOR_LIGHT, 300, 0, 0, 1);
    set_value(VA_SENSOR_PRESSURE, 1013.25f, 0, 0, 1);
    set_value(VA_SENSOR_HUMIDITY, 45, 0, 0, 1);
    s_location.latitude_deg = 37.4220;
    s_location.longitude_deg = -122.0841;
    s_location.altitude_m = 5;
    s_location.horizontal_accuracy_m = 5;
    const char *env = getenv("VA_MAC_LOCATION");
    if (env) {
        sscanf(env, "%lf,%lf,%lf", &s_location.latitude_deg,
               &s_location.longitude_deg, &s_location.altitude_m);
    }
    s_fake_camera = getenv("VA_MAC_FAKE_CAMERA") &&
                    strcmp(getenv("VA_MAC_FAKE_CAMERA"), "0");
    api->set_callbacks(&s_cb);

    pthread_t th;
    pthread_create(&th, NULL, ticker_main, NULL);
    pthread_detach(th);
    const char *ctl = getenv("VA_MAC_CONTROL");
    if (ctl && *ctl) {
        pthread_create(&th, NULL, control_main, strdup(ctl));
        pthread_detach(th);
    }
    LOG("macOS platform attached (location %.4f,%.4f%s)",
        s_location.latitude_deg, s_location.longitude_deg,
        s_fake_camera ? ", fake camera" : "");
}
