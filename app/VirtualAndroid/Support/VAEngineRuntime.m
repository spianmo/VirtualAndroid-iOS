#import "VAEngineRuntime.h"

#import <TargetConditionals.h>
#import <dlfcn.h>
#import <os/proc.h>
#import <pthread.h>
#import <stdlib.h>
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

bool va_runtime_jit_available(void)
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

uint64_t va_runtime_available_memory(void)
{
#if TARGET_OS_SIMULATOR
    return NSProcessInfo.processInfo.physicalMemory;
#else
    return (uint64_t)os_proc_available_memory();
#endif
}
