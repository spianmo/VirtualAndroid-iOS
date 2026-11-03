/*
 * VirtualAndroid libva_gfx standalone test harness (no QEMU).
 *
 * Loads libva_gfx with dlopen exactly like the engine will, provides a fake
 * VaGfxEngineOps (pipe registry + "BQL" mutex + fake goldfish sync), and acts
 * as a minimal goldfish-opengl guest: it opens pipe:opengles, performs the
 * HostConnection handshake, issues hand-encoded renderControl + GLESv2
 * commands (exactly the wire format the API 33 guest encoder produces with
 * checksums off), posts ColorBuffers, and writes the IOSurface frames it gets
 * back through VaGfxPresentFn to PNG files.
 *
 * usage: va_gfx_harness <path/to/libva_gfx.dylib> <out_dir> [angle|native]
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurfaceRef.h>
#include <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "hw/android/android_pipe.h"
#include "va_gfx.h"

static int W = 320, H = 480; /* override with HARNESS_W / HARNESS_H */

static int (*p_va_gfx_init)(const VaGfxConfig *, const VaGfxEngineOps *, VaGfxPresentFn, void *);
static void (*p_va_gfx_register_pipe_services)(void);
static const char *(*p_va_gfx_renderer_string)(void);
static int (*p_va_gfx_get_gles_version)(int *, int *);
static void (*p_va_gfx_teardown)(void);

static int failures = 0;
static int s_vulkan_advertised = 0;
#define CHECK(cond, ...)                                       \
    do {                                                       \
        if (!(cond)) {                                         \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                      \
            fprintf(stderr, "\n");                             \
            failures++;                                        \
        }                                                      \
    } while (0)

/* ------------------------------------------------------------------ */
/* Fake engine                                                         */
/* ------------------------------------------------------------------ */

static pthread_mutex_t s_bql = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t s_wake = PTHREAD_COND_INITIALIZER;
static pthread_t s_bql_owner;
static int s_bql_held = 0;
static int s_engine_calls_without_bql = 0;

static void bql_lock(void)
{
    pthread_mutex_lock(&s_bql);
    s_bql_owner = pthread_self();
    s_bql_held = 1;
}

static void bql_unlock(void)
{
    s_bql_held = 0;
    pthread_mutex_unlock(&s_bql);
}

static int bql_held_by_me(void)
{
    return s_bql_held && pthread_equal(s_bql_owner, pthread_self());
}

/* cond_wait releases the BQL like a sleeping vCPU would. */
static int bql_wait(int timeout_ms)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += timeout_ms / 1000;
    ts.tv_nsec += (timeout_ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec++;
        ts.tv_nsec -= 1000000000L;
    }
    s_bql_held = 0;
    int r = pthread_cond_timedwait(&s_wake, &s_bql, &ts);
    s_bql_owner = pthread_self();
    s_bql_held = 1;
    return r;
}

typedef struct {
    const char *name;
    void *opaque;
    const AndroidPipeFuncs *funcs;
} Service;

static Service s_services[16];
static int s_nservices = 0;

typedef struct {
    const Service *svc;
    void *state;
    unsigned wakes;
    int closed;
} FakePipe;

static FakePipe *s_pipes[8]; /* open guest pipes, for the atexit exit notifier */
static int s_npipes = 0;

static void eng_pipe_add_type(const char *name, void *opaque, const AndroidPipeFuncs *funcs)
{
    printf("engine: pipe service registered: %s\n", name);
    s_services[s_nservices++] = (Service){ name, opaque, funcs };
}

static void eng_pipe_host_close(void *hwpipe)
{
    if (!bql_held_by_me()) s_engine_calls_without_bql++;
    ((FakePipe *)hwpipe)->closed = 1;
    pthread_cond_broadcast(&s_wake);
}

static void eng_pipe_host_signal_wake(void *hwpipe, unsigned flags)
{
    if (!bql_held_by_me()) s_engine_calls_without_bql++;
    ((FakePipe *)hwpipe)->wakes |= flags;
    pthread_cond_broadcast(&s_wake);
}

static uint64_t s_next_timeline = 1;
static void (*s_trigger_wait)(uint64_t, uint64_t, uint64_t);
static int s_timeline_incs = 0;

static uint64_t eng_sync_create_timeline(void) { return s_next_timeline++; }
static int eng_sync_create_fence(uint64_t tl, uint32_t pt) { (void)tl; (void)pt; return -1; }
static pthread_mutex_t s_sync_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t s_sync_cond = PTHREAD_COND_INITIALIZER;
static uint64_t s_last_inc_timeline = 0;
static uint32_t s_last_inc_count = 0;

static void eng_sync_timeline_inc(uint64_t tl, uint32_t n)
{
    /* allowed from any thread, with or without the BQL (goldfish_sync.h) */
    pthread_mutex_lock(&s_sync_lock);
    s_timeline_incs++;
    s_last_inc_timeline = tl;
    s_last_inc_count = n;
    pthread_cond_broadcast(&s_sync_cond);
    pthread_mutex_unlock(&s_sync_lock);
}
static void eng_sync_destroy_timeline(uint64_t tl) { (void)tl; }
static void eng_sync_register_trigger_wait(void (*fn)(uint64_t, uint64_t, uint64_t))
{
    s_trigger_wait = fn;
}

/* ------------------------------------------------------------------ */
/* Guest side: goldfish pipe client (called with the BQL held)          */
/* ------------------------------------------------------------------ */

static FakePipe *guest_open(const char *name)
{
    for (int i = 0; i < s_nservices; i++) {
        if (!strcmp(s_services[i].name, name)) {
            FakePipe *p = calloc(1, sizeof(*p));
            p->svc = &s_services[i];
            p->state = p->svc->funcs->init(p, p->svc->opaque, NULL);
            if (!p->state) {
                free(p);
                return NULL;
            }
            if (s_npipes < 8) s_pipes[s_npipes++] = p;
            return p;
        }
    }
    return NULL;
}

static void guest_close(FakePipe *p)
{
    for (int i = 0; i < s_npipes; i++) {
        if (s_pipes[i] == p) s_pipes[i] = NULL;
    }
    p->svc->funcs->close(p->state);
    free(p);
}

static int guest_write(FakePipe *p, const void *data, size_t len)
{
    const uint8_t *d = data;
    while (len) {
        AndroidPipeBuffer b = { (uint8_t *)d, len };
        int r = p->svc->funcs->sendBuffers(p->state, &b, 1);
        if (r > 0) {
            d += r;
            len -= (size_t)r;
        } else if (r == PIPE_ERROR_AGAIN) {
            p->wakes &= ~PIPE_WAKE_WRITE;
            p->svc->funcs->wakeOn(p->state, PIPE_WAKE_WRITE);
            while (!(p->wakes & PIPE_WAKE_WRITE) && !p->closed) {
                if (bql_wait(10000) == ETIMEDOUT) return -1;
            }
        } else {
            return r;
        }
    }
    return 0;
}

static int guest_read(FakePipe *p, void *data, size_t len)
{
    uint8_t *d = data;
    while (len) {
        AndroidPipeBuffer b = { d, len };
        int r = p->svc->funcs->recvBuffers(p->state, &b, 1);
        if (r > 0) {
            d += r;
            len -= (size_t)r;
        } else if (r == PIPE_ERROR_AGAIN || r == 0) {
            p->wakes &= ~PIPE_WAKE_READ;
            p->svc->funcs->wakeOn(p->state, PIPE_WAKE_READ);
            while (!(p->wakes & PIPE_WAKE_READ) && !p->closed) {
                if (bql_wait(10000) == ETIMEDOUT) {
                    fprintf(stderr, "guest_read: timeout\n");
                    return -1;
                }
            }
        } else {
            return r;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Minimal encoder (renderControl / GLESv2 wire format, no checksums)   */
/* ------------------------------------------------------------------ */

typedef struct {
    uint8_t *buf;
    size_t len, cap;
} Packet;

static void pk_u32(Packet *pk, uint32_t v)
{
    if (pk->len + 4 > pk->cap) {
        pk->cap = (pk->cap + 4) * 2;
        pk->buf = realloc(pk->buf, pk->cap);
    }
    memcpy(pk->buf + pk->len, &v, 4);
    pk->len += 4;
}

static void pk_f32(Packet *pk, float f)
{
    uint32_t v;
    memcpy(&v, &f, 4);
    pk_u32(pk, v);
}

static void pk_bytes(Packet *pk, const void *data, size_t n)
{
    if (pk->len + n > pk->cap) {
        pk->cap = (pk->len + n) * 2;
        pk->buf = realloc(pk->buf, pk->cap);
    }
    memcpy(pk->buf + pk->len, data, n);
    pk->len += n;
}

static Packet pk_begin(uint32_t opcode)
{
    Packet pk = { 0 };
    pk_u32(&pk, opcode);
    pk_u32(&pk, 0); /* total size, patched in pk_send */
    return pk;
}

static void pk_send(FakePipe *p, Packet *pk)
{
    uint32_t sz = (uint32_t)pk->len;
    memcpy(pk->buf + 4, &sz, 4);
    if (guest_write(p, pk->buf, pk->len) != 0) {
        fprintf(stderr, "pipe write failed\n");
        failures++;
    }
    free(pk->buf);
}

static uint32_t read_u32(FakePipe *p)
{
    uint32_t v = 0;
    if (guest_read(p, &v, 4) != 0) failures++;
    return v;
}

enum {
    OP_rcGetRendererVersion = 10000,
    OP_rcGetGLString = 10003,
    OP_rcChooseConfig = 10006,
    OP_rcGetFBParam = 10007,
    OP_rcCreateContext = 10008,
    OP_rcCreateWindowSurface = 10010,
    OP_rcCreateColorBuffer = 10012,
    OP_rcSetWindowColorBuffer = 10015,
    OP_rcFlushWindowColorBuffer = 10016,
    OP_rcMakeCurrent = 10017,
    OP_rcFBPost = 10018,
    OP_rcUpdateColorBuffer = 10024,
    OP_rcCompose = 10037,
    OP_rcCreateSyncKHR = 10029,
    OP_glClear = 2063,
    OP_glClearColor = 2064,
    OP_glDisable = 2086,
    OP_glEnable = 2090,
    OP_glScissor = 2144,
    OP_glViewport = 2189,
};

static uint32_t rc0(FakePipe *p, uint32_t op)
{
    Packet pk = pk_begin(op);
    pk_send(p, &pk);
    return read_u32(p);
}

static uint32_t rcN(FakePipe *p, uint32_t op, int reply, int n, ...)
{
    Packet pk = pk_begin(op);
    va_list ap;
    va_start(ap, n);
    for (int i = 0; i < n; i++) pk_u32(&pk, va_arg(ap, uint32_t));
    va_end(ap);
    pk_send(p, &pk);
    return reply ? read_u32(p) : 0;
}

static void rc_get_string(FakePipe *p, uint32_t name, char *out, uint32_t size)
{
    Packet pk = pk_begin(OP_rcGetGLString);
    pk_u32(&pk, name);
    pk_u32(&pk, size); /* out-buffer length */
    pk_u32(&pk, size); /* bufferSize argument */
    pk_send(p, &pk);
    guest_read(p, out, size);
    (void)read_u32(p);
    out[size - 1] = 0;
}

static uint32_t rc_choose_config(FakePipe *p)
{
    const int32_t attribs[] = {
        0x3024, 8,     /* EGL_RED_SIZE */
        0x3023, 8,     /* EGL_GREEN_SIZE */
        0x3022, 8,     /* EGL_BLUE_SIZE */
        0x3021, 8,     /* EGL_ALPHA_SIZE */
        0x3033, 0x5,   /* EGL_SURFACE_TYPE: WINDOW | PBUFFER */
        0x3040, 0x4,   /* EGL_RENDERABLE_TYPE: ES2 */
        0x3038,        /* EGL_NONE */
    };
    Packet pk = pk_begin(OP_rcChooseConfig);
    pk_u32(&pk, sizeof(attribs));
    pk_bytes(&pk, attribs, sizeof(attribs));
    pk_u32(&pk, sizeof(attribs)); /* attribs_size (bytes) */
    pk_u32(&pk, 4 * 1);           /* configs out-buffer length */
    pk_u32(&pk, 1);               /* configs_size (count) */
    pk_send(p, &pk);
    uint32_t config = read_u32(p);
    int32_t n = (int32_t)read_u32(p);
    return n > 0 ? config : 0xffffffffu;
}

static void gl_clear_color(FakePipe *p, float r, float g, float b, float a)
{
    Packet pk = pk_begin(OP_glClearColor);
    pk_f32(&pk, r);
    pk_f32(&pk, g);
    pk_f32(&pk, b);
    pk_f32(&pk, a);
    pk_send(p, &pk);
}

/* ------------------------------------------------------------------ */
/* Present callback -> PNG                                             */
/* ------------------------------------------------------------------ */

static pthread_mutex_t s_frame_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t s_frame_cond = PTHREAD_COND_INITIALIZER;
static int s_frames = 0;
static IOSurfaceRef s_last_surface = NULL;
static int s_present_with_bql = 0;
/* teardown-stuck: the present callback never returns (render thread wedged
 * inside FrameBuffer::postImpl with the FrameBuffer lock held). */
static volatile int s_block_present = 0;
static int s_present_entered = 0;
static pthread_cond_t s_never = PTHREAD_COND_INITIALIZER;

static void on_present(void *opaque, const VaGfxFrame *frame)
{
    (void)opaque;
    if (bql_held_by_me()) s_present_with_bql++;
    if (s_block_present) {
        pthread_mutex_lock(&s_frame_lock);
        s_present_entered = 1;
        pthread_cond_broadcast(&s_frame_cond);
        for (;;) pthread_cond_wait(&s_never, &s_frame_lock); /* wedged forever */
    }
    pthread_mutex_lock(&s_frame_lock);
    if (s_last_surface) CFRelease(s_last_surface);
    s_last_surface = (IOSurfaceRef)frame->iosurface;
    CFRetain(s_last_surface);
    s_frames++;
    printf("present: frame #%llu %dx%d iosurface=%p (id %u)\n",
           (unsigned long long)frame->frame_number, frame->width, frame->height, frame->iosurface,
           IOSurfaceGetID(s_last_surface));
    pthread_cond_broadcast(&s_frame_cond);
    pthread_mutex_unlock(&s_frame_lock);
}

/* Waits (without holding the BQL) for frame number `want`. */
static IOSurfaceRef wait_frame(int want)
{
    IOSurfaceRef s = NULL;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += 10;
    pthread_mutex_lock(&s_frame_lock);
    while (s_frames < want) {
        if (pthread_cond_timedwait(&s_frame_cond, &s_frame_lock, &ts) == ETIMEDOUT) break;
    }
    if (s_frames >= want && s_last_surface) {
        s = s_last_surface;
        CFRetain(s);
    }
    pthread_mutex_unlock(&s_frame_lock);
    return s;
}

static void pixel_at(IOSurfaceRef s, int x, int y, uint8_t out_rgba[4])
{
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *base = IOSurfaceGetBaseAddress(s);
    const uint8_t *px = base + (size_t)y * IOSurfaceGetBytesPerRow(s) + (size_t)x * 4;
    out_rgba[0] = px[2];
    out_rgba[1] = px[1];
    out_rgba[2] = px[0];
    out_rgba[3] = px[3];
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
}

static int write_png(IOSurfaceRef s, const char *path)
{
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(IOSurfaceGetBaseAddress(s), w, h, 8,
                                             IOSurfaceGetBytesPerRow(s), cs,
                                             kCGImageAlphaPremultipliedFirst |
                                                 kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    CFStringRef cfpath = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, cfpath, kCFURLPOSIXPathStyle, false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    int ok = 0;
    if (dst) {
        CGImageDestinationAddImage(dst, img, NULL);
        ok = CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CFRelease(url);
    CFRelease(cfpath);
    CGImageRelease(img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    printf("wrote %s (%zux%zu): %s\n", path, w, h, ok ? "ok" : "FAILED");
    return ok;
}

static int near(const uint8_t a[4], int r, int g, int b)
{
    return abs(a[0] - r) <= 3 && abs(a[1] - g) <= 3 && abs(a[2] - b) <= 3;
}

/* hwcomposer host composition request (gfxstream Hwc2.h / guest EmuHWC2.h) */
typedef struct {
    uint32_t cbHandle;
    uint32_t composeMode; /* 2 = DEVICE (texture), 3 = SOLID_COLOR */
    int32_t displayFrame[4]; /* left, top, right, bottom */
    float crop[4];
    int32_t blendMode; /* 1 = NONE, 2 = PREMULTIPLIED */
    float alpha;
    uint8_t color[4];
    uint32_t transform;
} ComposeLayer;
typedef struct {
    uint32_t version; /* 2 */
    uint32_t displayId;
    uint32_t targetHandle;
    uint32_t numLayers;
    ComposeLayer layer[2];
} ComposeDeviceV2;
_Static_assert(sizeof(ComposeLayer) == 56, "ComposeLayer layout");

/*
 * HARNESS_EXIT=atexit: what QEMU does. An exit notifier is registered with
 * atexit() before libva_gfx is dlopen'ed, so it runs *after* libva_gfx's (and
 * ANGLE's) static destructors; it closes every pipe (BQL) and then calls
 * va_gfx_teardown(), like engine/qemu hw/android/ranchu.c:ranchu_exit().
 */
static int s_atexit_mode = 0;

static void harness_qemu_exit_notifier(void)
{
    if (!s_atexit_mode) return;
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    const int locked = bql_held_by_me();
    if (!locked) bql_lock();
    for (int i = s_npipes - 1; i >= 0; i--) {
        if (s_pipes[i]) s_pipes[i]->svc->funcs->close(s_pipes[i]->state);
    }
    if (!locked) bql_unlock();
    p_va_gfx_teardown();
    clock_gettime(CLOCK_MONOTONIC, &b);
    printf("exit: exit notifier (close all pipes + va_gfx_teardown) took %.1f ms\n",
           (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6);
}

/* ------------------------------------------------------------------ */

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <libva_gfx.dylib> <out_dir> [angle|native] [vulkan]\n",
                argv[0]);
        return 2;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    atexit(harness_qemu_exit_notifier); /* before dlopen, like QEMU */
    const char *backend = argc > 3 ? argv[3] : "angle";
    if (getenv("HARNESS_W")) W = atoi(getenv("HARNESS_W"));
    if (getenv("HARNESS_H")) H = atoi(getenv("HARNESS_H"));
    void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 1;
    }
    p_va_gfx_init = dlsym(lib, "va_gfx_init");
    p_va_gfx_register_pipe_services = dlsym(lib, "va_gfx_register_pipe_services");
    p_va_gfx_renderer_string = dlsym(lib, "va_gfx_renderer_string");
    p_va_gfx_get_gles_version = dlsym(lib, "va_gfx_get_gles_version");
    p_va_gfx_teardown = dlsym(lib, "va_gfx_teardown");
    if (!p_va_gfx_init || !p_va_gfx_register_pipe_services || !p_va_gfx_renderer_string ||
        !p_va_gfx_teardown) {
        fprintf(stderr, "dlsym failed\n");
        return 1;
    }

    VaGfxConfig cfg = {
        .display_width = W, .display_height = H, .display_dpi = 240, .refresh_hz = 60,
        .gles_backend = backend, .enable_vulkan = argc > 4 && !strcmp(argv[4], "vulkan"),
    };
    VaGfxEngineOps ops = {
        .pipe_add_type = eng_pipe_add_type,
        .pipe_host_close = eng_pipe_host_close,
        .pipe_host_signal_wake = eng_pipe_host_signal_wake,
        .bql_lock = bql_lock,
        .bql_unlock = bql_unlock,
        .sync_create_timeline = eng_sync_create_timeline,
        .sync_create_fence = eng_sync_create_fence,
        .sync_timeline_inc = eng_sync_timeline_inc,
        .sync_destroy_timeline = eng_sync_destroy_timeline,
        .sync_register_trigger_wait = eng_sync_register_trigger_wait,
    };
    if (p_va_gfx_init(&cfg, &ops, on_present, NULL) != 0) {
        fprintf(stderr, "va_gfx_init failed\n");
        return 1;
    }
    p_va_gfx_register_pipe_services();
    int gmaj = 0, gmin = 0;
    if (p_va_gfx_get_gles_version) p_va_gfx_get_gles_version(&gmaj, &gmin);
    printf("renderer: %s (guest GLES %d.%d)\n", p_va_gfx_renderer_string(), gmaj, gmin);

    char path[1024];
    bql_lock(); /* we are the "vCPU" now */

    /* --- GLProcessPipe handshake (ProcessPipe.cpp) --- */
    FakePipe *proc = guest_open("GLProcessPipe");
    CHECK(proc, "open GLProcessPipe");
    uint64_t puid = 0;
    if (proc) {
        int32_t confirm = 100;
        guest_write(proc, &confirm, 4);
        guest_read(proc, &puid, 8);
        printf("GLProcessPipe: puid=%llu\n", (unsigned long long)puid);
        CHECK(puid != 0, "puid");
    }

    /* --- opengles pipe (QemuPipeStream + HostConnection) --- */
    FakePipe *gl = guest_open("opengles");
    CHECK(gl, "open opengles");
    if (!gl) return 1;
    uint32_t client_flags = 0;
    guest_write(gl, &client_flags, 4);

    uint32_t ver = rc0(gl, OP_rcGetRendererVersion);
    printf("rcGetRendererVersion = %u\n", ver);
    CHECK(ver == 1, "renderer version %u", ver);
    static char str[8192];
    rc_get_string(gl, 0x1F00, str, 256);
    printf("GL_VENDOR   = %s\n", str);
    rc_get_string(gl, 0x1F01, str, 512);
    printf("GL_RENDERER = %s\n", str);
    rc_get_string(gl, 0x1F02, str, 256);
    printf("GL_VERSION  = %s\n", str);
    rc_get_string(gl, 0x1F03, str, sizeof(str));
    printf("GL_EXTENSIONS (ANDROID_EMU_*):");
    for (char *tok = strtok(str, " "); tok; tok = strtok(NULL, " ")) {
        if (!strncmp(tok, "ANDROID_EMU", 11)) printf(" %s", tok);
        if (!strncmp(tok, "ANDROID_EMU_vulkan", 18) && !strcmp(tok, "ANDROID_EMU_vulkan")) {
            s_vulkan_advertised = 1;
        }
    }
    printf("\n");
    uint32_t fbw = rcN(gl, OP_rcGetFBParam, 1, 1, 1);
    uint32_t fbh = rcN(gl, OP_rcGetFBParam, 1, 1, 2);
    uint32_t dpi = rcN(gl, OP_rcGetFBParam, 1, 1, 3);
    uint32_t fps = rcN(gl, OP_rcGetFBParam, 1, 1, 5);
    printf("rcGetFBParam: %ux%u xdpi=%u fps=%u\n", fbw, fbh, dpi, fps);
    CHECK(fbw == W && fbh == H, "fb size");
    printf("host Vulkan for the guest: %s\n", s_vulkan_advertised ? "advertised" : "not advertised");
    if (cfg.enable_vulkan) CHECK(s_vulkan_advertised, "Vulkan requested but not advertised");

    /* --- Frame 1: CPU upload (gralloc path) + post --- */
    uint32_t cb1 = rcN(gl, OP_rcCreateColorBuffer, 1, 3, W, H, 0x1908 /* GL_RGBA */);
    printf("rcCreateColorBuffer = %u\n", cb1);
    CHECK(cb1 != 0, "cb1");
    FakePipe *ref = guest_open("refcount");
    CHECK(ref, "open refcount");
    if (ref) guest_write(ref, &cb1, 4);
    {
        uint8_t *px = malloc(W * H * 4);
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                uint8_t *p = px + (y * W + x) * 4;
                p[0] = (uint8_t)(x * 255 / (W - 1));
                p[1] = (uint8_t)(y * 255 / (H - 1));
                p[2] = 128;
                p[3] = 255;
            }
        Packet pk = pk_begin(OP_rcUpdateColorBuffer);
        uint32_t args[] = { cb1, 0, 0, W, H, 0x1908, 0x1401 /* GL_UNSIGNED_BYTE */ };
        for (int i = 0; i < 7; i++) pk_u32(&pk, args[i]);
        pk_u32(&pk, W * H * 4);
        pk_bytes(&pk, px, W * H * 4);
        free(px);
        pk_send(gl, &pk);
        int r = (int)read_u32(gl);
        CHECK(r == 0, "rcUpdateColorBuffer = %d", r);
    }
    rcN(gl, OP_rcFBPost, 0, 1, cb1);
    (void)rc0(gl, OP_rcGetRendererVersion); /* round trip: post has been processed */
    bql_unlock();
    IOSurfaceRef f1 = wait_frame(1);
    CHECK(f1, "no frame after rcFBPost #1");
    if (f1) {
        snprintf(path, sizeof(path), "%s/va_gfx_frame1_upload_%s.png", argv[2], backend);
        write_png(f1, path);
        uint8_t a[4], b[4];
        pixel_at(f1, 0, 0, a);
        pixel_at(f1, W - 1, H - 1, b);
        printf("frame1 pixels: top-left rgba(%d,%d,%d) bottom-right rgba(%d,%d,%d)\n", a[0], a[1],
               a[2], b[0], b[1], b[2]);
        /* gralloc convention: CPU row 0 is the top of the screen */
        CHECK(near(a, 0, 0, 128) && near(b, 255, 255, 128), "frame1 gradient corners");
        CFRelease(f1);
    }
    bql_lock();

    /* --- Frame 2: real GLES rendering through the decoder + translator --- */
    uint32_t config = rc_choose_config(gl);
    printf("rcChooseConfig = %u\n", config);
    CHECK(config != 0xffffffffu, "config");
    uint32_t ctx = rcN(gl, OP_rcCreateContext, 1, 3, config, 0, 2 /* GLESApi_2 */);
    uint32_t surf = rcN(gl, OP_rcCreateWindowSurface, 1, 3, config, W, H);
    uint32_t cb2 = rcN(gl, OP_rcCreateColorBuffer, 1, 3, W, H, 0x1908);
    rcN(gl, OP_rcSetWindowColorBuffer, 0, 2, surf, cb2);
    uint32_t mc = rcN(gl, OP_rcMakeCurrent, 1, 3, ctx, surf, surf);
    printf("context=%u surface=%u cb=%u makeCurrent=%u\n", ctx, surf, cb2, mc);
    CHECK(ctx && surf && cb2 && mc, "context setup");

    rcN(gl, OP_glViewport, 0, 4, 0, 0, W, H);
    gl_clear_color(gl, 0.1f, 0.2f, 0.6f, 1.0f);
    rcN(gl, OP_glClear, 0, 1, 0x4000 /* GL_COLOR_BUFFER_BIT */);
    rcN(gl, OP_glEnable, 0, 1, 0x0C11 /* GL_SCISSOR_TEST */);
    rcN(gl, OP_glScissor, 0, 4, 0, 0, W / 2, H / 2);        /* GL bottom-left */
    gl_clear_color(gl, 1.0f, 0.0f, 0.0f, 1.0f);
    rcN(gl, OP_glClear, 0, 1, 0x4000);
    rcN(gl, OP_glScissor, 0, 4, W / 2, H / 2, W / 2, H / 2); /* GL top-right */
    gl_clear_color(gl, 0.0f, 1.0f, 0.0f, 1.0f);
    rcN(gl, OP_glClear, 0, 1, 0x4000);
    rcN(gl, OP_glDisable, 0, 1, 0x0C11);
    int flushed = (int)rcN(gl, OP_rcFlushWindowColorBuffer, 1, 1, surf);
    CHECK(flushed == 0, "rcFlushWindowColorBuffer = %d", flushed);
    rcN(gl, OP_rcFBPost, 0, 1, cb2);
    (void)rc0(gl, OP_rcGetRendererVersion);
    bql_unlock();
    IOSurfaceRef f2 = wait_frame(2);
    CHECK(f2, "no frame after rcFBPost #2");
    if (f2) {
        snprintf(path, sizeof(path), "%s/va_gfx_frame2_gles_%s.png", argv[2], backend);
        write_png(f2, path);
        uint8_t bl[4], tr[4], tl[4];
        pixel_at(f2, W / 4, H * 3 / 4, bl);
        pixel_at(f2, W * 3 / 4, H / 4, tr);
        pixel_at(f2, W / 4, H / 4, tl);
        printf("frame2 pixels: bottom-left rgba(%d,%d,%d) top-right rgba(%d,%d,%d) "
               "top-left rgba(%d,%d,%d)\n",
               bl[0], bl[1], bl[2], tr[0], tr[1], tr[2], tl[0], tl[1], tl[2]);
        CHECK(near(bl, 255, 0, 0), "bottom-left should be red");
        CHECK(near(tr, 0, 255, 0), "top-right should be green");
        CHECK(near(tl, 26, 51, 153), "top-left should be the clear color");
        CFRelease(f2);
    }
    bql_lock();

    /* --- goldfish sync: native fence -> TRIGGER_HOST_WAIT -> timeline_inc --- */
    {
        const int32_t attribs[] = { 0x3145 /* EGL_SYNC_NATIVE_FENCE_FD_ANDROID */,
                                    -1 /* EGL_NO_NATIVE_FENCE_FD_ANDROID */, 0x3038 };
        Packet pk = pk_begin(OP_rcCreateSyncKHR);
        pk_u32(&pk, 0x3144); /* EGL_SYNC_NATIVE_FENCE_ANDROID */
        pk_u32(&pk, sizeof(attribs));
        pk_bytes(&pk, attribs, sizeof(attribs));
        pk_u32(&pk, sizeof(attribs));
        pk_u32(&pk, 1);  /* destroy_when_signaled */
        pk_u32(&pk, 8);  /* glsync_out size */
        pk_u32(&pk, 8);  /* syncthread_out size */
        pk_send(gl, &pk);
        uint64_t glsync = 0, syncthread = 0;
        guest_read(gl, &glsync, 8);
        guest_read(gl, &syncthread, 8);
        printf("rcCreateSyncKHR: glsync=0x%llx syncthread=0x%llx\n", (unsigned long long)glsync,
               (unsigned long long)syncthread);
        CHECK(glsync && syncthread, "rcCreateSyncKHR handles");
        CHECK(s_trigger_wait != NULL, "trigger_wait not registered");
        if (glsync && s_trigger_wait) {
            const uint64_t timeline = 0x4242;
            /* what goldfish_sync does on CMD_TRIGGER_HOST_WAIT (vCPU, BQL held) */
            s_trigger_wait(glsync, syncthread, timeline);
            bql_unlock();
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_sec += 5;
            pthread_mutex_lock(&s_sync_lock);
            while (s_last_inc_timeline != timeline &&
                   pthread_cond_timedwait(&s_sync_cond, &s_sync_lock, &ts) != ETIMEDOUT) {
            }
            const int got = s_last_inc_timeline == timeline;
            const uint32_t count = s_last_inc_count;
            pthread_mutex_unlock(&s_sync_lock);
            bql_lock();
            printf("goldfish sync: timeline_inc(0x%llx, %u) %s\n", (unsigned long long)timeline,
                   count, got ? "received" : "NOT received");
            CHECK(got && count == 1, "fence signal via timeline_inc");
        }
    }

    /* --- Throughput: GLES clear + flush + post, waiting for each IOSurface frame --- */
    {
        const int n = 60;
        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        for (int i = 0; i < n; i++) {
            gl_clear_color(gl, (float)i / n, 0.5f, 1.0f - (float)i / n, 1.0f);
            rcN(gl, OP_glClear, 0, 1, 0x4000);
            (void)rcN(gl, OP_rcFlushWindowColorBuffer, 1, 1, surf);
            rcN(gl, OP_rcFBPost, 0, 1, cb2);
            (void)rc0(gl, OP_rcGetRendererVersion);
            bql_unlock();
            IOSurfaceRef f = wait_frame(3 + i);
            bql_lock();
            if (!f) {
                CHECK(f, "throughput: frame %d never arrived", i);
                break;
            }
            CFRelease(f);
        }
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
        printf("throughput: %d posted frames %dx%d in %.1f ms = %.2f ms/frame (%.1f fps)\n", n, W,
               H, ms, ms / n, n * 1000.0 / ms);
    }
    if (getenv("HARNESS_PROFILE")) {
        const int n = 60;
        struct timespec t0, t1;
#define ELAPSED_MS() ((t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6)
        clock_gettime(CLOCK_MONOTONIC, &t0);
        for (int i = 0; i < n; i++) (void)rc0(gl, OP_rcGetRendererVersion);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        printf("profile: rc round trip %.2f ms\n", ELAPSED_MS() / n);
        clock_gettime(CLOCK_MONOTONIC, &t0);
        for (int i = 0; i < n; i++) {
            gl_clear_color(gl, (float)i / n, 0.5f, 0.5f, 1.0f);
            rcN(gl, OP_glClear, 0, 1, 0x4000);
            (void)rcN(gl, OP_rcFlushWindowColorBuffer, 1, 1, surf);
        }
        clock_gettime(CLOCK_MONOTONIC, &t1);
        printf("profile: clear+flushWindowColorBuffer %.2f ms\n", ELAPSED_MS() / n);
        int base = s_frames;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        for (int i = 0; i < n; i++) {
            rcN(gl, OP_rcFBPost, 0, 1, cb2);
            (void)rc0(gl, OP_rcGetRendererVersion);
            bql_unlock();
            IOSurfaceRef f = wait_frame(base + i + 1);
            bql_lock();
            if (!f) break;
            CFRelease(f);
        }
        clock_gettime(CLOCK_MONOTONIC, &t1);
        printf("profile: post+readback+present %.2f ms\n", ELAPSED_MS() / n);
    }
    const int frames_before_compose = s_frames;

    /* --- Frame 3: hwcomposer host composition (rcCompose, what EmuHWC2 uses) --- */
    {
        uint32_t target = rcN(gl, OP_rcCreateColorBuffer, 1, 3, W, H, 0x1908);
        ComposeDeviceV2 dev;
        memset(&dev, 0, sizeof(dev));
        dev.version = 2;
        dev.displayId = 0;
        dev.targetHandle = target;
        dev.numLayers = 2;
        dev.layer[0] = (ComposeLayer){ .cbHandle = cb1, .composeMode = 2,
                                       .displayFrame = { 0, 0, W, H },
                                       .crop = { 0, 0, W, H }, .blendMode = 1, .alpha = 1.0f };
        dev.layer[1] = (ComposeLayer){ .cbHandle = 0, .composeMode = 3,
                                       .displayFrame = { W / 4, H / 4, W * 3 / 4, H * 3 / 4 },
                                       .crop = { 0, 0, 0, 0 }, .blendMode = 1, .alpha = 1.0f,
                                       .color = { 255, 255, 0, 255 } };
        Packet pk = pk_begin(OP_rcCompose);
        pk_u32(&pk, sizeof(dev));
        pk_u32(&pk, sizeof(dev));
        pk_bytes(&pk, &dev, sizeof(dev));
        pk_send(gl, &pk);
        int r = (int)read_u32(gl);
        printf("rcCompose = %d\n", r);
        CHECK(r == 0 || r == 1, "rcCompose = %d", r);
    }
    bql_unlock();
    IOSurfaceRef f3 = wait_frame(frames_before_compose + 1);
    CHECK(f3, "no frame after rcCompose");
    if (f3) {
        snprintf(path, sizeof(path), "%s/va_gfx_frame3_compose_%s.png", argv[2], backend);
        write_png(f3, path);
        uint8_t c[4], tl[4];
        pixel_at(f3, W / 2, H / 2, c);
        pixel_at(f3, 0, 0, tl);
        printf("frame3 pixels: center rgba(%d,%d,%d) top-left rgba(%d,%d,%d)\n", c[0], c[1], c[2],
               tl[0], tl[1], tl[2]);
        CHECK(near(c, 255, 255, 0), "center should be the yellow solid-color layer");
        CHECK(near(tl, 0, 0, 128), "top-left should be the gradient layer");
        CFRelease(f3);
    }
    bql_lock();

    CHECK(s_engine_calls_without_bql == 0, "%d engine calls without the BQL",
          s_engine_calls_without_bql);
    CHECK(s_present_with_bql == 0, "present called with the BQL held");
    printf("goldfish sync: trigger_wait %s, timeline_inc calls %d\n",
           s_trigger_wait ? "registered" : "not registered", s_timeline_incs);

    /*
     * Shutdown paths (HARNESS_EXIT):
     *   (unset)       board's order: close the pipes, then va_gfx_teardown() on the
     *                 "main thread" with the BQL held, twice (idempotent), then exit()
     *   live          exit() with open pipes and live render threads, no teardown
     *                 (QEMU SIGTERM without a shutdown handler)
     *   live-busy     like live, but with queued GL work and posts in flight
 *   atexit        exit(); an atexit handler registered before dlopen (so it runs
 *                 after libva_gfx's and ANGLE's static destructors) closes the
 *                 pipes and calls va_gfx_teardown() -- QEMU's exit-notifier order
 *   teardown-open va_gfx_teardown() with the pipes still open, then exit()
 *   teardown-stuck a render thread is wedged in the post path holding the
 *                 FrameBuffer lock (another waits on it); teardown must return
 *                 within VA_GFX_TEARDOWN_TIMEOUT_MS and exit() must not hang
     */
    const char *exit_mode = getenv("HARNESS_EXIT") ? getenv("HARNESS_EXIT") : "";
    printf("%s (%d failures)\n", failures ? "HARNESS FAILED" : "HARNESS PASSED", failures);
    if (!strcmp(exit_mode, "atexit")) {
        s_atexit_mode = 1;
        printf("exit: calling exit(); the exit notifier closes the pipes and tears down\n");
        exit(failures ? 1 : 0); /* BQL held, like QEMU's main loop thread */
    }
    if (!strcmp(exit_mode, "teardown-stuck")) {
        /* 1) wedge a render thread in the post path while it holds the FB lock */
        s_block_present = 1;
        rcN(gl, OP_rcFBPost, 0, 1, cb2);
        bql_unlock();
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 5;
        pthread_mutex_lock(&s_frame_lock);
        while (!s_present_entered &&
               pthread_cond_timedwait(&s_frame_cond, &s_frame_lock, &ts) != ETIMEDOUT) {
        }
        const int wedged = s_present_entered;
        pthread_mutex_unlock(&s_frame_lock);
        bql_lock();
        CHECK(wedged, "could not wedge a render thread");
        /* 2) a second render thread queues behind the FB lock (no reply read) */
        FakePipe *gl2 = guest_open("opengles");
        if (gl2) {
            uint32_t flags2 = 0;
            guest_write(gl2, &flags2, 4);
            rcN(gl2, OP_rcCreateColorBuffer, 0, 3, 64, 64, 0x1908);
        }
        usleep(200 * 1000);
        /* 3) teardown on the "main thread" with the BQL held must still return */
        struct timespec a, b;
        clock_gettime(CLOCK_MONOTONIC, &a);
        p_va_gfx_teardown();
        clock_gettime(CLOCK_MONOTONIC, &b);
        p_va_gfx_teardown();
        const double ms = (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6;
        const char *to = getenv("VA_GFX_TEARDOWN_TIMEOUT_MS");
        const double limit = (to ? atof(to) : 3000.0) + 1000.0;
        CHECK(ms < limit, "teardown took %.0f ms with a wedged render thread", ms);
        printf("exit: va_gfx_teardown (teardown-stuck, render thread wedged holding the "
               "FrameBuffer lock) took %.1f ms; %s\n", ms, failures ? "FAILED" : "ok");
        exit(failures ? 1 : 0); /* BQL held; wedged threads are left behind */
    }
    if (!strcmp(exit_mode, "live-busy")) {
        /* queue lots of GL work + posts, then exit while the render thread is busy */
        for (int i = 0; i < 300; i++) {
            gl_clear_color(gl, (float)(i % 10) / 10, 0.2f, 0.3f, 1.0f);
            rcN(gl, OP_glClear, 0, 1, 0x4000);
            rcN(gl, OP_rcFBPost, 0, 1, cb2);
        }
        printf("exit: calling exit() while the render thread is busy\n");
        exit(failures ? 1 : 0);
    }
    if (!strcmp(exit_mode, "live")) {
        printf("exit: calling exit() with live render threads and open pipes\n");
        exit(failures ? 1 : 0); /* BQL still held, like QEMU's main thread */
    }
    if (strcmp(exit_mode, "teardown-open") != 0) {
        if (ref) guest_close(ref);
        guest_close(gl);
        if (proc) guest_close(proc);
    }
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    p_va_gfx_teardown(); /* BQL held */
    clock_gettime(CLOCK_MONOTONIC, &t1);
    p_va_gfx_teardown(); /* idempotent */
    printf("exit: va_gfx_teardown (%s) took %.1f ms\n",
           exit_mode[0] ? exit_mode : "pipes closed",
           (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6);
    exit(failures ? 1 : 0); /* BQL still held */
}
