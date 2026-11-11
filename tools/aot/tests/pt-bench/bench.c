/*
 * Same-ISA passthrough benchmark (run.sh): times each loop of loops.S with
 * the guest virtual counter and prints "B <loop> <iterations> <ns>" on the
 * PL011.  Bare-metal, -M virt; entry and MMU setup from ../fp-passthrough.
 */
#include <stdint.h>

#define UART ((volatile uint32_t *)0x09000000)
#ifndef ITERS
#define ITERS 4000000
#endif

uint64_t loop_fp_scalar(uint64_t), loop_fp_vector(uint64_t), loop_fp_convert(uint64_t);
uint64_t loop_crypto(uint64_t), loop_int(uint64_t);
uint64_t pt_cntvct(void), pt_cntfrq(void);

static void uputc(char c)
{
    while (UART[0x18 / 4] & 0x20) {
    }
    UART[0] = (uint32_t)c;
}
static void uputs(const char *s)
{
    while (*s) {
        uputc(*s++);
    }
}
static void udec(uint64_t v)
{
    char b[24];
    int n = 0;
    do {
        b[n++] = '0' + v % 10;
        v /= 10;
    } while (v);
    while (n) {
        uputc(b[--n]);
    }
}

static const struct {
    const char *name;
    uint64_t (*fn)(uint64_t);
} loops[] = {
    { "fp_scalar", loop_fp_scalar }, { "fp_vector", loop_fp_vector },
    { "fp_convert", loop_fp_convert }, { "crypto", loop_crypto }, { "int", loop_int },
};

void pt_main(void)
{
    UART[0x30 / 4] = 0x301;
    uint64_t frq = pt_cntfrq();
    for (unsigned i = 0; i < sizeof(loops) / sizeof(loops[0]); i++) {
        loops[i].fn(1000);              /* translate (and chain) first */
        uint64_t t0 = pt_cntvct();
        uint64_t r = loops[i].fn(ITERS);
        uint64_t t1 = pt_cntvct();
        uputs("B ");
        uputs(loops[i].name);
        uputc(' ');
        udec(ITERS);
        uputc(' ');
        udec((t1 - t0) * 1000000000ull / frq);
        uputs(" r=");
        udec(r & 0xffff);
        uputc('\n');
    }
    uputs("DONE\n");
}
