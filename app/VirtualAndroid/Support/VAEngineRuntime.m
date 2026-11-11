#import "VAEngineRuntime.h"

#import <TargetConditionals.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <time.h>
#import <os/proc.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <signal.h>
#import <sys/ucontext.h>
#import <unistd.h>

static NSString *const VAEngineErrorDomain = @"VirtualAndroid.Engine";

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define VA_CS_OPS_STATUS 0
#define VA_CS_DEBUGGED 0x10000000

@interface VAQemuRunner ()
@property (nonatomic, readwrite) BOOL running;
@end

@implementation VAQemuRunner {
    void *_handle;
    VAEngineSymbols _symbols;
    pthread_t _thread;
    dispatch_semaphore_t _done;
    volatile int _status;
    volatile int _fatal;
    NSArray<NSString *> *_argv;
    NSDictionary<NSString *, NSString *> *_env;
    NSString *_cwd;
    VAEngineExitHandler _exitHandler;
}

static NSError *VAError(NSString *message)
{
    return [NSError errorWithDomain:VAEngineErrorDomain code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (instancetype)initWithLibraryPath:(NSString *)path error:(NSError **)error
{
    if (!(self = [super init])) {
        return nil;
    }
    _libraryPath = [path copy];
    _handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!_handle) {
        const char *err = dlerror();
        if (error) {
            *error = VAError([NSString stringWithFormat:@"dlopen failed: %s", err ? err : "?"]);
        }
        return nil;
    }
    _symbols.qemu_init = dlsym(_handle, "qemu_init");
    _symbols.qemu_main_loop = dlsym(_handle, "qemu_main_loop");
    _symbols.qemu_cleanup = dlsym(_handle, "qemu_cleanup");
    _symbols.host_set_callbacks = dlsym(_handle, "va_host_set_callbacks");
    _symbols.sensor_event = dlsym(_handle, "va_engine_sensor_event");
    _symbols.location_update = dlsym(_handle, "va_engine_location_update");
    _symbols.battery_changed = dlsym(_handle, "va_engine_battery_changed");
    _symbols.clipboard_from_host = dlsym(_handle, "va_engine_clipboard_from_host");
    _symbols.touch = dlsym(_handle, "va_engine_touch");
    _symbols.key = dlsym(_handle, "va_engine_key");
    _symbols.set_display_rotation = dlsym(_handle, "va_engine_set_display_rotation");
    _symbols.host_set_present_callback = dlsym(_handle, "va_host_set_present_callback");
    if (!_symbols.qemu_init || !_symbols.qemu_main_loop || !_symbols.qemu_cleanup) {
        if (error) {
            *error = VAError(@"framework does not export qemu_init/qemu_main_loop/qemu_cleanup");
        }
        dlclose(_handle);
        _handle = NULL;
        return nil;
    }
    _done = dispatch_semaphore_create(0);
    return self;
}

- (VAEngineSymbols)symbols
{
    return _symbols;
}

static void *va_qemu_thread_main(void *arg)
{
    VAQemuRunner *self = (__bridge_transfer VAQemuRunner *)arg;
    pthread_setname_np("qemu-main");

    [self->_env enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        setenv(k.UTF8String, v.UTF8String, 1);
    }];
    setenv("TMPDIR", NSFileManager.defaultManager.temporaryDirectory.path.fileSystemRepresentation, 1);
    if (self->_cwd) {
        chdir(self->_cwd.fileSystemRepresentation);
    }
    /* VA_STDERR_FILE: append the engine's stderr (QEMU warnings, tcg/AOT
     * messages) to a file; on a device stderr otherwise goes nowhere. */
    const char *errPath = getenv("VA_STDERR_FILE");
    if (errPath && *errPath) {
        int fd = open(errPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            dup2(fd, STDERR_FILENO);
            close(fd);
            setvbuf(stderr, NULL, _IOLBF, 0);
            time_t now = time(NULL);
            fprintf(stderr, "---- engine start %s", ctime(&now));
            fprintf(stderr, "app: %llu MB available to the process, jit available %d, "
                    "debugger attached %d\n", (unsigned long long)(va_runtime_available_memory() >> 20),
                    va_runtime_jit_available(), va_runtime_debugger_attached());
        }
    }

    int argc = (int)self->_argv.count + 1;
    char **argv = calloc((size_t)argc + 1, sizeof(char *));
    argv[0] = strdup("qemu-system-aarch64");
    for (int i = 1; i < argc; i++) {
        argv[i] = strdup(self->_argv[(NSUInteger)i - 1].UTF8String);
    }

    /* Returns with the BQL held; exit()s (intercepted below) on bad options. */
    self->_symbols.qemu_init(argc, argv);
    int status = self->_symbols.qemu_main_loop();
    self->_symbols.qemu_cleanup(status);
    self->_status = status;
    dispatch_semaphore_signal(self->_done);
    return NULL;
}

- (BOOL)startWithArguments:(NSArray<NSString *> *)arguments
               environment:(NSDictionary<NSString *, NSString *> *)environment
          workingDirectory:(NSString *)workingDirectory
               exitHandler:(VAEngineExitHandler)exitHandler
                     error:(NSError **)error
{
    if (self.running) {
        if (error) {
            *error = VAError(@"engine already running");
        }
        return NO;
    }
    _argv = [arguments copy];
    _env = [environment copy];
    _cwd = [workingDirectory copy];
    _exitHandler = [exitHandler copy];
    _status = 0;
    _fatal = 0;

    /* QEMU calls exit() on fatal errors and on "quit": end only its thread. */
    __weak VAQemuRunner *weakSelf = self;
    if (atexit_b(^{
            VAQemuRunner *strongSelf = weakSelf;
            if (strongSelf && strongSelf->_thread && pthread_equal(pthread_self(), strongSelf->_thread)) {
                strongSelf->_fatal = 1;
                dispatch_semaphore_signal(strongSelf->_done);
                pthread_exit(NULL);
            }
        }) != 0) {
        if (error) {
            *error = VAError(@"atexit_b failed");
        }
        return NO;
    }

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_attr_setstacksize(&attr, 8u << 20);
    self.running = YES;
    int rc = pthread_create(&_thread, &attr, va_qemu_thread_main, (__bridge_retained void *)self);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        self.running = NO;
        if (error) {
            *error = VAError([NSString stringWithFormat:@"pthread_create failed: %d", rc]);
        }
        return NO;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        dispatch_semaphore_wait(self->_done, DISPATCH_TIME_FOREVER);
        self.running = NO;
        VAEngineExitHandler handler = self->_exitHandler;
        self->_exitHandler = nil;
        if (handler) {
            handler(self->_status, self->_fatal != 0);
        }
    });
    return YES;
}

@end

bool va_runtime_is_simulator(void)
{
#if TARGET_OS_SIMULATOR
    return true;
#else
    return false;
#endif
}

bool va_runtime_cs_debugged(void)
{
#if TARGET_OS_SIMULATOR
    return true;
#else
    uint32_t flags = 0;
    if (csops(getpid(), VA_CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return false;
    }
    return (flags & VA_CS_DEBUGGED) != 0;
#endif
}

bool va_runtime_debugger_attached(void)
{
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return false;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

/* A device known to have no TXM (Trusted Execution Monitor): there CS_DEBUGGED
 * alone allows JIT, as before iOS 26. Unknown counts as TXM (conservative: we
 * then only JIT while a debugger is attached to prepare the region). */
static bool va_runtime_device_lacks_txm(void)
{
    /* StikDebug 3.2's rule (ProcessInfo+TXM.swift): on iOS 27+ every device
     * but iPad8,11/iPad8,12 has TXM; on iOS 26 iPhones from iPhone14,2 (A15)
     * and iPads from iPad14,5 on. */
    struct utsname u;
    if (uname(&u) != 0) {
        return false;
    }
    if (@available(iOS 27, *)) {
        return !strcmp(u.machine, "iPad8,11") || !strcmp(u.machine, "iPad8,12");
    }
    bool ipad = !strncmp(u.machine, "iPad", 4);
    const char *num = u.machine + (ipad ? 4 : (strncmp(u.machine, "iPhone", 6) ? 0 : 6));
    int major = 0, minor = 0;
    if (num == u.machine || sscanf(num, "%d,%d", &major, &minor) != 2) {
        return false;
    }
    /* Integer compare. StikDebug builds a decimal (14,10 -> 14.1) and so calls
     * the iPad Air 13" M2 (iPad14,10/11) non-TXM; it has TXM like every M2. */
    return major < 14 || (major == 14 && minor < (ipad ? 5 : 2));
}

bool va_runtime_jit_needs_debugger(void)
{
#if TARGET_OS_SIMULATOR
    return false;
#else
    /* iOS 26+: on TXM devices (A15/M2 and later) the debugger has to prepare
     * the JIT region (engine tcg/region.c, brk #0x69 / #0xf00d). Treat every
     * iOS 26+ device that way: QEMU only asks while a debugger is attached,
     * and an older device whose debugger already left would still JIT. */
    if (@available(iOS 26, *)) {
        return !va_runtime_device_lacks_txm();
    }
    return false;
#endif
}

bool va_runtime_jit_available(void)
{
#if TARGET_OS_SIMULATOR
    return true;
#else
    if (!va_runtime_cs_debugged()) {
        return false;
    }
    return !va_runtime_jit_needs_debugger() || va_runtime_debugger_attached();
#endif
}

#if !TARGET_OS_SIMULATOR
/* A brk the debugger no longer catches (it detached after our P_TRACED check)
 * raises SIGTRAP: skip it instead of dying (same as the engine's region.c). */
static volatile sig_atomic_t va_jit26_trapped;

static void va_jit26_sigtrap(int sig, siginfo_t *info, void *ctx)
{
    ucontext_t *uc = ctx;
    uint32_t insn = *(const uint32_t *)uc->uc_mcontext->__ss.__pc;
    if ((insn & 0xFFE0001F) == 0xD4200000) {
        uc->uc_mcontext->__ss.__pc += 4;
        va_jit26_trapped = 1;
        return;
    }
    signal(SIGTRAP, SIG_DFL);
}

/* Same calls as the engine (tcg/region.c): legacy brk #0x69 first, then the
 * StikDebug universal.js "JIT26" calls (x16 = command, brk #0xf00d). */
static uint64_t va_jit26_brk69(uint64_t addr, uint64_t len)
{
    register uint64_t x0 asm("x0") = addr;
    register uint64_t x1 asm("x1") = len;
    asm volatile("brk #0x69" : "+r"(x0), "+r"(x1) : : "memory");
    return x0;
}

static uint64_t va_jit26_call(uint64_t cmd, uint64_t a0, uint64_t a1)
{
    register uint64_t x0 asm("x0") = a0;
    register uint64_t x1 asm("x1") = a1;
    register uint64_t x16 asm("x16") = cmd;
    asm volatile("brk #0xf00d" : "+r"(x0), "+r"(x1), "+r"(x16) : : "memory");
    return x0;
}
#endif

bool va_runtime_release_jit_debugger(void)
{
#if TARGET_OS_SIMULATOR
    return false;
#else
    if (!va_runtime_debugger_attached() || !va_runtime_jit_needs_debugger()) {
        return false;
    }
    /* legacy.js prepares the (empty) region and detaches by itself.
     * universal.js refuses the legacy call by overwriting x0 (see the engine's
     * tcg/region.c) and detaches on command 0. A script that leaves x0 alone
     * and stays attached is left alone too. */
    struct sigaction sa = { 0 }, old;
    sa.sa_sigaction = va_jit26_sigtrap;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTRAP, &sa, &old);
    va_jit26_trapped = 0;
    uint64_t r = va_jit26_brk69(0, 0);
    if (!va_jit26_trapped && va_runtime_debugger_attached() && r != 0) {
        va_jit26_call(0, 0, 0);
    }
    sigaction(SIGTRAP, &old, NULL);
    return !va_runtime_debugger_attached();
#endif
}

uint64_t va_runtime_available_memory(void)
{
#if TARGET_OS_SIMULATOR
    return NSProcessInfo.processInfo.physicalMemory;
#else
    return (uint64_t)os_proc_available_memory();
#endif
}
