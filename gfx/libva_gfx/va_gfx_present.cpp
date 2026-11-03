// VirtualAndroid libva_gfx: delivers composed guest frames as IOSurfaces.
//
// gfxstream reads the posted ColorBuffer back (BGRA, bottom-up rows) on one
// of its threads; we copy it into a small ring of IOSurfaces and hand the
// surface to the embedder's VaGfxPresentFn. A surface is reused only when
// nobody else holds it (CFRetain'ed by the embedder or IOSurfaceIsInUse),
// so an embedder may keep displaying a frame until it receives the next one.
//
// TODO(zero-copy): render the final composition straight into an
// IOSurface-backed EGL pbuffer (EGL_ANGLE_iosurface_client_buffer).

#include "va_gfx_internal.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>

#include <cstring>
#include <mutex>
#include <vector>

namespace {

constexpr size_t kMaxSurfaces = 6;

std::mutex sLock;
VaGfxPresentFn sFn = nullptr;
void* sOpaque = nullptr;
std::vector<IOSurfaceRef> sPool;
size_t sNext = 0;
int sWidth = 0;
int sHeight = 0;
uint64_t sFrameNumber = 0;

void addNumber(CFMutableDictionaryRef dict, CFStringRef key, int64_t value) {
    CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &value);
    CFDictionarySetValue(dict, key, n);
    CFRelease(n);
}

IOSurfaceRef createSurface(int width, int height) {
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    addNumber(props, kIOSurfaceWidth, width);
    addNumber(props, kIOSurfaceHeight, height);
    addNumber(props, kIOSurfaceBytesPerElement, 4);
    addNumber(props, kIOSurfaceBytesPerRow,
              (int64_t)IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)width * 4));
    addNumber(props, kIOSurfacePixelFormat, 'BGRA');
    IOSurfaceRef s = IOSurfaceCreate(props);
    CFRelease(props);
    return s;
}

void clearPoolLocked() {
    for (auto s : sPool) CFRelease(s);
    sPool.clear();
    sNext = 0;
}

bool isFree(IOSurfaceRef s) {
    // Our pool holds exactly one reference.
    return !IOSurfaceIsInUse(s) && CFGetRetainCount(s) == 1;
}

IOSurfaceRef acquireLocked(int width, int height) {
    if (width != sWidth || height != sHeight) {
        clearPoolLocked();
        sWidth = width;
        sHeight = height;
    }
    for (size_t i = 0; i < sPool.size(); i++) {
        size_t idx = (sNext + i) % sPool.size();
        if (isFree(sPool[idx])) {
            sNext = (idx + 1) % sPool.size();
            return sPool[idx];
        }
    }
    if (sPool.size() < kMaxSurfaces) {
        IOSurfaceRef s = createSurface(width, height);
        if (s) {
            sPool.push_back(s);
            sNext = 0;
            return s;
        }
    }
    return nullptr;  // embedder holds every surface: drop this frame
}

}  // namespace

extern "C" void vagfx_present_init(int width, int height, VaGfxPresentFn fn, void* opaque) {
    std::lock_guard<std::mutex> lock(sLock);
    sFn = fn;
    sOpaque = opaque;
    sWidth = width;
    sHeight = height;
    for (int i = 0; i < 3; i++) {
        if (IOSurfaceRef s = createSurface(width, height)) sPool.push_back(s);
    }
}

extern "C" void vagfx_present_frame(int width, int height, int ydir, const unsigned char* bgra) {
    std::lock_guard<std::mutex> lock(sLock);
    if (!sFn || !bgra || width <= 0 || height <= 0) return;
    IOSurfaceRef s = acquireLocked(width, height);
    if (!s) return;

    IOSurfaceLock(s, 0, nullptr);
    auto* dst = static_cast<uint8_t*>(IOSurfaceGetBaseAddress(s));
    const size_t dstStride = IOSurfaceGetBytesPerRow(s);
    const size_t srcStride = (size_t)width * 4;
    for (int y = 0; y < height; y++) {
        // ydir == -1: source rows are bottom-to-top (GL readback order).
        const int srcRow = ydir < 0 ? height - 1 - y : y;
        memcpy(dst + (size_t)y * dstStride, bgra + (size_t)srcRow * srcStride, srcStride);
    }
    IOSurfaceUnlock(s, 0, nullptr);

    VaGfxFrame frame;
    frame.iosurface = (void*)s;
    frame.width = width;
    frame.height = height;
    frame.rotation_deg = 0;
    frame.frame_number = ++sFrameNumber;
    sFn(sOpaque, &frame);
}

extern "C" void vagfx_present_teardown(void) {
    std::lock_guard<std::mutex> lock(sLock);
    sFn = nullptr;
    sOpaque = nullptr;
    clearPoolLocked();
}
