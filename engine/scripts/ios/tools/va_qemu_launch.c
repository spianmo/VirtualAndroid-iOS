/*
 * va-qemu-launch: command-line harness that loads QEMU the way the iOS app
 * does (UTM Services/UTMProcess.m + UTMQemuSystem.m): dlopen the framework,
 * dlsym qemu_init / qemu_main_loop / qemu_cleanup, run them on a dedicated
 * pthread and keep the main thread free (it runs a CFRunLoop, as the app's
 * UI thread would).
 *
 *   va-qemu-launch [--lib PATH] -- <qemu args...>
 *
 * Default PATH: @rpath/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu
 * Run in the simulator with: xcrun simctl spawn <udid> va-qemu-launch -- -M virt ...
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

/* Real signatures (include/system/system.h of our QEMU tree) */
typedef void (*qemu_init_fn)(int argc, char **argv);
typedef int (*qemu_main_loop_fn)(void);
typedef void (*qemu_cleanup_fn)(int status);

static qemu_init_fn p_init;
static qemu_main_loop_fn p_main_loop;
static qemu_cleanup_fn p_cleanup;
static int q_argc;
static char **q_argv;
static pthread_t q_thread;
static double t0;

static double now(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

static void *qemu_thread(void *opaque)
{
    (void)opaque;
    fprintf(stderr, "[va-launch] qemu_init (%d args)\n", q_argc);
    p_init(q_argc, q_argv);          /* returns with the BQL held */
    fprintf(stderr, "[va-launch] qemu_init done after %.2fs, entering qemu_main_loop\n", now() - t0);
    int status = p_main_loop();
    fprintf(stderr, "[va-launch] qemu_main_loop returned %d after %.2fs\n", status, now() - t0);
    p_cleanup(status);
    fprintf(stderr, "[va-launch] qemu_cleanup done\n");
    exit(status);
}

int main(int argc, char **argv)
{
    const char *lib = "@rpath/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu";
    int i = 1;
    for (; i < argc; i++) {
        if (!strcmp(argv[i], "--lib") && i + 1 < argc) {
            lib = argv[++i];
        } else if (!strcmp(argv[i], "--")) {
            i++;
            break;
        } else {
            break;
        }
    }
    t0 = now();
    void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        fprintf(stderr, "[va-launch] dlopen %s failed: %s\n", lib, dlerror());
        return 1;
    }
    p_init = (qemu_init_fn)dlsym(h, "qemu_init");
    p_main_loop = (qemu_main_loop_fn)dlsym(h, "qemu_main_loop");
    p_cleanup = (qemu_cleanup_fn)dlsym(h, "qemu_cleanup");
    if (!p_init || !p_main_loop || !p_cleanup) {
        fprintf(stderr, "[va-launch] missing entry points: init=%p loop=%p cleanup=%p\n",
                (void *)p_init, (void *)p_main_loop, (void *)p_cleanup);
        return 1;
    }
    fprintf(stderr, "[va-launch] loaded %s in %.2fs\n", lib, now() - t0);

    /* argv[0] for QEMU, then the passthrough arguments */
    q_argc = argc - i + 1;
    q_argv = calloc(q_argc + 1, sizeof(char *));
    q_argv[0] = "qemu-system-aarch64";
    for (int j = 1; j < q_argc; j++) {
        q_argv[j] = argv[i + j - 1];
    }

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_attr_setstacksize(&attr, 8 << 20);
    if (pthread_create(&q_thread, &attr, qemu_thread, NULL) != 0) {
        perror("pthread_create");
        return 1;
    }
    CFRunLoopRun();
    return 0;
}
