// Runtime glue for the real engine: loads the QEMU framework with dlopen,
// resolves the va_host.h symbols and runs qemu_init/qemu_main_loop/qemu_cleanup
// on a dedicated pthread, intercepting exit() like UTM (UTMProcess.m).
// Environment variables are applied with setenv() before qemu_init.
#ifndef VA_ENGINE_RUNTIME_H
#define VA_ENGINE_RUNTIME_H

#import <Foundation/Foundation.h>
#include "va_host.h"
#include "va_gfx.h"

NS_ASSUME_NONNULL_BEGIN

/* Engine entry points resolved from the framework. Any may be NULL if the
 * framework does not export it; callers must check. */
typedef struct VAEngineSymbols {
    /* QEMU 10 signatures (include/system/system.h of our tree; UTM's older
     * fork had int qemu_init(argc, argv, envp)). qemu_init() exits on error. */
    void (*_Nullable qemu_init)(int argc, char *_Nullable *_Nullable argv);
    int (*_Nullable qemu_main_loop)(void);
    void (*_Nullable qemu_cleanup)(int status);

    void (*_Nullable host_set_callbacks)(const VaHostCallbacks *_Nonnull callbacks);
    void (*_Nullable sensor_event)(VaSensorType type, const float *_Nonnull values,
                                   int count, int64_t timestamp_ns);
    void (*_Nullable location_update)(const VaLocation *_Nonnull location);
    void (*_Nullable battery_changed)(void);
    void (*_Nullable clipboard_from_host)(const char *_Nonnull utf8, size_t len);
    void (*_Nullable touch)(const VaTouchPoint *_Nonnull points, int count);
    void (*_Nullable key)(uint32_t linux_keycode, bool down);
    void (*_Nullable set_display_rotation)(int degrees);

    /* Engine passes this to va_gfx_init() as its VaGfxPresentFn. */
    void (*_Nullable host_set_present_callback)(VaHostPresentFn _Nullable fn,
                                                void *_Nullable opaque);
} VAEngineSymbols;

typedef void (^VAEngineExitHandler)(int status, BOOL fatal);

@interface VAQemuRunner : NSObject

@property (nonatomic, readonly) NSString *libraryPath;
@property (nonatomic, readonly) VAEngineSymbols symbols;
@property (nonatomic, readonly, getter=isRunning) BOOL running;

- (nullable instancetype)initWithLibraryPath:(NSString *)path
                                       error:(NSError *_Nullable *_Nullable)error;

/* argv[0] is supplied by the runner ("qemu-system-aarch64"). */
- (BOOL)startWithArguments:(NSArray<NSString *> *)arguments
               environment:(NSDictionary<NSString *, NSString *> *)environment
          workingDirectory:(nullable NSString *)workingDirectory
               exitHandler:(VAEngineExitHandler)exitHandler
                     error:(NSError *_Nullable *_Nullable)error;

@end

/* True when an engine started now could JIT: always on the simulator; on a
 * device a debugger must have attached (CS_DEBUGGED, e.g. StikDebug or Xcode),
 * and on iOS 26+ (TXM) it must still be attached so that it can prepare the
 * engine's code buffer. Sample it once at launch: the engine detaches the
 * debugger after the preparation. */
bool va_runtime_jit_available(void);
/* CS_DEBUGGED is set (a debugger attached at some point; simulator: true). */
bool va_runtime_cs_debugged(void);
/* A debugger is attached right now (P_TRACED). */
bool va_runtime_debugger_attached(void);
/* iOS 26+ device: JIT memory must be prepared by an attached debugger. */
bool va_runtime_jit_needs_debugger(void);
/* No JIT in this process although StikDebug attached for it: tell its script
 * to detach (legacy brk #0x69 with an empty region, then the universal detach
 * call), so the app is not stopped on every signal or killed with StikDebug.
 * Returns true when the debugger is gone afterwards. Do not call under Xcode's
 * debugger, which stops on the brk. */
bool va_runtime_release_jit_debugger(void);
/* os_proc_available_memory() on device, physical memory on the simulator. */
uint64_t va_runtime_available_memory(void);
bool va_runtime_is_simulator(void);

/* VaCameraInfo.sizes is an array of anonymous structs Swift cannot import. */
static inline void va_camera_info_set_size(VaCameraInfo *info, int index, int width, int height)
{
    if (index >= 0 && index < (int)(sizeof(info->sizes) / sizeof(info->sizes[0]))) {
        info->sizes[index].width = width;
        info->sizes[index].height = height;
    }
}

static inline int va_camera_info_size_count(void)
{
    return (int)(sizeof(((VaCameraInfo *)0)->sizes) / sizeof(((VaCameraInfo *)0)->sizes[0]));
}

NS_ASSUME_NONNULL_END

#endif
