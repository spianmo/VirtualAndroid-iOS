// VirtualAndroid libva_gfx: hosts the gfxstream renderer for a goldfish-pipe
// (gltransport=pipe) Android guest and bridges it to the engine through
// VaGfxEngineOps. This is the moral equivalent of the Android emulator's
// android-emu glue (opengles.cpp + android_pipe_device.cpp + goldfish_sync
// hookup), minus everything that needs the emulator UI.
//
// Threading contract (see gfx/README.md):
//  * Engine -> libva_gfx pipe callbacks arrive with the BQL held.
//  * libva_gfx -> engine pipe calls (pipe_host_signal_wake, pipe_host_close)
//    are always made with the BQL held: either directly
//    from inside an engine callback (same thread), or from libva_gfx's
//    "va-gfx-waker" thread, which takes engine->bql_lock() around them.
//    Renderer threads never call into the engine directly, which avoids the
//    BQL <-> RenderChannel lock inversion.
//  * sync_timeline_inc is called directly from gfxstream's SyncThread (no
//    BQL), as allowed by engine/qemu's goldfish_sync.h.
//
// Lifetime: nothing in this library runs from static destructors. All global
// state is heap-allocated and intentionally leaked, so a process that exits
// without va_gfx_teardown() (e.g. QEMU on SIGTERM) never joins renderer
// threads. va_gfx_teardown() is the only orderly shutdown; it is idempotent,
// bounded in time and safe to call with the BQL held. Once the process has
// started exiting (our atexit handler ran) teardown and all pipe callbacks
// are no-ops: exit() must never wait for, or call into, the renderer.

#include "va_gfx_internal.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <dlfcn.h>
#include <map>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <vector>

#include <TargetConditionals.h>

#include "aemu/base/GLObjectCounter.h"
#include "aemu/base/system/System.h"
#include "gfxstream/host/Features.h"
#include "host-common/AndroidPipe.h"
#include "host-common/HostmemIdMapping.h"
#include "host-common/MultiDisplay.h"
#include "host-common/RefcountPipe.h"
#include "host-common/VmLock.h"
#include "host-common/address_space_device.h"
#include "host-common/android_pipe_base.h"
#include "host-common/android_pipe_device.h"
#include "host-common/multi_display_agent.h"
#include "host-common/opengl/logger.h"
#include "host-common/opengles-pipe.h"
#include "host-common/opengles.h"
#include "host-common/refcount-pipe.h"
#include "host-common/sync_device.h"
#include "host-common/vm_operations.h"
#include "host-common/window_agent.h"
#include "render-utils/RenderLib.h"
#include "render-utils/render_api.h"
#include "ExitGate.h"

#define VLOG(fmt, ...) fprintf(stderr, "va_gfx: " fmt "\n", ##__VA_ARGS__)

namespace {

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

struct State {
    VaGfxConfig cfg = {};
    std::string glesBackend;
    VaGfxEngineOps engine = {};
    VaGfxPresentFn present = nullptr;
    void* presentOpaque = nullptr;
    gfxstream::RenderLibPtr renderLib;
    gfxstream::RendererPtr renderer;
    std::string rendererString;
    std::string vendorString;
    std::string versionString;
    int glesMajor = 2;
    int glesMinor = 0;
    bool initialized = false;
    bool servicesRegistered = false;
    bool readbackRegistered = false;
    // Set by va_gfx_teardown(): no new pipes, no engine calls from our threads.
    std::atomic<bool> shutdown{false};
    std::atomic<bool> teardownStarted{false};
    // Set by our atexit handler, which runs *before* ANGLE's and this
    // library's static destructors (it is registered last, at the end of
    // va_gfx_init). From then on nothing may touch the renderer, ANGLE or
    // gfxstream: an embedder exit notifier that calls va_gfx_teardown() or
    // closes pipes later in exit() would otherwise use destroyed globals.
    std::atomic<bool> processExiting{false};
};

// Never destroyed (see "Lifetime" above).
State& g = *new State;

// >0 while this thread is inside an engine -> libva_gfx callback (BQL held).
thread_local int t_inEngineCallback = 0;

struct EngineCallbackScope {
    EngineCallbackScope() { ++t_inEngineCallback; }
    ~EngineCallbackScope() { --t_inEngineCallback; }
};

// ---------------------------------------------------------------------------
// Deferred engine operations ("waker" thread)
// ---------------------------------------------------------------------------

struct DeferredOp {
    enum Kind { kWake, kClose } kind;
    VaGfxPipe* pipe;
    unsigned flags;
};

void performOp(const DeferredOp& op);

class Waker {
public:
    void start() {
        std::lock_guard<std::mutex> lock(mLock);
        if (mThread.joinable()) return;
        mQuit = false;
        mThread = std::thread([this] { run(); });
    }

    // Never joins: the waker may be blocked in bql_lock() while our caller
    // (va_gfx_teardown on the main thread) holds the BQL. Once it gets the
    // BQL it sees g.shutdown, drops its batch and exits.
    void stop() {
        {
            std::lock_guard<std::mutex> lock(mLock);
            mQuit = true;
            mQueue.clear();
        }
        mCv.notify_all();
        if (mThread.joinable()) mThread.detach();
    }

    void push(const DeferredOp& op) {
        {
            std::lock_guard<std::mutex> lock(mLock);
            mQueue.push_back(op);
        }
        mCv.notify_one();
    }

    // Called with the BQL held (pipe close), so it cannot race with run()'s
    // BQL-protected drain.
    void removeFor(VaGfxPipe* pipe) {
        std::lock_guard<std::mutex> lock(mLock);
        for (auto it = mQueue.begin(); it != mQueue.end();) {
            if (it->pipe == pipe) {
                it = mQueue.erase(it);
            } else {
                ++it;
            }
        }
    }

private:
    void run() {
        pthread_setname_np("va-gfx-waker");
        std::deque<DeferredOp> batch;
        for (;;) {
            {
                std::unique_lock<std::mutex> lock(mLock);
                mCv.wait(lock, [this] { return mQuit || !mQueue.empty(); });
                if (mQuit) return;
            }
            // Take the BQL *before* dequeuing so a concurrent guest close
            // (which runs under the BQL) either sees these ops still queued
            // and removes them, or runs after we are done with the pipe.
            if (g.engine.bql_lock) g.engine.bql_lock();
            {
                std::lock_guard<std::mutex> lock(mLock);
                batch.swap(mQueue);
            }
            if (!g.shutdown.load()) {
                for (const auto& op : batch) performOp(op);
            }
            batch.clear();
            if (g.engine.bql_unlock) g.engine.bql_unlock();
        }
    }

    std::mutex mLock;
    std::condition_variable mCv;
    std::deque<DeferredOp> mQueue;
    std::thread mThread;
    bool mQuit = false;
};

Waker& waker() {
    static Waker* w = new Waker();
    return *w;
}

void onProcessExit();  // atexit handler, defined below va_gfx_init

}  // namespace

// ---------------------------------------------------------------------------
// Pipe bridge: engine hwpipe <-> aemu AndroidPipe services
// ---------------------------------------------------------------------------

struct VaGfxPipe {
    // MUST stay first: aemu's AndroidPipe.cpp reads the hw funcs table
    // through `*(const AndroidPipeHwFuncs**)hwPipe`.
    const AndroidPipeHwFuncs* hwFuncs;
    void* hwpipe;     // the engine's guest-side pipe handle
    void* aemuPipe;   // android::AndroidPipe*
    int id;
    bool hostClosed;
    std::string service;
};

namespace {

std::atomic<int> sNextPipeId{1};

void performOp(const DeferredOp& op) {
    if (g.shutdown.load()) return;
    switch (op.kind) {
        case DeferredOp::kWake:
            if (!op.pipe->hostClosed && g.engine.pipe_host_signal_wake) {
                g.engine.pipe_host_signal_wake(op.pipe->hwpipe, op.flags);
            }
            break;
        case DeferredOp::kClose:
            if (!op.pipe->hostClosed && g.engine.pipe_host_close) {
                op.pipe->hostClosed = true;
                g.engine.pipe_host_close(op.pipe->hwpipe);
            }
            break;
    }
}

void hwCloseFromHost(void* hw) {
    auto* p = static_cast<VaGfxPipe*>(hw);
    DeferredOp op{DeferredOp::kClose, p, 0};
    if (t_inEngineCallback) {
        performOp(op);
    } else {
        waker().push(op);
    }
}

void hwSignalWake(void* hw, unsigned flags) {
    auto* p = static_cast<VaGfxPipe*>(hw);
    DeferredOp op{DeferredOp::kWake, p, flags};
    if (t_inEngineCallback) {
        performOp(op);
    } else {
        waker().push(op);
    }
}

int hwGetPipeId(void* hw) { return static_cast<VaGfxPipe*>(hw)->id; }

const AndroidPipeHwFuncs kHwFuncs = {
    hwCloseFromHost,
    hwSignalWake,
    hwGetPipeId,
};

}  // namespace

extern "C" VaGfxPipe* vagfx_pipe_open(void* hwpipe, const char* service, const char* args) {
    EngineCallbackScope scope;
    if (g.shutdown.load() || g.processExiting.load()) {
        VLOG("guest opened '%s' after va_gfx_teardown(); refusing", service);
        return nullptr;
    }
    if (!g.renderer) {
        VLOG("guest opened '%s' before the renderer exists", service);
        return nullptr;
    }
    auto* p = new VaGfxPipe{&kHwFuncs, hwpipe, nullptr, sNextPipeId++, false, service};

    // Reuse aemu's connector logic: it owns the service registry populated by
    // android_init_opengles_pipe()/android_init_refcount_pipe().
    void* pipe = android_pipe_guest_open(p);
    std::string conn = std::string("pipe:") + service;
    if (args && *args) {
        conn += ":";
        conn += args;
    }
    AndroidPipeBuffer buf = {reinterpret_cast<uint8_t*>(&conn[0]), conn.size() + 1};
    void* connector = pipe;
    int r = android_pipe_guest_send(&pipe, &buf, 1);
    if (r != static_cast<int>(conn.size() + 1) || pipe == connector) {
        VLOG("failed to create pipe service '%s' (%d)", service, r);
        delete static_cast<android::AndroidPipe*>(pipe);
        delete p;
        return nullptr;
    }
    p->aemuPipe = pipe;
    return p;
}

extern "C" void vagfx_pipe_close(VaGfxPipe* p) {
    EngineCallbackScope scope;
    if (!p) return;
    if (g.processExiting.load()) return;  // leak: don't wake render threads during exit()
    if (p->aemuPipe) {
        android_pipe_guest_close(p->aemuPipe, PIPE_CLOSE_GRACEFUL);
        p->aemuPipe = nullptr;
    }
    waker().removeFor(p);
    delete p;
}

extern "C" int vagfx_pipe_send(VaGfxPipe* p, const void* buffers, int n) {
    EngineCallbackScope scope;
    if (g.processExiting.load()) return PIPE_ERROR_IO;
    return android_pipe_guest_send(&p->aemuPipe, static_cast<const AndroidPipeBuffer*>(buffers),
                                   n);
}

extern "C" int vagfx_pipe_recv(VaGfxPipe* p, void* buffers, int n) {
    EngineCallbackScope scope;
    if (g.processExiting.load()) return PIPE_ERROR_IO;
    return android_pipe_guest_recv(p->aemuPipe, static_cast<AndroidPipeBuffer*>(buffers), n);
}

extern "C" unsigned vagfx_pipe_poll(VaGfxPipe* p) {
    EngineCallbackScope scope;
    if (g.processExiting.load()) return PIPE_POLL_HUP;
    return android_pipe_guest_poll(p->aemuPipe);
}

extern "C" void vagfx_pipe_wake_on(VaGfxPipe* p, int flags) {
    EngineCallbackScope scope;
    if (g.processExiting.load()) return;
    android_pipe_guest_wake_on(p->aemuPipe, static_cast<unsigned>(flags));
}

// ---------------------------------------------------------------------------
// goldfish_sync hookup
// ---------------------------------------------------------------------------

namespace {

uint64_t syncCreateTimeline() {
    return g.engine.sync_create_timeline ? g.engine.sync_create_timeline() : 0;
}

int syncCreateFence(uint64_t timeline, uint32_t pt) {
    return g.engine.sync_create_fence ? g.engine.sync_create_fence(timeline, pt) : -1;
}

void syncTimelineInc(uint64_t timeline, uint32_t count) {
    // engine/qemu goldfish_sync_timeline_inc() only queues and may be called
    // from any thread with or without the BQL (hw/android/goldfish_sync.h),
    // so signal fences directly from gfxstream's SyncThread: lowest latency.
    if (g.shutdown.load()) return;
    if (g.engine.sync_timeline_inc) g.engine.sync_timeline_inc(timeline, count);
}

void syncDestroyTimeline(uint64_t timeline) {
    if (g.engine.sync_destroy_timeline) g.engine.sync_destroy_timeline(timeline);
}

void syncRegisterTriggerWait(emugl_sync_trigger_wait_t fn) {
    // Render threads re-register on every rcCreateSyncKHR; ignore after teardown.
    if (g.shutdown.load()) return;
    if (g.engine.sync_register_trigger_wait) g.engine.sync_register_trigger_wait(fn);
}

bool syncDeviceExists() {
    return g.engine.sync_timeline_inc && g.engine.sync_register_trigger_wait;
}

// ---------------------------------------------------------------------------
// Emulator "agents" (headless implementations)
// ---------------------------------------------------------------------------

// Leaked on purpose: render threads may use them during process exit.
std::mutex& sDisplayLock = *new std::mutex;
std::map<uint32_t, android::MultiDisplayInfo>& sDisplays =
    *new std::map<uint32_t, android::MultiDisplayInfo>;

QAndroidMultiDisplayAgent sMultiDisplayAgent;
QAndroidEmulatorWindowAgent sWindowAgent;
QAndroidVmOperations sVmOps;

void initAgents() {
    memset(&sMultiDisplayAgent, 0, sizeof(sMultiDisplayAgent));
    sMultiDisplayAgent.notifyDisplayChanges = []() -> bool { return true; };
    sMultiDisplayAgent.setMultiDisplay = [](uint32_t id, int32_t x, int32_t y, uint32_t w,
                                            uint32_t h, uint32_t dpi, uint32_t flag,
                                            bool add) -> int {
        std::lock_guard<std::mutex> lock(sDisplayLock);
        if (!add) {
            sDisplays.erase(id);
            return 0;
        }
        auto& d = sDisplays[id];
        d.pos_x = x;
        d.pos_y = y;
        d.width = w;
        d.height = h;
        d.originalWidth = w;
        d.originalHeight = h;
        d.dpi = dpi;
        d.flag = flag;
        d.enabled = true;
        return 0;
    };
    sMultiDisplayAgent.getMultiDisplay = [](uint32_t id, int32_t* x, int32_t* y, uint32_t* w,
                                            uint32_t* h, uint32_t* dpi, uint32_t* flag,
                                            bool* enabled) -> bool {
        std::lock_guard<std::mutex> lock(sDisplayLock);
        auto it = sDisplays.find(id);
        if (it == sDisplays.end()) {
            if (enabled) *enabled = false;
            return false;
        }
        const auto& d = it->second;
        if (x) *x = d.pos_x;
        if (y) *y = d.pos_y;
        if (w) *w = d.width;
        if (h) *h = d.height;
        if (dpi) *dpi = d.dpi;
        if (flag) *flag = d.flag;
        if (enabled) *enabled = d.enabled;
        return true;
    };
    sMultiDisplayAgent.getNextMultiDisplay = [](int32_t startId, uint32_t* id, int32_t* x,
                                                int32_t* y, uint32_t* w, uint32_t* h,
                                                uint32_t* dpi, uint32_t* flag,
                                                uint32_t* cb) -> bool {
        std::lock_guard<std::mutex> lock(sDisplayLock);
        uint32_t key = startId < 0 ? 0 : static_cast<uint32_t>(startId) + 1;
        auto it = sDisplays.lower_bound(key);
        if (it == sDisplays.end()) return false;
        if (id) *id = it->first;
        if (x) *x = it->second.pos_x;
        if (y) *y = it->second.pos_y;
        if (w) *w = it->second.width;
        if (h) *h = it->second.height;
        if (dpi) *dpi = it->second.dpi;
        if (flag) *flag = it->second.flag;
        if (cb) *cb = it->second.cb;
        return true;
    };
    sMultiDisplayAgent.isMultiDisplayEnabled = []() -> bool {
        std::lock_guard<std::mutex> lock(sDisplayLock);
        return sDisplays.size() > 1;
    };
    sMultiDisplayAgent.getCombinedDisplaySize = [](uint32_t* w, uint32_t* h) {
        std::lock_guard<std::mutex> lock(sDisplayLock);
        auto it = sDisplays.find(0);
        if (w) *w = it == sDisplays.end() ? 0 : it->second.width;
        if (h) *h = it == sDisplays.end() ? 0 : it->second.height;
    };
    sMultiDisplayAgent.multiDisplayParamValidate = [](uint32_t, uint32_t, uint32_t, uint32_t,
                                                      uint32_t) -> bool { return true; };
    sMultiDisplayAgent.translateCoordination = [](uint32_t*, uint32_t*, uint32_t*) -> bool {
        return true;
    };
    sMultiDisplayAgent.setGpuMode = [](bool, uint32_t, uint32_t) {};
    sMultiDisplayAgent.createDisplay = [](uint32_t* displayId) -> int {
        if (!displayId) return -1;
        std::lock_guard<std::mutex> lock(sDisplayLock);
        if (sDisplays.size() >= android::MultiDisplay::s_maxNumMultiDisplay) return -1;
        if (sDisplays.count(*displayId)) return 0;
        if (*displayId == android::MultiDisplay::s_invalidIdMultiDisplay) {
            for (uint32_t i = android::MultiDisplay::s_displayIdInternalBegin;
                 i < android::MultiDisplay::s_maxNumMultiDisplay; i++) {
                if (!sDisplays.count(i)) {
                    *displayId = i;
                    break;
                }
            }
        }
        if (*displayId == android::MultiDisplay::s_invalidIdMultiDisplay) return -1;
        sDisplays.emplace(*displayId, android::MultiDisplayInfo());
        return 0;
    };
    sMultiDisplayAgent.destroyDisplay = [](uint32_t displayId) -> int {
        std::lock_guard<std::mutex> lock(sDisplayLock);
        sDisplays.erase(displayId);
        return 0;
    };
    sMultiDisplayAgent.setDisplayPose = [](uint32_t displayId, int32_t x, int32_t y, uint32_t w,
                                           uint32_t h, uint32_t dpi) -> int {
        std::lock_guard<std::mutex> lock(sDisplayLock);
        auto it = sDisplays.find(displayId);
        if (it == sDisplays.end()) return -1;
        it->second.pos_x = x;
        it->second.pos_y = y;
        it->second.width = w;
        it->second.height = h;
        it->second.dpi = dpi;
        return 0;
    };
    sMultiDisplayAgent.getDisplayPose = [](uint32_t displayId, int32_t* x, int32_t* y,
                                           uint32_t* w, uint32_t* h) -> int {
        std::lock_guard<std::mutex> lock(sDisplayLock);
        auto it = sDisplays.find(displayId);
        if (it == sDisplays.end()) return -1;
        if (x) *x = it->second.pos_x;
        if (y) *y = it->second.pos_y;
        if (w) *w = it->second.width;
        if (h) *h = it->second.height;
        return 0;
    };
    sMultiDisplayAgent.getDisplayColorBuffer = [](uint32_t displayId, uint32_t* cb) -> int {
        std::lock_guard<std::mutex> lock(sDisplayLock);
        auto it = sDisplays.find(displayId);
        if (it == sDisplays.end()) return -1;
        *cb = it->second.cb;
        return 0;
    };
    sMultiDisplayAgent.getColorBufferDisplay = [](uint32_t cb, uint32_t* displayId) -> int {
        std::lock_guard<std::mutex> lock(sDisplayLock);
        for (const auto& it : sDisplays) {
            if (it.second.cb == cb) {
                *displayId = it.first;
                return 0;
            }
        }
        return -1;
    };
    sMultiDisplayAgent.setDisplayColorBuffer = [](uint32_t displayId, uint32_t cb) -> int {
        std::lock_guard<std::mutex> lock(sDisplayLock);
        auto it = sDisplays.find(displayId);
        if (it == sDisplays.end()) return -1;
        it->second.cb = cb;
        return 0;
    };
    sMultiDisplayAgent.isMultiDisplayWindow = []() -> bool { return false; };
    sMultiDisplayAgent.performRotation = [](int) {};
    sMultiDisplayAgent.isPixelFold = []() -> bool { return false; };

    memset(&sWindowAgent, 0, sizeof(sWindowAgent));
    sWindowAgent.initUI = []() {};
    sWindowAgent.getEmulatorWindow = []() -> EmulatorWindow* { return nullptr; };
    sWindowAgent.rotate90Clockwise = []() -> bool { return true; };
    sWindowAgent.rotate = [](int) -> bool { return true; };
    sWindowAgent.getRotation = []() -> int { return 0; };
    sWindowAgent.showMessage = [](const char* msg, WindowMessageType, int) {
        VLOG("renderer message: %s", msg);
    };
    sWindowAgent.showMessageWithDismissCallback = [](const char* msg, WindowMessageType,
                                                     const char*, void*, void (*)(void*), int) {
        VLOG("renderer message: %s", msg);
    };
    sWindowAgent.fold = [](bool) -> bool { return true; };
    sWindowAgent.isFolded = []() -> bool { return false; };
    sWindowAgent.getFoldedArea = [](int*, int*, int*, int*) -> bool { return false; };
    sWindowAgent.updateFoldablePostureIndicator = [](bool) {};
    sWindowAgent.setPosture = [](int) -> bool { return true; };
    sWindowAgent.setUIDisplayRegion = [](int, int, int, int, bool) {};
    sWindowAgent.setNoSkin = []() {};
    sWindowAgent.restoreSkin = []() {};
    sWindowAgent.updateUIMultiDisplayPage = [](uint32_t) {};
    sWindowAgent.addMultiDisplayWindow = [](uint32_t, bool, uint32_t, uint32_t) -> bool {
        return true;
    };
    sWindowAgent.paintMultiDisplayWindow = [](uint32_t, uint32_t) -> bool { return true; };
    sWindowAgent.getMonitorRect = [](uint32_t* w, uint32_t* h) -> bool {
        if (w) *w = g.cfg.display_width;
        if (h) *h = g.cfg.display_height;
        return true;
    };
    // On Apple platforms gfxstream routes PostWorker tasks through the UI
    // thread. We are headless: run them synchronously on the caller (the
    // renderer's post thread).
    sWindowAgent.runOnUiThread = [](UiUpdateFunc f, void* data, bool) { f(data); };
    sWindowAgent.isRunningInUiThread = []() -> bool { return false; };
    sWindowAgent.hasWindow = []() -> bool { return false; };

    memset(&sVmOps, 0, sizeof(sVmOps));
    sVmOps.vmStop = []() -> bool { return true; };
    sVmOps.vmStart = []() -> bool { return true; };
    sVmOps.vmReset = []() {};
    sVmOps.vmShutdown = []() {};
    sVmOps.vmPause = []() -> bool { return true; };
    sVmOps.vmResume = []() -> bool { return true; };
    sVmOps.vmIsRunning = []() -> bool { return true; };
    sVmOps.setSnapshotCallbacks = [](void*, const SnapshotCallbacks*) {};
    sVmOps.mapUserBackedRam = [](uint64_t, void*, uint64_t) {};
    sVmOps.unmapUserBackedRam = [](uint64_t, uint64_t) {};
    sVmOps.getVmConfiguration = [](VmConfiguration*) {};
    sVmOps.setFailureReason = [](const char*, int) {};
    sVmOps.setExiting = []() {};
    sVmOps.allowRealAudio = [](bool) {};
    sVmOps.physicalMemoryGetAddr = [](uint64_t) -> void* { return nullptr; };
    sVmOps.isRealAudioAllowed = []() -> bool { return false; };
    sVmOps.setSkipSnapshotSave = [](bool) {};
    sVmOps.isSnapshotSaveSkipped = []() -> bool { return true; };
    sVmOps.hostmemRegister = android_emulation_hostmem_register;
    sVmOps.hostmemUnregister = android_emulation_hostmem_unregister;
    sVmOps.hostmemGetInfo = android_emulation_hostmem_get_info;
    sVmOps.vulkanInstanceRegister = [](uint64_t, const char*) {};
    sVmOps.vulkanInstanceUnregister = [](uint64_t) {};
    sVmOps.vulkanInstanceEnumerate = [](uint32_t* count, uint64_t*, char**) {
        if (count) *count = 0;
    };
    sVmOps.setSkipSnapshotSaveReason = [](SnapshotSkipReason) {};
    sVmOps.getSkipSnapshotSaveReason = []() -> SnapshotSkipReason {
        return SNAPSHOT_SKIP_UNKNOWN;
    };
    sVmOps.setStatSnapshotUseVulkan = []() {};
    sVmOps.snapshotUseVulkan = []() -> bool { return false; };
}

// ---------------------------------------------------------------------------
// Backend selection helpers
// ---------------------------------------------------------------------------

bool fileExists(const std::string& path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0;
}

std::string dirOfThisLibrary() {
    Dl_info info;
    if (dladdr(reinterpret_cast<void*>(&dirOfThisLibrary), &info) && info.dli_fname) {
        std::string p = info.dli_fname;
        auto slash = p.rfind('/');
        if (slash != std::string::npos) return p.substr(0, slash);
    }
    return ".";
}

// Finds ANGLE's libGLESv2 next to libva_gfx (dylib layout), as a sibling
// framework (iOS app bundle layout), or in $VA_GFX_ANGLE_DIR. ANGLE's
// libGLESv2 also exports the EGL entry points (as EGL_Foo, which our patched
// gfxstream loader accepts), so it serves as both the EGL and GLES library;
// ANGLE's libEGL shim is not needed.
void setupAngleLibraryPaths() {
    if (getenv("GFXSTREAM_EGL_LIB") && getenv("GFXSTREAM_GLESV2_LIB")) return;
    std::vector<std::string> dirs;
    if (const char* d = getenv("VA_GFX_ANGLE_DIR")) dirs.push_back(d);
    std::string self = dirOfThisLibrary();
    dirs.push_back(self);
    dirs.push_back(self + "/..");  // .../Frameworks/va_gfx.framework/..
    dirs.push_back(self + "/../lib");
    for (const auto& d : dirs) {
        const std::string candidates[] = {
            d + "/libGLESv2.dylib",
            d + "/GLESv2.framework/GLESv2",
            d + "/GLESv2.framework/Versions/A/GLESv2",
            d + "/libGLESv2.framework/libGLESv2",
        };
        for (const auto& c : candidates) {
            if (fileExists(c)) {
                setenv("GFXSTREAM_EGL_LIB", c.c_str(), 1);
                setenv("GFXSTREAM_GLESV2_LIB", c.c_str(), 1);
                VLOG("ANGLE: %s", c.c_str());
                return;
            }
        }
    }
    VLOG("ANGLE libGLESv2 not found next to %s; relying on the default dlopen search",
         self.c_str());
}

// Vulkan: gfxstream dlopens a "loader"; MoltenVK exports the full Vulkan API
// (vkGetInstanceProcAddr etc.), so we point it straight at MoltenVK (no
// Khronos loader needed, which is also how iOS apps use MoltenVK).
bool setupVulkanLibraryPath() {
    if (getenv("ANDROID_EMU_VK_LOADER_PATH")) return true;
    std::vector<std::string> candidates;
    if (const char* p = getenv("VA_GFX_MOLTENVK_PATH")) candidates.push_back(p);
    std::string self = dirOfThisLibrary();
    for (const std::string& d : {self, self + "/..", self + "/../lib"}) {
        candidates.push_back(d + "/libMoltenVK.dylib");
        candidates.push_back(d + "/MoltenVK.framework/MoltenVK");
        candidates.push_back(d + "/MoltenVK.framework/Versions/A/MoltenVK");
        candidates.push_back(d + "/libvulkan.dylib");
    }
    for (const auto& c : candidates) {
        if (fileExists(c)) {
            setenv("ANDROID_EMU_VK_LOADER_PATH", c.c_str(), 1);
            VLOG("Vulkan: %s", c.c_str());
            return true;
        }
    }
    VLOG("Vulkan requested but no MoltenVK found next to %s; disabling Vulkan", self.c_str());
    return false;
}

void buildFeatures(gfxstream::host::FeatureSet* f, bool vulkan, bool sync) {
#define VA_FEATURE(name, value) GFXSTREAM_SET_FEATURE_ON_CONDITION(f, name, value)
    // Matches what the official emulator negotiates with an API 33
    // goldfish-pipe guest, minus features needing devices we do not have
    // (goldfish DMA, address-space graphics, virtio-gpu).
    VA_FEATURE(GlAsyncSwap, sync);
    VA_FEATURE(GlDirectMem, false);
    VA_FEATURE(GlDma, false);
    VA_FEATURE(GlDma2, false);
    VA_FEATURE(GlesDynamicVersion, true);
    VA_FEATURE(GlPipeChecksum, false);
    VA_FEATURE(GlProgramBinaryLinkStatus, false);
    VA_FEATURE(GrallocSync, false);
    VA_FEATURE(HasSharedSlotsHostMemoryAllocator, false);
    VA_FEATURE(HostComposition, true);
    VA_FEATURE(HwcMultiConfigs, true);
    VA_FEATURE(Minigbm, false);
    VA_FEATURE(NativeTextureDecompression, false);
    VA_FEATURE(NoDelayCloseColorBuffer, false);
    VA_FEATURE(PlayStoreImage, false);
    VA_FEATURE(RefCountPipe, true);
    VA_FEATURE(VirtioGpuFenceContexts, false);
    VA_FEATURE(VirtioGpuNativeSync, false);
    VA_FEATURE(VirtioGpuNext, false);
    VA_FEATURE(ExternalBlob, false);
    VA_FEATURE(SystemBlob, false);
    VA_FEATURE(GuestVulkanOnly, false);
    VA_FEATURE(AsyncComposeSupport, false);
    VA_FEATURE(Yuv420888ToNv21, true);
    VA_FEATURE(YuvCache, true);
    VA_FEATURE(Vulkan, vulkan);
    VA_FEATURE(VulkanBatchedDescriptorSetUpdate, false);
    VA_FEATURE(VulkanIgnoredHandles, vulkan);
    VA_FEATURE(VulkanNullOptionalStrings, vulkan);
    VA_FEATURE(VulkanQueueSubmitWithCommands, vulkan);
    VA_FEATURE(VulkanShaderFloat16Int8, vulkan);
    VA_FEATURE(VulkanVirtualQueue, vulkan);
#undef VA_FEATURE
}

void onPost(void*, uint32_t displayId, int width, int height, int ydir, int, int,
            unsigned char* pixels) {
    if (displayId != 0) return;
    vagfx_present_frame(width, height, ydir, pixels);
}

}  // namespace

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

extern "C" __attribute__((visibility("default"))) int va_gfx_init(const VaGfxConfig* config,
                                                                  const VaGfxEngineOps* engine,
                                                                  VaGfxPresentFn present,
                                                                  void* opaque) {
    if (g.initialized) return 0;
    if (g.teardownStarted.load()) {
        VLOG("va_gfx_init after va_gfx_teardown() is not supported in the same process");
        return -1;
    }
    if (!config || !engine || !engine->pipe_add_type) return -1;

    g.cfg = *config;
    if (g.cfg.display_width <= 0) g.cfg.display_width = 1080;
    if (g.cfg.display_height <= 0) g.cfg.display_height = 2340;
    if (g.cfg.display_dpi <= 0) g.cfg.display_dpi = 440;
    if (g.cfg.refresh_hz <= 0) g.cfg.refresh_hz = 60;
    g.glesBackend = config->gles_backend ? config->gles_backend : "angle";
    if (const char* env = getenv("VA_GFX_GLES_BACKEND")) g.glesBackend = env;
    g.cfg.gles_backend = g.glesBackend.c_str();
    g.engine = *engine;
    g.present = present;
    g.presentOpaque = opaque;

#if TARGET_OS_IPHONE || defined(VA_GFX_IOS)
    const bool angle = true;  // no desktop GL on iOS
#else
    const bool angle = g.glesBackend != "native";
#endif
    const int w = g.cfg.display_width;
    const int h = g.cfg.display_height;
    const bool sync = syncDeviceExists();
    VLOG("init %dx%d@%dHz dpi %d, GLES backend %s, Vulkan %s, goldfish sync %s", w, h,
         g.cfg.refresh_hz, g.cfg.display_dpi, angle ? "ANGLE" : "native",
         g.cfg.enable_vulkan ? "on" : "off", sync ? "on" : "off");

    android::base::setEnvironmentVariable("ANDROID_EMU_HEADLESS", "1");
    // Deliver each posted frame synchronously (no async-readback frame lag).
    setenv("GFXSTREAM_DISABLE_ASYNC_READBACK", "1", 0);
    if (angle) {
        android::base::setEnvironmentVariable("ANDROID_EGL_ON_EGL", "1");
        setupAngleLibraryPaths();
        if (!getenv("ANGLE_DEFAULT_PLATFORM")) setenv("ANGLE_DEFAULT_PLATFORM", "metal", 1);
    }

    if (g.cfg.enable_vulkan && !setupVulkanLibraryPath()) g.cfg.enable_vulkan = false;

    initAgents();
    sMultiDisplayAgent.setMultiDisplay(0, 0, 0, w, h, g.cfg.display_dpi, 0, true);

    android_prepareOpenglesEmulation();
    g.renderLib = gfxstream::initLibrary();
    android_setOpenglesEmulation(g.renderLib.get(), nullptr, nullptr);

    auto& lib = *g.renderLib;
    lib.setRenderer(angle ? SELECTED_RENDERER_ANGLE_INDIRECT : SELECTED_RENDERER_HOST);
    lib.setAvdInfo(true /* phone */, 33);
    lib.setSyncDevice(syncCreateTimeline, syncCreateFence, syncTimelineInc, syncDestroyTimeline,
                      syncRegisterTriggerWait, syncDeviceExists);
    lib.setLogger(android_opengl_logger_write);
    lib.setGLObjectCounter(android::base::GLObjectCounter::get());
    emugl_dma_ops dma = {
        [](uint64_t) -> void* { return nullptr; },
        [](uint64_t) {},
    };
    lib.setDmaOps(dma);
    lib.setVmOps(sVmOps);
    lib.setAddressSpaceDeviceControlOps(get_address_space_device_control_ops());
    lib.setWindowOps(sWindowAgent, sMultiDisplayAgent);

    gfxstream::host::FeatureSet features;
    buildFeatures(&features, g.cfg.enable_vulkan, sync);

    g.renderer = lib.initRenderer(w, h, features, false /* useSubWindow */, angle /* egl2egl */);
    if (!g.renderer) {
        VLOG("gfxstream initRenderer failed");
        g.renderLib.reset();
        return -1;
    }
    android_setOpenglesRenderer(&g.renderer);
    android::emulation::registerOnLastRefCallback(lib.getOnLastColorBufferRef());

    g.renderer->setDisplayConfigs(0, w, h, g.cfg.display_dpi, g.cfg.display_dpi);
    g.renderer->setDisplayActiveConfig(0);
    g.renderer->setVsyncHz(g.cfg.refresh_hz);

    auto strings = g.renderer->getHardwareStrings();
    g.vendorString = strings.vendor;
    g.rendererString = strings.renderer;
    g.versionString = strings.version;
    lib.getGlesVersion(&g.glesMajor, &g.glesMinor);
    VLOG("GL vendor [%s] renderer [%s] version [%s], guest GLES %d.%d", g.vendorString.c_str(),
         g.rendererString.c_str(), g.versionString.c_str(), g.glesMajor, g.glesMinor);

    // aemu pipe services; their wakes reach us through kHwFuncs.
    android::AndroidPipe::initThreading(android::VmLock::get());
    android_init_opengles_pipe();
    android_opengles_pipe_set_recv_mode(0 /* Android goldfish pipe */);
    android_init_refcount_pipe();

    waker().start();
    vagfx_present_init(w, h, present, opaque);
    // Zero-copy (ANGLE): posted ColorBuffers are blitted into IOSurfaces on
    // the GPU. Otherwise (native CGL, or VA_GFX_FORCE_READBACK=1): synchronous
    // BGRA readback into IOSurfaces.
    bool zeroCopy = false;
    if (angle && !getenv("VA_GFX_FORCE_READBACK")) {
        const char* glesLib = getenv("GFXSTREAM_GLESV2_LIB");
        zeroCopy = vagfx_present_gl_enable(glesLib ? glesLib : "libGLESv2.dylib");
    }
    if (!zeroCopy) {
        g.renderer->setPostCallback(onPost, nullptr, true /* BGRA readback */, 0);
        g.readbackRegistered = true;
    }
    VLOG("frame delivery: %s", zeroCopy ? "zero-copy IOSurface blit" : "readback");

    // Last, so it runs first at exit (atexit is LIFO): before ANGLE (dlopened
    // above) and libva_gfx static destructors, and before any embedder exit
    // notifier registered earlier (QEMU's).
    atexit(onProcessExit);

    g.initialized = true;
    return 0;
}

namespace {

// Registered at the end of va_gfx_init, so it runs before the static
// destructors of ANGLE and of this library. Cheap and non-blocking: stop all
// callbacks into the engine and the embedder, and freeze the renderer (its
// threads are left alone; the OS reclaims everything).
void onProcessExit() {
    g.processExiting.store(true);
    g.shutdown.store(true);
    vagfx_present_disable();
    waker().stop();  // never joins
    // Park render/cleanup/sync threads at their next unit of work and let the
    // units in flight finish, so nothing runs concurrently with the static
    // destructors exit() is about to run (heap corruption otherwise).
    long drainMs = 1000;
    if (const char* t = getenv("VA_GFX_EXIT_DRAIN_MS")) drainMs = atol(t);
    bool drained = false;
    const int busy = gfxstream::exit_gate::freeze((int)drainMs, &drained);
    if (busy > 0 || !drained) {
        VLOG("process exit: %d renderer work unit(s) in flight, %s", busy,
             drained ? "drained" : "NOT drained before the deadline");
    }
}

}  // namespace

extern "C" void vagfx_request_readback_fallback(void) {
    static std::atomic<bool> requested{false};
    if (requested.exchange(true)) return;
    // Called from inside a post (FrameBuffer lock held): switch on another thread.
    std::thread([] {
        if (g.shutdown.load()) return;
        vagfx_present_gl_disable();
        if (g.renderer) {
            g.renderer->setPostCallback(onPost, nullptr, true, 0);
            g.readbackRegistered = true;
        }
        VLOG("frame delivery: fell back to readback");
    }).detach();
}

extern "C" __attribute__((visibility("default"))) void va_gfx_register_pipe_services(void) {
    if (!g.initialized || g.servicesRegistered) return;
    vagfx_shim_register_services(&g.engine);
    g.servicesRegistered = true;
}

extern "C" __attribute__((visibility("default"))) const char* va_gfx_renderer_string(void) {
    return g.rendererString.c_str();
}

extern "C" __attribute__((visibility("default"))) int va_gfx_get_gles_version(int* major,
                                                                              int* minor) {
    if (!g.initialized) return -1;
    if (major) *major = g.glesMajor;
    if (minor) *minor = g.glesMinor;
    return 0;
}

extern "C" __attribute__((visibility("default"))) void va_gfx_teardown(void) {
    // Idempotent; also a no-op if va_gfx_init never succeeded.
    if (!g.initialized || g.teardownStarted.exchange(true)) return;
    if (g.processExiting.load()) {
        // Called from an exit notifier: globals of ANGLE/gfxstream may already
        // be destroyed. Our atexit handler already stopped every callback;
        // leave the renderer threads to the OS.
        VLOG("teardown during process exit: renderer left to the OS");
        return;
    }

    // 1. Synchronous and non-blocking (safe with the BQL held): stop talking
    //    to the engine and the embedder.
    g.shutdown.store(true);
    vagfx_present_disable();  // no new VaGfxPresentFn calls
    if (g.engine.sync_register_trigger_wait) {
        g.engine.sync_register_trigger_wait(nullptr);  // device signals fences itself
    }
    waker().stop();  // never joins

    // 2. Everything that waits on renderer threads runs on a helper thread;
    //    we wait for it with a deadline, so teardown cannot hang (the helper
    //    and any stuck renderer threads are leaked on timeout).
    gfxstream::RendererPtr renderer = std::move(g.renderer);
    {
        gfxstream::RendererPtr none;
        android_setOpenglesRenderer(&none);  // under the caller's BQL, like pipe callbacks
    }
    struct Job {
        std::mutex m;
        std::condition_variable cv;
        bool done = false;
    };
    auto job = std::make_shared<Job>();
    const bool readback = g.readbackRegistered;
    std::thread([job, readback, renderer = std::move(renderer)]() mutable {
        pthread_setname_np("va-gfx-teardown");
        vagfx_present_gl_disable();  // waits for an in-flight zero-copy post
        if (renderer) {
            if (readback) renderer->setPostCallback(nullptr, nullptr, false, 0);
            // Closes every render channel from the host side (render threads
            // leave their loops), then joins them and the cleanup thread.
            renderer->stop(true);
        }
        vagfx_present_teardown();
        renderer.reset();  // ~RendererImpl: RenderWindow, FrameBuffer, post/sync threads
        {
            std::lock_guard<std::mutex> lock(job->m);
            job->done = true;
        }
        job->cv.notify_all();
    }).detach();

    long timeoutMs = 3000;
    if (const char* t = getenv("VA_GFX_TEARDOWN_TIMEOUT_MS")) timeoutMs = atol(t);
    std::unique_lock<std::mutex> lock(job->m);
    const bool done = job->cv.wait_for(lock, std::chrono::milliseconds(timeoutMs),
                                       [&] { return job->done; });
    VLOG("teardown %s", done ? "complete" : "timed out; leaving renderer threads behind");
}
