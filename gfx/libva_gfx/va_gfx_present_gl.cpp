// VirtualAndroid libva_gfx: zero-copy presentation for the ANGLE backend.
//
// gfxstream (patched, see gfx/patches/gfxstream.patch) calls our hook on every
// post with its FrameBuffer GL context current and the posted ColorBuffer's
// texture name in the *underlying ANGLE context*. We blit that texture into
// an IOSurface-backed ANGLE pbuffer (EGL_ANGLE_iosurface_client_buffer) and
// hand the IOSurface to the embedder: no glReadPixels, no CPU copy. This is
// the same mechanism WebKit uses to composite WebGL on iOS.
//
// We call ANGLE directly (dlsym on the already-loaded libGLESv2), so every GL
// binding we touch is saved and restored to keep gfxstream's GLES translator
// state cache consistent.

#include "va_gfx_internal.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <dlfcn.h>

#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>

#define VLOG(fmt, ...) fprintf(stderr, "va_gfx: " fmt "\n", ##__VA_ARGS__)

namespace {

typedef void* EGLDisplay;
typedef void* EGLConfig;
typedef void* EGLSurface;
typedef void* EGLClientBuffer;
typedef int32_t EGLint;
typedef unsigned int EGLenum;
typedef unsigned int EGLBoolean;
typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef int GLsizei;
typedef unsigned int GLbitfield;
typedef unsigned char GLboolean;

constexpr EGLint EGL_NONE = 0x3038;
constexpr EGLint EGL_RED_SIZE = 0x3024, EGL_GREEN_SIZE = 0x3023, EGL_BLUE_SIZE = 0x3022,
                 EGL_ALPHA_SIZE = 0x3021, EGL_SURFACE_TYPE = 0x3033, EGL_PBUFFER_BIT = 0x0001,
                 EGL_BIND_TO_TEXTURE_RGBA = 0x303A, EGL_WIDTH = 0x3057, EGL_HEIGHT = 0x3056,
                 EGL_TEXTURE_TARGET = 0x3081, EGL_TEXTURE_FORMAT = 0x3080,
                 EGL_TEXTURE_RGBA = 0x305E, EGL_TEXTURE_2D = 0x305F, EGL_BACK_BUFFER = 0x3084,
                 EGL_EXTENSIONS = 0x3055, EGL_RENDERABLE_TYPE = 0x3040,
                 EGL_OPENGL_ES2_BIT = 0x0004;
constexpr EGLint EGL_IOSURFACE_ANGLE = 0x3454, EGL_IOSURFACE_PLANE_ANGLE = 0x345A,
                 EGL_TEXTURE_RECTANGLE_ANGLE = 0x345B, EGL_TEXTURE_TYPE_ANGLE = 0x345C,
                 EGL_TEXTURE_INTERNAL_FORMAT_ANGLE = 0x345D,
                 EGL_BIND_TO_TEXTURE_TARGET_ANGLE = 0x348D;
constexpr GLenum GL_TEXTURE_2D = 0x0DE1, GL_TEXTURE_RECTANGLE_ANGLE = 0x84F5,
                 GL_TEXTURE_BINDING_2D = 0x8069, GL_TEXTURE_BINDING_RECTANGLE_ANGLE = 0x84F6,
                 GL_READ_FRAMEBUFFER = 0x8CA8, GL_DRAW_FRAMEBUFFER = 0x8CA9,
                 GL_READ_FRAMEBUFFER_BINDING = 0x8CAA, GL_DRAW_FRAMEBUFFER_BINDING = 0x8CA6,
                 GL_COLOR_ATTACHMENT0 = 0x8CE0, GL_FRAMEBUFFER_COMPLETE = 0x8CD5,
                 GL_SCISSOR_TEST = 0x0C11, GL_COLOR_BUFFER_BIT = 0x4000, GL_NEAREST = 0x2600,
                 GL_BGRA_EXT = 0x80E1, GL_UNSIGNED_BYTE = 0x1401;

struct Fns {
    EGLDisplay (*GetCurrentDisplay)();
    const char* (*QueryString)(EGLDisplay, EGLint);
    EGLBoolean (*ChooseConfig)(EGLDisplay, const EGLint*, EGLConfig*, EGLint, EGLint*);
    EGLBoolean (*GetConfigAttrib)(EGLDisplay, EGLConfig, EGLint, EGLint*);
    EGLSurface (*CreatePbufferFromClientBuffer)(EGLDisplay, EGLenum, EGLClientBuffer, EGLConfig,
                                                const EGLint*);
    EGLBoolean (*BindTexImage)(EGLDisplay, EGLSurface, EGLint);
    EGLBoolean (*ReleaseTexImage)(EGLDisplay, EGLSurface, EGLint);
    EGLBoolean (*DestroySurface)(EGLDisplay, EGLSurface);
    void (*GenTextures)(GLsizei, GLuint*);
    void (*DeleteTextures)(GLsizei, const GLuint*);
    void (*BindTexture)(GLenum, GLuint);
    void (*GenFramebuffers)(GLsizei, GLuint*);
    void (*DeleteFramebuffers)(GLsizei, const GLuint*);
    void (*BindFramebuffer)(GLenum, GLuint);
    void (*FramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
    GLenum (*CheckFramebufferStatus)(GLenum);
    void (*BlitFramebuffer)(GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield,
                            GLenum);
    void (*GetIntegerv)(GLenum, GLint*);
    GLboolean (*IsEnabled)(GLenum);
    void (*Enable)(GLenum);
    void (*Disable)(GLenum);
    void (*Finish)();
};

struct Entry {
    EGLSurface pbuffer = nullptr;
    GLuint tex = 0;
    GLuint fbo = 0;
};

std::mutex sLock;
Fns f;
bool sResolved = false;
bool sFailed = false;
EGLConfig sConfig = nullptr;
GLenum sTexTarget = GL_TEXTURE_2D;
GLuint sReadFbo = 0;
uint64_t sGeneration = ~0ull;
std::map<IOSurfaceRef, Entry> sEntries;
EGLDisplay sDisplay = nullptr;

template <typename T>
bool load(void* lib, T* out, const char* name) {
    *out = reinterpret_cast<T>(dlsym(lib, name));
    if (!*out) VLOG("zero-copy: missing ANGLE symbol %s", name);
    return *out != nullptr;
}

void destroyEntries() {
    for (auto& it : sEntries) {
        Entry& e = it.second;
        if (e.fbo) f.DeleteFramebuffers(1, &e.fbo);
        if (e.pbuffer) {
            f.ReleaseTexImage(sDisplay, e.pbuffer, EGL_BACK_BUFFER);
            f.DestroySurface(sDisplay, e.pbuffer);
        }
        if (e.tex) f.DeleteTextures(1, &e.tex);
    }
    sEntries.clear();
}

bool ensureConfig(EGLDisplay dpy) {
    if (sConfig) return true;
    const char* exts = f.QueryString(dpy, EGL_EXTENSIONS);
    if (!exts || !strstr(exts, "EGL_ANGLE_iosurface_client_buffer")) {
        VLOG("zero-copy: EGL_ANGLE_iosurface_client_buffer not supported");
        return false;
    }
    const EGLint attribs[] = {EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
                              EGL_ALPHA_SIZE, 8, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                              EGL_BIND_TO_TEXTURE_RGBA, 1, EGL_RENDERABLE_TYPE,
                              EGL_OPENGL_ES2_BIT, EGL_NONE};
    EGLint n = 0;
    if (!f.ChooseConfig(dpy, attribs, &sConfig, 1, &n) || n < 1) {
        VLOG("zero-copy: no pbuffer config bindable to RGBA textures");
        sConfig = nullptr;
        return false;
    }
    EGLint target = EGL_TEXTURE_2D;
    f.GetConfigAttrib(dpy, sConfig, EGL_BIND_TO_TEXTURE_TARGET_ANGLE, &target);
    sTexTarget = target == EGL_TEXTURE_RECTANGLE_ANGLE ? GL_TEXTURE_RECTANGLE_ANGLE : GL_TEXTURE_2D;
    VLOG("zero-copy IOSurface presentation enabled (texture target %s)",
         sTexTarget == GL_TEXTURE_2D ? "2D" : "RECTANGLE");
    return true;
}

bool createEntry(IOSurfaceRef s, int w, int h, Entry* e) {
    const EGLint attribs[] = {EGL_WIDTH, w, EGL_HEIGHT, h, EGL_IOSURFACE_PLANE_ANGLE, 0,
                              EGL_TEXTURE_TARGET,
                              sTexTarget == GL_TEXTURE_2D ? EGL_TEXTURE_2D
                                                          : EGL_TEXTURE_RECTANGLE_ANGLE,
                              EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, (EGLint)GL_BGRA_EXT,
                              EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA, EGL_TEXTURE_TYPE_ANGLE,
                              (EGLint)GL_UNSIGNED_BYTE, EGL_NONE};
    e->pbuffer =
        f.CreatePbufferFromClientBuffer(sDisplay, EGL_IOSURFACE_ANGLE, s, sConfig, attribs);
    if (!e->pbuffer) {
        VLOG("zero-copy: eglCreatePbufferFromClientBuffer(IOSurface) failed");
        return false;
    }
    const GLenum bindingQuery = sTexTarget == GL_TEXTURE_2D ? GL_TEXTURE_BINDING_2D
                                                            : GL_TEXTURE_BINDING_RECTANGLE_ANGLE;
    GLint prevTex = 0;
    f.GetIntegerv(bindingQuery, &prevTex);
    f.GenTextures(1, &e->tex);
    f.BindTexture(sTexTarget, e->tex);
    const bool bound = f.BindTexImage(sDisplay, e->pbuffer, EGL_BACK_BUFFER);
    f.BindTexture(sTexTarget, (GLuint)prevTex);
    if (!bound) {
        VLOG("zero-copy: eglBindTexImage failed");
        return false;
    }
    f.GenFramebuffers(1, &e->fbo);
    vagfx_present_mark_idle(s);  // ANGLE holds its own IOSurface references now
    return true;
}

void postTextureHook(void*, uint32_t displayId, uint32_t tex, uint32_t width, uint32_t height) {
    if (displayId != 0 || !tex) return;
    std::lock_guard<std::mutex> lock(sLock);
    if (sFailed) return;
    EGLDisplay dpy = f.GetCurrentDisplay();
    if (!dpy || !ensureConfig(dpy)) {
        sFailed = true;
        vagfx_request_readback_fallback();
        return;
    }
    if (dpy != sDisplay) {
        sEntries.clear();
        sDisplay = dpy;
    }

    uint64_t generation = 0;
    IOSurfaceRef s = (IOSurfaceRef)vagfx_present_acquire((int)width, (int)height, &generation);
    if (!s) return;  // embedder holds every surface: drop the frame
    if (generation != sGeneration) {
        destroyEntries();
        sGeneration = generation;
    }
    Entry& e = sEntries[s];
    if (!e.pbuffer && !createEntry(s, (int)width, (int)height, &e)) {
        sEntries.erase(s);
        sFailed = true;
        vagfx_request_readback_fallback();
        return;
    }

    GLint prevRead = 0, prevDraw = 0;
    f.GetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevRead);
    f.GetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevDraw);
    const bool scissor = f.IsEnabled(GL_SCISSOR_TEST);
    if (!sReadFbo) f.GenFramebuffers(1, &sReadFbo);

    f.BindFramebuffer(GL_READ_FRAMEBUFFER, sReadFbo);
    f.FramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    f.BindFramebuffer(GL_DRAW_FRAMEBUFFER, e.fbo);
    f.FramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, sTexTarget, e.tex, 0);
    if (scissor) f.Disable(GL_SCISSOR_TEST);
    // ColorBuffer row 0 is the top of the screen, as is IOSurface row 0.
    f.BlitFramebuffer(0, 0, (GLint)width, (GLint)height, 0, 0, (GLint)width, (GLint)height,
                      GL_COLOR_BUFFER_BIT, GL_NEAREST);
    if (scissor) f.Enable(GL_SCISSOR_TEST);
    f.FramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
    f.BindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)prevRead);
    f.BindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)prevDraw);
    f.Finish();  // the IOSurface contents must be complete before the embedder sees it

    vagfx_present_submit(s, (int)width, (int)height);
}

}  // namespace

extern "C" {
typedef void (*gfxstream_post_texture_hook_t)(void*, uint32_t, uint32_t, uint32_t, uint32_t);
void gfxstream_set_post_texture_hook(gfxstream_post_texture_hook_t hook, void* ctx);
}

extern "C" bool vagfx_present_gl_enable(const char* angle_glesv2_path) {
    std::lock_guard<std::mutex> lock(sLock);
    if (!sResolved) {
        void* lib = dlopen(angle_glesv2_path, RTLD_NOW | RTLD_LOCAL);
        if (!lib) {
            VLOG("zero-copy: dlopen(%s): %s", angle_glesv2_path, dlerror());
            return false;
        }
        bool ok = true;
        ok &= load(lib, &f.GetCurrentDisplay, "EGL_GetCurrentDisplay");
        ok &= load(lib, &f.QueryString, "EGL_QueryString");
        ok &= load(lib, &f.ChooseConfig, "EGL_ChooseConfig");
        ok &= load(lib, &f.GetConfigAttrib, "EGL_GetConfigAttrib");
        ok &= load(lib, &f.CreatePbufferFromClientBuffer, "EGL_CreatePbufferFromClientBuffer");
        ok &= load(lib, &f.BindTexImage, "EGL_BindTexImage");
        ok &= load(lib, &f.ReleaseTexImage, "EGL_ReleaseTexImage");
        ok &= load(lib, &f.DestroySurface, "EGL_DestroySurface");
        ok &= load(lib, &f.GenTextures, "glGenTextures");
        ok &= load(lib, &f.DeleteTextures, "glDeleteTextures");
        ok &= load(lib, &f.BindTexture, "glBindTexture");
        ok &= load(lib, &f.GenFramebuffers, "glGenFramebuffers");
        ok &= load(lib, &f.DeleteFramebuffers, "glDeleteFramebuffers");
        ok &= load(lib, &f.BindFramebuffer, "glBindFramebuffer");
        ok &= load(lib, &f.FramebufferTexture2D, "glFramebufferTexture2D");
        ok &= load(lib, &f.CheckFramebufferStatus, "glCheckFramebufferStatus");
        ok &= load(lib, &f.BlitFramebuffer, "glBlitFramebuffer");
        ok &= load(lib, &f.GetIntegerv, "glGetIntegerv");
        ok &= load(lib, &f.IsEnabled, "glIsEnabled");
        ok &= load(lib, &f.Enable, "glEnable");
        ok &= load(lib, &f.Disable, "glDisable");
        ok &= load(lib, &f.Finish, "glFinish");
        if (!ok) return false;
        sResolved = true;
    }
    sFailed = false;
    gfxstream_set_post_texture_hook(postTextureHook, nullptr);
    return true;
}

extern "C" void vagfx_present_gl_disable(void) {
    gfxstream_set_post_texture_hook(nullptr, nullptr);
    std::lock_guard<std::mutex> lock(sLock);
    sEntries.clear();  // GL objects die with the renderer's context
    sConfig = nullptr;
    sReadFbo = 0;
    sDisplay = nullptr;
    sGeneration = ~0ull;
}
