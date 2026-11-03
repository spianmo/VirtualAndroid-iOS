/* Probe whether a process can JIT: MAP_JIT RWX + pthread_jit_write_protect_np,
 * then plain RWX without MAP_JIT, then the split W^X vm_remap trick.
 * Build for the simulator and run with `xcrun simctl spawn <dev> jit_probe`. */
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

extern kern_return_t mach_vm_remap(vm_map_t, mach_vm_address_t *, mach_vm_size_t, mach_vm_offset_t,
                                   int, vm_map_t, mach_vm_address_t, boolean_t, vm_prot_t *,
                                   vm_prot_t *, vm_inherit_t);

/* Same APRR commpage toggle QEMU uses (include/tcg/tcg-apple-jit.h);
 * pthread_jit_write_protect_np is marked unavailable in the iOS SDKs. */
#define COMM_PAGE 0x0000000FFFFFC000ULL
static int aprr_support(void) { return *(volatile uint8_t *)(COMM_PAGE + 0x10C); }
static void jit_write_protect(int enabled)
{
    int s = aprr_support();
    uint64_t a = enabled ? COMM_PAGE + 0x118 : COMM_PAGE + 0x110;
    if (s == 1) {
        __asm__ __volatile__("ldr x0, [%0]\nmsr S3_4_c15_c2_7, x0\nisb sy\n" :: "r"(a) : "memory", "x0");
    } else if (s == 2 || s == 3) {
        __asm__ __volatile__("ldr x0, [%0]\nmsr S3_6_c15_c1_5, x0\nisb sy\n" :: "r"(a) : "memory", "x0");
    }
}

static const uint32_t code[] = { 0x52800540 /* mov w0,#42 */, 0xd65f03c0 /* ret */ };

static int run(void *p) { return ((int (*)(void))p)(); }

int main(void)
{
    size_t sz = 16384;
    void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (p == MAP_FAILED) {
        printf("MAP_JIT rwx: mmap failed errno=%d (%s)\n", errno, strerror(errno));
    } else {
        jit_write_protect(0);
        memcpy(p, code, sizeof(code));
        jit_write_protect(1);
        sys_icache_invalidate(p, sizeof(code));
        printf("MAP_JIT rwx: mmap ok, commpage aprr_support=%d, run -> %d\n",
               aprr_support(), run(p));
    }
    void *q = mmap(NULL, sz, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    printf("plain rwx (no MAP_JIT): %s errno=%d\n", q == MAP_FAILED ? "FAILED" : "ok", q == MAP_FAILED ? errno : 0);
    /* split W^X: RW mapping + RX alias */
    void *rw = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    mach_vm_address_t rx = 0; vm_prot_t cur, max;
    kern_return_t kr = mach_vm_remap(mach_task_self(), &rx, sz, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                     (mach_vm_address_t)rw, 0, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        printf("splitwx: vm_remap failed %d\n", kr);
    } else if (mprotect((void *)rx, sz, PROT_READ | PROT_EXEC) != 0) {
        printf("splitwx: mprotect rx failed errno=%d (%s)\n", errno, strerror(errno));
    } else {
        memcpy(rw, code, sizeof(code));
        sys_icache_invalidate((void *)rx, sizeof(code));
        printf("splitwx: run -> %d\n", run((void *)rx));
    }
    return 0;
}
