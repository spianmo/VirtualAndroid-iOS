/*
 * 128-bit atomics under MTTCG (see run.sh): runs as /init of a tiny
 * initramfs on the Android kernel, with -smp 4.
 *
 * Every test has NTHREADS threads update one shared 16-byte-aligned pair
 * (lo, hi) whose invariant is hi == lo * 3 + MAGIC, so a torn update or a
 * lost increment shows up both in the invariant and in the final count:
 *
 *   casp     CASPAL loop (LSE, what the kernel's cmpxchg_double and the
 *            128-bit __atomic builtins compile to on ARMv8.1+)
 *   ldxp     LDAXP/STLXP loop (the same without LSE)
 *   casp-ro  one CASP writer, readers that read the pair atomically with
 *            CASP(0, 0) and check the invariant on every read
 *   cas64    64-bit CASAL loop and ldxr64 LDAXR/STLXR loop, for reference
 *            (TCG always had helpers for these)
 *
 * Output on the console: one line per test with the result and ns per
 * successful update, then "A128 PASS" or "A128 FAIL", then power off.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/reboot.h>
#include <time.h>
#include <unistd.h>

#define NTHREADS 4
#define MAGIC 0x5a5a000000000000ull

static struct pair {
    uint64_t lo, hi;
} __attribute__((aligned(16))) shared;
static uint64_t shared64 __attribute__((aligned(64)));
static long iters;
static pthread_barrier_t barrier;
static volatile int stop_readers;
static unsigned long torn;

static inline void casp(uint64_t *lo, uint64_t *hi, uint64_t nlo, uint64_t nhi,
                        struct pair *p)
{
    register uint64_t x0 __asm__("x0") = *lo;
    register uint64_t x1 __asm__("x1") = *hi;
    register uint64_t x2 __asm__("x2") = nlo;
    register uint64_t x3 __asm__("x3") = nhi;
    __asm__ __volatile__("caspal x0, x1, x2, x3, [%[p]]"
                         : "+r"(x0), "+r"(x1)
                         : "r"(x2), "r"(x3), [p] "r"(p)
                         : "memory");
    *lo = x0;
    *hi = x1;
}

static void *t_casp(void *arg)
{
    (void)arg;
    pthread_barrier_wait(&barrier);
    for (long i = 0; i < iters; i++) {
        uint64_t lo = 0, hi = MAGIC;   /* first guess; CASP returns the real value */
        for (;;) {
            uint64_t elo = lo, ehi = hi;
            casp(&lo, &hi, elo + 1, ehi + 3, &shared);
            if (lo == elo && hi == ehi) {
                break;
            }
            if (hi != lo * 3 + MAGIC) {
                __atomic_add_fetch(&torn, 1, __ATOMIC_RELAXED);
            }
        }
    }
    return NULL;
}

static void *t_ldxp(void *arg)
{
    (void)arg;
    pthread_barrier_wait(&barrier);
    for (long i = 0; i < iters; i++) {
        uint64_t lo, hi;
        uint32_t fail;
        do {
            __asm__ __volatile__("ldaxp %0, %1, [%2]" : "=&r"(lo), "=&r"(hi) : "r"(&shared) : "memory");
            if (hi != lo * 3 + MAGIC) {
                __atomic_add_fetch(&torn, 1, __ATOMIC_RELAXED);
            }
            __asm__ __volatile__("stlxp %w0, %1, %2, [%3]"
                                 : "=&r"(fail)
                                 : "r"(lo + 1), "r"(hi + 3), "r"(&shared)
                                 : "memory");
        } while (fail);
    }
    return NULL;
}

static void *t_casp_reader(void *arg)
{
    (void)arg;
    pthread_barrier_wait(&barrier);
    while (!stop_readers) {
        uint64_t lo = 0, hi = 0;
        casp(&lo, &hi, 0, 0, &shared);      /* atomic 16-byte read (never matches 0:0) */
        if (hi != lo * 3 + MAGIC) {
            __atomic_add_fetch(&torn, 1, __ATOMIC_RELAXED);
        }
    }
    return NULL;
}

static void *t_cas64(void *arg)
{
    (void)arg;
    pthread_barrier_wait(&barrier);
    for (long i = 0; i < iters; i++) {
        uint64_t old = __atomic_load_n(&shared64, __ATOMIC_RELAXED);
        while (!__atomic_compare_exchange_n(&shared64, &old, old + 1, 0,
                                            __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
        }
    }
    return NULL;
}

static void *t_ldxr64(void *arg)
{
    (void)arg;
    pthread_barrier_wait(&barrier);
    for (long i = 0; i < iters; i++) {
        uint64_t v;
        uint32_t fail;
        do {
            __asm__ __volatile__("ldaxr %0, [%1]" : "=&r"(v) : "r"(&shared64) : "memory");
            __asm__ __volatile__("stlxr %w0, %1, [%2]" : "=&r"(fail) : "r"(v + 1), "r"(&shared64)
                                 : "memory");
        } while (fail);
    }
    return NULL;
}

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* Runs nthreads of fn (plus nreaders of reader); returns 0 if the final state matches. */
static int run(const char *name, void *(*fn)(void *), int nthreads,
               void *(*reader)(void *), int nreaders, int is64)
{
    pthread_t th[NTHREADS];
    int n = nthreads + nreaders;

    shared.lo = 0;
    shared.hi = MAGIC;
    shared64 = 0;
    torn = 0;
    stop_readers = 0;
    pthread_barrier_init(&barrier, NULL, n + 1);
    for (int i = 0; i < nthreads; i++) {
        pthread_create(&th[i], NULL, fn, NULL);
    }
    for (int i = 0; i < nreaders; i++) {
        pthread_create(&th[nthreads + i], NULL, reader, NULL);
    }
    pthread_barrier_wait(&barrier);
    double t0 = now();
    for (int i = 0; i < nthreads; i++) {
        pthread_join(th[i], NULL);
    }
    double dt = now() - t0;
    stop_readers = 1;
    for (int i = 0; i < nreaders; i++) {
        pthread_join(th[nthreads + i], NULL);
    }
    pthread_barrier_destroy(&barrier);

    uint64_t want = (uint64_t)iters * nthreads;
    int ok;
    if (is64) {
        ok = shared64 == want;
        printf("A128 %-8s %s count %llu/%llu, %.0f ns/update\n", name, ok ? "ok  " : "FAIL",
               (unsigned long long)shared64, (unsigned long long)want, dt * 1e9 / want);
    } else {
        ok = shared.lo == want && shared.hi == want * 3 + MAGIC && torn == 0;
        printf("A128 %-8s %s count %llu/%llu, hi %s, torn %lu, %.0f ns/update\n", name,
               ok ? "ok  " : "FAIL", (unsigned long long)shared.lo, (unsigned long long)want,
               shared.hi == want * 3 + MAGIC ? "ok" : "BAD", torn, dt * 1e9 / want);
    }
    fflush(stdout);
    return ok ? 0 : 1;
}

int main(int argc, char **argv)
{
    int bad = 0;

    (void)argc;
    (void)argv;
    iters = 20000;
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("A128 start: %d threads, %ld updates each\n", NTHREADS, iters);
    bad += run("casp", t_casp, NTHREADS, NULL, 0, 0);
    bad += run("ldxp", t_ldxp, NTHREADS, NULL, 0, 0);
    bad += run("casp-ro", t_casp, 1, t_casp_reader, NTHREADS - 1, 0);
    bad += run("cas64", t_cas64, NTHREADS, NULL, 0, 1);
    bad += run("ldxr64", t_ldxr64, NTHREADS, NULL, 0, 1);
    printf("A128 %s\n", bad ? "FAIL" : "PASS");
    fflush(stdout);
    sync();
    reboot(RB_POWER_OFF);
    for (;;) {
        pause();
    }
}
