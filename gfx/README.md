# gfx — libva_gfx (gfxstream host renderer for the goldfish-pipe guest)

`libva_gfx` hosts the gfxstream host renderer (the same code the official
emulator ships as `libgfxstream_backend`) and bridges it to our QEMU through
the `VaGfxEngineOps` table in `include/va_gfx.h`. The API 33 image only has the
goldfish-opengl "emulation" GLES/Vulkan drivers, so this library is what turns
the guest's GL command stream on `pipe:opengles` into frames.

```
guest libGLESv2_emulation / hwcomposer.ranchu / gralloc.ranchu
   │  pipe:opengles  pipe:GLProcessPipe  pipe:refcount   (goldfish pipe, engine/qemu)
   ▼
libva_gfx: VaGfxEngineOps shim ─ aemu AndroidPipe services ─ gfxstream RenderThreads
   │  GLES translator in EGL-on-EGL mode            Vulkan decoder (optional)
   ▼                                                ▼
ANGLE (WebKit subset, Metal backend)               MoltenVK
   ▼
ColorBuffer posted (rcFBPost / rcCompose) ─ GPU blit into IOSurface pbuffer ─ IOSurface ring ─ VaGfxPresentFn
                                           (readback + memcpy fallback for native CGL)
```

## Status (all verified with `tests/va_gfx_harness`)

| platform | GLES backend | result |
|---|---|---|
| macOS arm64 | ANGLE Metal (`build-macos/dist`) | harness passes (upload, GLES draw, rcCompose + 60-frame loop); 1080x2340 post→IOSurface 0.76 ms (zero-copy) vs 10.9 ms (readback) |
| macOS arm64 | native CGL (`gles_backend="native"`) | upload/GLES frames pass; host compositor shaders need ANGLE's shader translator, so use ANGLE |
| macOS arm64 | + Vulkan via MoltenVK | host advertises `ANDROID_EMU_vulkan` (tested with the SDK's prebuilt MoltenVK) |
| iOS simulator arm64 | ANGLE Metal (`build-ios-sim/dist`) | harness passes inside the simulator (`simctl spawn`); 1080x2340 1.29 ms zero-copy vs 165 ms readback |
| iOS simulator arm64 | + Vulkan via MoltenVK 1.4.2 (source build) | host advertises `ANDROID_EMU_vulkan`, VkDevice on "Apple iOS simulator GPU" |
| iOS device arm64 | ANGLE Metal (`build-ios/dist`) | builds; not run (needs a device) |

xcframeworks: `build-ios-xcframeworks/{va_gfx,GLESv2[,MoltenVK]}.xcframework` (device + simulator).
The harness also checks goldfish sync end to end (rcCreateSyncKHR → the
registered trigger_wait → `sync_timeline_inc` from gfxstream's SyncThread)
and the BQL rules below (it counts engine calls made without the BQL).

## Building

```sh
gfx/scripts/fetch-sources.sh   # pinned gfxstream d047a572, aemu 3c1ced8a (+ our patches),
                               # WebKit ANGLE subset @ ed78ab6e (sparse, shallow)
for P in macos ios-sim ios; do
  gfx/scripts/build-aemu.sh $P          # CMake, static
  gfx/scripts/build-gfxstream.sh $P     # meson, static (cross file generated for iOS)
  gfx/scripts/build-angle.sh $P         # xcodebuild (needs: xcodebuild -downloadComponent MetalToolchain)
  gfx/scripts/build-moltenvk.sh $P      # optional, Vulkan: KhronosGroup MoltenVK v1.4.2
  gfx/libva_gfx/build.sh $P             # glue + static gfxstream/aemu -> libva_gfx.dylib
  gfx/scripts/package-apple.sh $P       # -> build-$P/dist
done
gfx/scripts/package-apple.sh xcframework
```

Our source changes live in `patches/gfxstream.patch` and `patches/aemu.patch`
(Apple/iOS build fixes, ANGLE library discovery, sync readback switch).

Test:

```sh
gfx/tests/build-harness.sh macos
gfx/build-macos/tests/va_gfx_harness gfx/build-macos/dist/libva_gfx.dylib /tmp angle   # PNGs in /tmp
gfx/tests/build-harness.sh ios-sim
xcrun simctl spawn booted $PWD/gfx/build-ios-sim/tests/va_gfx_harness \
    $PWD/gfx/build-ios-sim/dist/va_gfx.framework/va_gfx /tmp angle
```

## What the engine (ranchu machine) must do

Shortcut: `integration/ranchu_gfx.{c,h}` implements steps 2-3 below as a
drop-in for `engine/qemu/hw/android/` (syntax-checked against the real tree with
`integration/check-syntax.sh`). The machine then only needs:

```c
#include "ranchu_gfx.h"            /* add gfx/include to the include path */
RanchuGfxOptions o = { .width = 1080, .height = 2340, .dpi = 440, .refresh_hz = 60 };
if (ranchu_gfx_init(&o, present_cb, opaque)) {               /* in ranchu_init() */
    /* bootconfig: androidboot.opengles.version = ranchu_gfx_opengles_version() */
}
```

### 1. Ship the libraries

* macOS: `libva_gfx.dylib` and `libGLESv2.dylib` (ANGLE) in the same directory
  (`build-macos/dist`). Optional `libMoltenVK.dylib` next to them for Vulkan.
* iOS: embed `va_gfx.framework` and `GLESv2.framework` (and later
  `MoltenVK.framework`) in the app's `Frameworks/` (Embed & Sign). libva_gfx
  finds ANGLE as `../GLESv2.framework/GLESv2` relative to itself. ANGLE's
  libGLESv2 also provides EGL; `libEGL` is not needed.
* Overrides: `VA_GFX_ANGLE_DIR=<dir>`, `GFXSTREAM_EGL_LIB`/`GFXSTREAM_GLESV2_LIB`
  (full paths), `VA_GFX_MOLTENVK_PATH`, `VA_GFX_GLES_BACKEND=angle|native`.

### 2. Load and resolve (never link)

```c
void *h = dlopen(path_to_libva_gfx, RTLD_NOW | RTLD_LOCAL);
//  macOS: ".../libva_gfx.dylib"   iOS: "<bundle>/Frameworks/va_gfx.framework/va_gfx"
int  (*init)(const VaGfxConfig *, const VaGfxEngineOps *, VaGfxPresentFn, void *) = dlsym(h, "va_gfx_init");
void (*reg)(void)               = dlsym(h, "va_gfx_register_pipe_services");
const char *(*renderer)(void)   = dlsym(h, "va_gfx_renderer_string");
int  (*gles)(int *, int *)      = dlsym(h, "va_gfx_get_gles_version");   /* gfx addition */
void (*teardown)(void)          = dlsym(h, "va_gfx_teardown");
/* optional: guest physical -> host pointer for gralloc's DMA color buffer
 * updates (goldfish_address_space memory); call before or after init */
void (*dma)(void *(*)(uint64_t)) = dlsym(h, "va_gfx_set_dma_host_addr");
if (dma) dma(goldfish_address_space_dma_host_addr);
```

Without the DMA hook, `rcUpdateColorBufferDMA`/`rcReadColorBufferDMA` see no
memory: camera frames and other CPU-written gralloc buffers stay black.

Only these five symbols are exported (gfxstream/aemu are linked statically and
hidden, so they cannot clash with QEMU's own `android_pipe_*`).

### 3. Fill the ops table and initialise (machine init, before the guest runs)

```c
static void va_bql_lock(void)   { bql_lock(); }    /* bql_lock() is a macro in QEMU 10 */
static void va_bql_unlock(void) { bql_unlock(); }

VaGfxEngineOps ops = {
    .pipe_add_type              = android_pipe_add_type,
    .pipe_host_close            = android_pipe_host_close,
    .pipe_host_signal_wake      = android_pipe_host_signal_wake,
    .bql_lock                   = va_bql_lock,
    .bql_unlock                 = va_bql_unlock,
    .sync_create_timeline       = goldfish_sync_create_timeline,
    .sync_create_fence          = goldfish_sync_create_fence,
    .sync_timeline_inc          = goldfish_sync_timeline_inc,
    .sync_destroy_timeline      = goldfish_sync_destroy_timeline,
    .sync_register_trigger_wait = goldfish_sync_register_trigger_wait,
};
VaGfxConfig cfg = { .display_width = 1080, .display_height = 2340, .display_dpi = 440,
                    .refresh_hz = 60, .gles_backend = "angle", .enable_vulkan = false };
if (init(&cfg, &ops, present_cb, opaque) == 0) {   /* creates the renderer (GL context, threads) */
    reg();                                          /* registers opengles, GLProcessPipe, refcount */
}
int maj, min; gles(&maj, &min);                     /* ANGLE Metal: 3.0 */
```

* Call `va_gfx_init` once, after the android_pipe core exists and before the
  guest boots; calling it with the BQL held is fine (it makes no engine calls).
  It returns -1 if no renderer could be created (then do not register).
* If the sync pointers are NULL, native sync is not advertised and the guest
  falls back to glFinish-style sync (works, slower).
* `cfg.display_*` is what the guest's hwcomposer sees through rcGetFBParam
  (size, xdpi, fps); keep it equal to the board's display/`lcd_density`.

### 4. Bootconfig the guest needs

```
androidboot.hardware.gltransport=pipe
androidboot.qemu.gltransport.name=pipe
androidboot.qemu.gltransport.drawFlushInterval=800
androidboot.opengles.version=<(maj << 16) | min>     # 196608 for ANGLE Metal (GLES 3.0)
androidboot.hardware.vulkan=ranchu                   # harmless without host Vulkan
androidboot.debug.hwui.renderer=skiagl
androidboot.qemu.vsync=<refresh_hz>
```

### 5. Threading contract

* Engine → libva_gfx pipe callbacks: BQL held, vCPU thread (as android_pipe.h says).
* libva_gfx → `pipe_host_signal_wake` / `pipe_host_close`: **always with the BQL
  held** — either re-entrantly from inside a pipe callback on the same thread
  (e.g. `wakeOn` immediately signalling `PIPE_WAKE_READ`, as AOSP does), or from
  libva_gfx's `va-gfx-waker` thread, which wraps them in `bql_lock/bql_unlock`.
  Renderer threads never call into the engine directly (avoids the
  BQL ↔ RenderChannel lock inversion). Pending wakes for a pipe are dropped
  when the guest closes it.
* `sync_timeline_inc`: called directly from gfxstream's SyncThread without the
  BQL (allowed by `hw/android/goldfish_sync.h`). `sync_register_trigger_wait`
  is called from render threads (rcGetRendererVersion) without the BQL (the
  board's implementation is an atomic store); the callback it registers
  (`rcTriggerWait`) is non-blocking (queues to SyncThread) and is fine to call
  on a vCPU thread with the BQL held.
* `present` (VaGfxPresentFn): called on a renderer thread, **without** the BQL,
  once per guest post (rcFBPost / rcCompose). `frame->iosurface` is an
  `IOSurfaceRef`, BGRA8 (`'BGRA'`), `width x height` = display size, row 0 = top.
  It is retained only for the duration of the call: `CFRetain` it to keep
  showing it (e.g. as `CALayer.contents` or a Metal texture via
  `newTextureWithDescriptor:iosurface:plane:`). libva_gfx keeps a ring of up to
  6 surfaces and never reuses one that is retained elsewhere or
  `IOSurfaceIsInUse`; if all are held the frame is dropped. Do not block.

### 6. Teardown and process exit

* `va_gfx_teardown()`: call it from the shutdown handler after closing the
  pipes. It is idempotent, safe on the QEMU main thread with the BQL held, and
  cannot hang: it stops engine/embedder callbacks synchronously (no new pipes,
  no wakes, `sync_register_trigger_wait(NULL)`, no more `present` calls), then
  stops the renderer on a helper thread (host-side close of every render
  channel, join of render/cleanup threads, renderer destruction) and waits at
  most `VA_GFX_TEARDOWN_TIMEOUT_MS` (default 3000 ms). On timeout it returns and
  leaks the stuck threads. `va_gfx_init()` cannot be called again afterwards.
  Measured: ~15-35 ms (macOS and iOS simulator).
* Without teardown (e.g. SIGTERM straight to `exit()`): nothing in libva_gfx
  runs from static destructors (all state is leaked heap memory), and the
  gfxstream registries render threads touch are leaked singletons, so exit
  never joins renderer threads.
* Teardown from an exit notifier (what ranchu does): `va_gfx_init` registers an
  `atexit` handler last, so it runs first in `exit()` — before ANGLE's and
  gfxstream's static destructors and before QEMU's notifiers. It stops every
  callback and marks the process as exiting; afterwards `va_gfx_teardown()`
  and all pipe callbacks (close included) are immediate no-ops and the
  renderer threads are left to the OS. The same handler freezes gfxstream's
  exit gate (`host/ExitGate.h`, patched in): render batches, process-cleanup
  items and sync commands park at their next unit of work, and the handler
  waits up to `VA_GFX_EXIT_DRAIN_MS` (default 1000) for units in flight, so no
  renderer thread runs while exit() destroys ANGLE/gfxstream globals. Real
  guest: QEMU exits ~0.1 s after SIGTERM or monitor `quit`. For an orderly shutdown (e.g. an iOS app stopping a VM but staying
  alive) call `va_gfx_teardown()` before `exit()`.
* Tested by `tests/run-exit-tests.sh <macos|ios-sim> [udid]`: pipes closed then
  teardown, exit() with live render threads, exit() while the render thread is
  busy, a guest process with 48 contexts/surfaces/colorbuffers dying right
  before exit() (cleanup thread busy during exit), QEMU's order (atexit
  notifier registered before dlopen closes the pipes
  and tears down), teardown with pipes still open, and teardown while a render
  thread is wedged in the post path holding the FrameBuffer lock (must return
  at the deadline). Each run has a 30 s hang watchdog.
* Snapshot save/load of these pipes is not implemented yet (`save`/`load` are
  NULL, so the engine closes them on load; the guest reconnects).

## Snapshot (M4, docs/SNAPSHOT.md)

`va_gfx_snapshot_save/load` plus the graphics pipes' `AndroidPipeFuncs.save/load`.

**Contract change (additive):** `VaGfxEngineOps` gained `pipe_stream_put_buffer` /
`pipe_stream_get_buffer`; set them to `android_pipe_stream_put_buffer` /
`android_pipe_stream_get_buffer` (libva_gfx cannot link those QEMU symbols).
If they are NULL the graphics pipes register `save/load = NULL` (closed on
load, as before). `integration/ranchu_gfx.c` fills them.

What is saved:
* `va-gfx` section (via `VaGfxSnapshotIo`, length-framed, `'VAGX'` v1): display
  size, aemu pipe-service state (GLProcessPipe id counter) and the gfxstream
  FrameBuffer (`RendererImpl::save`: contexts, surfaces, ColorBuffers, EGL
  images, fences). Texture contents go to `<aux_dir>/gfx-textures.bin` (aemu
  TextureSaver, LZ4).
* each graphics pipe (`'VAGP'` v1): aemu `AndroidPipe::saveToStream` (opengles:
  unread reply bytes, RenderChannel queues and its RenderThread's state;
  GLProcessPipe: process id; refcount: handle) plus wake flags that were still
  queued for the device.

How it runs (VM stopped, BQL held, never blocking on renderer threads):
* save: on a helper thread with a deadline (`VA_GFX_SNAPSHOT_TIMEOUT_MS`, default
  10 s): wait for an earlier load's background texture loading, drain process
  cleanup, park every render thread at its snapshot point, save the
  FrameBuffer, drain SyncThread (pending trigger-wait results reach goldfish_sync
  before that device is saved). Render threads stay parked while the engine
  saves the pipes; they resume once the BQL is free again (or on the next pipe
  callback). A timeout returns -1 and the guest keeps running.
* load (fresh renderer): restore the FrameBuffer, re-present the last frame
  (`FrameBuffer::repost` -> VaGfxPresentFn), then each pipe load recreates its
  channel + render thread, which restores its state and parks until resume.

The engine must also restore the pipes *after* `va_gfx_snapshot_load` and may
release the BQL between sections: render threads resume only when every pipe
counted at save time has been loaded (or on guest pipe activity), never on a
"BQL is free" heuristic. `VA_GFX_DEBUG_PIPES=1` logs pipe EIO/host-close causes.

Measured (harness, `tests/run-snapshot-tests.sh`, 1080x2340, 10 ColorBuffers,
macOS M2 Max): save ~120-160 ms, `gfx-textures.bin` 10.8 MB (101 MB raw),
`state.bin` 6 KB, load to first re-presented frame ~225-290 ms; the
re-presented frame and a re-done composition are pixel-identical to process
A's; the restored GL context, buffers, GLProcessPipe ids and refcount pipe keep
working; a restored process can be suspended again.

Real guest (macOS HVF, `tools/run-macos.sh --snapshot` + `tools/snapshot.py`, engine
0e17cd59b, host load average 30-60 from other builds): 4 suspend/restore cycles
from the home screen, 72-76 graphics pipes and 17-35 render threads each time:
va_gfx save 263-558 ms (one outlier 1.8 s), `snapshot/gfx` 5-13 MB, va_gfx load
563-853 ms (outlier 1.26 s), first frame 1.2-3.0 s after QEMU launch (0.64 s on
an idle host), the re-presented frame pixel-identical to the last pre-suspend
frame; then 2 min of `am start` Settings/Contacts + swipes: 0 watchdog / EGL /
pipe errors in 3 cycles, one app input-ANR (Settings, "no focused window") in
the 4th under load.

Needed for ANGLE (Metal) with many contexts (patches/angle.patch): ANGLE lists
Metal command buffers when created, and `ensureResourceReadyForCPU` waited on
the oldest ones -- possibly another context's uncommitted buffer, whose owner
waits for the share-group lock: a deadlock (seen restoring the real guest:
texture upload stuck in `waitUntilCompleted` while the background texture
loader waited for the lock). Patched to wait only for committed buffers.

Not covered yet: Vulkan state (gfxstream VulkanSnapshots is off), the
address-space-graphics transport (not used by this guest).

## Implementation notes

* ANGLE must be built with `ANGLE_ENABLE_SHARE_CONTEXT_LOCK=1` and
  `ANGLE_ENABLE_CONTEXT_MUTEX=1` (`scripts/build-angle.sh` does this; standalone
  ANGLE enables them by default, WebKit's Xcode build does not). gfxstream runs
  one GL context per guest thread, all in one share group, from many host
  threads; without the locks a real guest corrupts shared GL state within
  seconds of boot (a render thread spins in `gl::Framebuffer::setAttachment`
  holding the FrameBuffer lock, frames stop, system_server's watchdog fires).

* `libva_gfx/va_gfx_pipe_shim.c` is the only file that sees QEMU's
  `android_pipe.h`; `va_gfx.cpp` sees aemu's (conflicting) pipe headers. A guest
  connection is created through aemu's connector (`android_pipe_guest_open` +
  `"pipe:<name>"`), so the stock gfxstream/aemu `opengles`, `GLProcessPipe` and
  `refcount` services are used unmodified.
* Frames (ANGLE): zero-copy. A small gfxstream patch calls a hook in
  `FrameBuffer::postImpl` with the posted ColorBuffer's host texture; 
  `va_gfx_present_gl.cpp` blits it into an IOSurface-backed ANGLE pbuffer
  (`EGL_ANGLE_iosurface_client_buffer`), glFinish, then presents. Native CGL,
  `VA_GFX_FORCE_READBACK=1`, or a runtime failure of the GPU path use the
  synchronous BGRA readback path (`GFXSTREAM_DISABLE_ASYNC_READBACK`) instead.
* Features negotiated with the guest (see `buildFeatures`): host composition,
  refcount pipe, GLES dynamic version, YUV cache, HWC multi-configs, native
  sync (if the engine provides goldfish_sync), Vulkan (if enabled + MoltenVK);
  no goldfish DMA / direct-mem / address-space graphics / virtio-gpu.

## Dependencies and licenses

| component | source | license |
|---|---|---|
| gfxstream host | android.googlesource.com/platform/hardware/google/gfxstream @ d047a572 | Apache-2.0 (meson declares "MIT OR Apache-2.0"; bundled Khronos/Vulkan headers Apache-2.0/MIT, glm MIT, renderdoc header MIT) |
| aemu (base, host-common, snapshot) | android.googlesource.com/platform/hardware/google/aemu @ 3c1ced8a | Apache-2.0 |
| ANGLE | WebKit's Source/ThirdParty/ANGLE, github.com/utmapp/WebKit @ ed78ab6e | BSD-3-Clause |
| MoltenVK (optional) | macOS test used the Android SDK prebuilt; iOS: build from source (Apache-2.0) | Apache-2.0 |
| libva_gfx glue | this repo (ported from aemu/gfxstream glue) | project license; Apache-2.0-compatible |

Note: libva_gfx is Apache-2.0 code loaded into QEMU (GPL-2.0). The AOSP
emulator ships the same split (QEMU + separately loaded gfxstream); Apache-2.0
vs GPL-2.0-only compatibility should be reviewed before distribution.
