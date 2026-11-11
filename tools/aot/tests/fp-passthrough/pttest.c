/*
 * Same-ISA passthrough differential test (docs/AOT.md, "Same-ISA
 * passthrough").  Bare-metal AArch64 program for -M virt -cpu cortex-a76:
 * runs every instruction in ops.S over special-value tables (+-0, +-Inf,
 * quiet and signalling NaNs with payloads, denormals, rounding ties,
 * overflow/underflow and integer-range edges) under several FPCR settings
 * (all rounding modes, FZ, DN) with FPSR cleared or Inexact primed, and
 * prints one hash per (group, FPCR, primed) plus a total checksum on the
 * PL011.  -DPT_VERBOSE prints every case.  Built freestanding with
 * -mgeneral-regs-only: the harness itself never executes an FP instruction.
 */
#include <stdint.h>

struct pt_in {
    uint64_t v1[2], v2[2], v3[2], v0[2];
    uint64_t x2, x3, pad[2];
} __attribute__((aligned(16)));
typedef void opfn(const struct pt_in *, uint64_t *);

void pt_set_fpcr(uint64_t);
void pt_set_fpsr(uint64_t);
uint64_t pt_get_fpsr(void);
void pt_prime_ix(void);

/* ---------------------------------------------------------------- UART */

#define UART ((volatile uint32_t *)0x09000000)

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
static void uhex(uint64_t v, int digits)
{
    for (int i = digits - 1; i >= 0; i--) {
        uputc("0123456789abcdef"[(v >> (4 * i)) & 15]);
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
static void upad(const char *s, int w)
{
    int n = 0;
    while (s[n]) {
        n++;
    }
    uputs(s);
    while (n++ < w) {
        uputc(' ');
    }
}

/* ---------------------------------------------------------- value sets */

static const uint32_t F32[] = {
    0x00000000, 0x80000000, 0x3f800000, 0xbf800000, 0x3f800001, 0x3fc00000, 0x40490fdb, 0x3eaaaaab,
    0x7f7fffff, 0xff7fffff, 0x00800000, 0x80800000, 0x00800001, 0x007fffff, 0x00000001, 0x80000001,
    0x7f800000, 0xff800000, 0x7fc00000, 0x7fc12345, 0xffc00001, 0x7f800001, 0x7fa00000, 0x4b000000,
    0x33800000, 0x34000000, 0x4f000000, 0xcf000000, 0x4f800000, 0x5f000000, 0x5f800000, 0x3f000000,
    0x40200000, 0xc0200000, 0x1f800000, 0x4effffff, 0xcf000001, 0x5effffff, 0x3effffff, 0xbfc00000,
};
static const uint64_t F64[] = {
    0x0000000000000000, 0x8000000000000000, 0x3ff0000000000000, 0xbff0000000000000,
    0x3ff0000000000001, 0x3ff8000000000000, 0x400921fb54442d18, 0x3fd5555555555555,
    0x7fefffffffffffff, 0xffefffffffffffff, 0x0010000000000000, 0x8010000000000000,
    0x0010000000000001, 0x000fffffffffffff, 0x0000000000000001, 0x8000000000000001,
    0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000, 0x7ff8000000012345,
    0xfff8000000000001, 0x7ff0000000000001, 0x7ff4000000000000, 0x4330000000000000,
    0x3ca0000000000000, 0x41e0000000000000, 0xc1e0000000000000, 0x41f0000000000000,
    0x43e0000000000000, 0x43f0000000000000, 0x3fe0000000000000, 0x4004000000000000,
    0xc004000000000000, 0x0170000000000000, 0x47efffffe0000000, 0x47effffff0000000,
    0x3810000000000000, 0x36a0000000000000, 0x41dfffffffe00000, 0xc1e0000000100000,
    0x43dfffffffffffff, 0xc3e0000000000000, 0x43efffffffffffff, 0x380fffffffffffff,
};
static const uint64_t I64[] = {
    0, 1, 0xffffffffffffffff, 2, 0xfffffffffffffffe, 3, 7, 0x7fffffff,
    0x80000000, 0xffffffff, 0x100000000, 0x1000001, 0x20000000000001, 0x7fffffffffffffff,
    0x8000000000000000, 0x8000000000000001, 0x123456789abcdef0, 0xfedcba9876543210,
    0xff, 0xffffff80, 0xffffff7f, 0x40000000000000ff, 0xc000000000000001, 0x00ffffff00000001,
};
#define N32 (int)(sizeof(F32) / sizeof(F32[0]))
#define N64 (int)(sizeof(F64) / sizeof(F64[0]))
#define NI (int)(sizeof(I64) / sizeof(I64[0]))

/*
 * FPCR: RN, RP, RM, RZ, FZ, DN, FZ+DN+RZ, then FEAT_AFP settings: AH,
 * AH+FIZ+NEP+FZ, FIZ+FZ16 (AH, FIZ and NEP are RES0 on cortex-a76, so these
 * are RN, FZ and FZ16 there; run.sh --cpu max has FEAT_AFP)
 */
#define AFP_FIZ (1 << 0)
#define AFP_AH (1 << 1)
#define AFP_NEP (1 << 2)
static const uint64_t CFG[] = {
    0, 1 << 22, 2 << 22, 3 << 22, 1 << 24, 1 << 25, (1 << 24) | (1 << 25) | (3 << 22),
    AFP_AH, AFP_AH | AFP_FIZ | AFP_NEP | (1 << 24), AFP_FIZ | (1 << 19),
};
#define NCFG (int)(sizeof(CFG) / sizeof(CFG[0]))

/* ------------------------------------------------------------- groups */

enum {
    K_S2, K_D2,         /* scalar binary: s1/d1, s2/d2 */
    K_S3, K_D3,         /* scalar ternary: + s3/d3 addend */
    K_S1, K_D1,         /* scalar unary */
    K_X1,               /* integer in x2 (int -> float) */
    K_V4S, K_V2D,       /* vector binary/ternary (v0 = accumulator) */
    K_V4S1, K_V2D1,     /* vector unary */
    K_VI32, K_VI64,     /* vector integer lanes (int -> float) */
    K_RAW,              /* random 128-bit vectors (integer Neon, crypto) */
    K_INT2,             /* integer pairs in x2, x3 */
};
#define FP_GROUP(k) ((k) <= K_VI64)

struct grp {
    const char *name;
    opfn *fn;
    int kind;
};

#define G(n, k) { #n, op_##n, k },
#define DECL(n, k) opfn op_##n;
#define GROUPS(X) \
    X(fadd_s, K_S2) X(fsub_s, K_S2) X(fmul_s, K_S2) X(fdiv_s, K_S2) \
    X(fmin_s, K_S2) X(fmax_s, K_S2) X(fminnm_s, K_S2) X(fmaxnm_s, K_S2) \
    X(fadd_d, K_D2) X(fsub_d, K_D2) X(fmul_d, K_D2) X(fdiv_d, K_D2) \
    X(fmin_d, K_D2) X(fmax_d, K_D2) X(fminnm_d, K_D2) X(fmaxnm_d, K_D2) \
    X(fcmp_s, K_S2) X(fcmpe_s, K_S2) X(fcmp_d, K_D2) X(fcmpe_d, K_D2) X(fcmp0_s, K_S1) \
    X(fmadd_s, K_S3) X(fmsub_s, K_S3) X(fnmadd_s, K_S3) X(fmadd_d, K_D3) X(fnmsub_d, K_D3) \
    X(fsqrt_s, K_S1) X(fsqrt_d, K_D1) X(fcvt_ds, K_S1) X(fcvt_sd, K_D1) \
    X(frintn_s, K_S1) X(frintm_s, K_S1) X(frintp_s, K_S1) X(frintz_s, K_S1) \
    X(frinta_s, K_S1) X(frinti_s, K_S1) X(frintx_s, K_S1) \
    X(frintn_d, K_D1) X(frintm_d, K_D1) X(frinta_d, K_D1) X(frinti_d, K_D1) X(frintx_d, K_D1) \
    X(fcvtzs_ws, K_S1) X(fcvtzs_xs, K_S1) X(fcvtzu_ws, K_S1) X(fcvtzu_xs, K_S1) \
    X(fcvtzs_wd, K_D1) X(fcvtzs_xd, K_D1) X(fcvtzu_wd, K_D1) X(fcvtzu_xd, K_D1) \
    X(fcvtns_ws, K_S1) X(fcvtms_xd, K_D1) X(fcvtps_wd, K_D1) X(fcvtas_xs, K_S1) \
    X(fcvtau_wd, K_D1) X(fcvtzs_ws8, K_S1) X(fcvtzu_xd32, K_D1) X(fcvtzs_xd64, K_D1) \
    X(scvtf_sx, K_X1) X(scvtf_sw, K_X1) X(ucvtf_sx, K_X1) X(ucvtf_sw, K_X1) \
    X(scvtf_dx, K_X1) X(scvtf_dw, K_X1) X(ucvtf_dx, K_X1) X(scvtf_sx3, K_X1) \
    X(ucvtf_sw16, K_X1) X(scvtf_dx40, K_X1) X(ucvtf_dx64, K_X1) \
    V3G(X, vfadd) V3G(X, vfsub) V3G(X, vfmul) V3G(X, vfdiv) V3G(X, vfmin) V3G(X, vfmax) \
    V3G(X, vfminnm) V3G(X, vfmaxnm) V3G(X, vfcmeq) V3G(X, vfcmge) V3G(X, vfcmgt) \
    V3G(X, vfmla) V3G(X, vfmls) \
    X(vfmul_e4s, K_V4S) X(vfmul_e2s, K_V4S) X(vfmul_e2d, K_V2D) X(vfmla_e4s, K_V4S) \
    X(vfmla_e2s, K_V4S) X(vfmla_e2d, K_V2D) X(vfmls_e4s, K_V4S) \
    X(vfcmeq0_4s, K_V4S1) X(vfcmgt0_4s, K_V4S1) X(vfcmge0_2s, K_V4S1) X(vfcmlt0_4s, K_V4S1) \
    X(vfcmle0_2d, K_V2D1) X(vfcmeq0_2d, K_V2D1) \
    X(vscvtf_4s, K_VI32) X(vucvtf_2s, K_VI32) X(vscvtf_4s5, K_VI32) X(vucvtf_4s32, K_VI32) \
    X(vscvtf_2d, K_VI64) X(vucvtf_2d20, K_VI64) \
    X(vfcvtzs_4s, K_V4S1) X(vfcvtzu_2s, K_V4S1) X(vfcvtzs_4s4, K_V4S1) X(vfcvtzu_4s31, K_V4S1) \
    X(vfcvtns_4s, K_V4S1) X(vfcvtms_2s, K_V4S1) X(vfcvtpu_4s, K_V4S1) X(vfcvtas_4s, K_V4S1) \
    X(vfcvtzs_2d, K_V2D1) X(vfcvtnu_2d, K_V2D1) X(vfcvtzs_2d10, K_V2D1) \
    X(alias_fadd, K_V4S) X(alias_fmla_e, K_V4S) X(alias_fmul_e, K_V2D) X(alias_fmls, K_V4S) \
    X(alias_addp, K_RAW) X(alias_aesmc, K_RAW) X(alias_sha256h, K_RAW) \
    X(addp_16b, K_RAW) X(addp_8b, K_RAW) X(addp_8h, K_RAW) X(addp_2s, K_RAW) X(addp_2d, K_RAW) \
    X(umaxp_16b, K_RAW) X(uminp_8b, K_RAW) X(smaxp_8h, K_RAW) X(sminp_4s, K_RAW) \
    X(cnt_16b, K_RAW) X(cnt_8b, K_RAW) X(rbit_16b, K_RAW) X(rbit_8b, K_RAW) \
    X(xtn_8b, K_RAW) X(xtn2_4h, K_RAW) X(shll_8h, K_RAW) X(shll2_2d, K_RAW) \
    X(clz_8h, K_RAW) X(clz_4h, K_RAW) \
    X(aese, K_RAW) X(aesd, K_RAW) X(aesmc, K_RAW) X(aesimc, K_RAW) X(aese_mc, K_RAW) \
    X(sha256h, K_RAW) X(sha256h2, K_RAW) X(sha256su0, K_RAW) X(sha256su1, K_RAW) \
    X(crc32b, K_INT2) X(crc32h, K_INT2) X(crc32w, K_INT2) X(crc32x, K_INT2) \
    X(crc32cb, K_INT2) X(crc32ch, K_INT2) X(crc32cw, K_INT2) X(crc32cx, K_INT2) \
    X(smulh, K_INT2) X(umulh, K_INT2) X(sdiv, K_INT2) X(udiv, K_INT2) X(rbit_x, K_INT2) X(rbit_w, K_INT2) \
    X(frintp_d, K_D1) X(frintz_d, K_D1) X(fnmul_s, K_S2) X(fnmadd_d, K_D3) \
    X(fcvtzu_ws12, K_S1) X(fcvtnu_xs, K_S1) X(fcvtmu_wd, K_D1) X(fcvtpu_xd, K_D1) \
    X(scvtf_sw32, K_X1) X(ucvtf_dw, K_X1) X(fcvtzs_s1, K_S1) X(fcvtzu_d1, K_D1) \
    X(scvtf_s1, K_VI32) X(ucvtf_d1, K_VI64) X(vucvtf_4s, K_VI32) X(vscvtf_2d64, K_VI64) \
    X(vfcvtzu_2d64, K_V2D1) X(vfcvtmu_2d, K_V2D1) X(vfcvtps_2d, K_V2D1) X(vfcvtau_4s, K_V4S1) \
    X(vfmls_e2d, K_V2D) X(vfmls_e2s, K_V4S) X(vfcmgt0_2s, K_V4S1) X(vfcmle0_4s, K_V4S1) \
    X(aesd_imc, K_RAW) X(addp_4h, K_RAW) X(smaxp_16b, K_RAW) X(uminp_8h, K_RAW) X(umaxp_2s, K_RAW)
#define V3G(X, n) X(n##_4s, K_V4S) X(n##_2s, K_V4S) X(n##_2d, K_V2D)

GROUPS(DECL)
static const struct grp groups[] = { GROUPS(G) };
#define NGROUPS (int)(sizeof(groups) / sizeof(groups[0]))

/* ---------------------------------------------------------------- run */

static uint64_t fnv(uint64_t h, uint64_t w)
{
    for (int i = 0; i < 8; i++) {
        h ^= (w >> (8 * i)) & 0xff;
        h *= 0x100000001b3ull;
    }
    return h;
}

static uint64_t lcg_state = 0x9e3779b97f4a7c15ull;
static uint64_t rnd(void)
{
    lcg_state = lcg_state * 6364136223846793005ull + 1442695040888963407ull;
    return lcg_state ^ (lcg_state >> 29);
}

/* number of cases of a kind, and the case's inputs */
static int ncases(int kind)
{
    switch (kind) {
    case K_S2: case K_V4S: return N32 * N32;
    case K_D2: case K_V2D: return N64 * N64;
    case K_S3: return N32 * N32 * 3;
    case K_D3: return N64 * N64 * 3;
    case K_S1: return N32;
    case K_D1: return N64;
    case K_X1: return NI;
    case K_V4S1: return N32 * 4;
    case K_V2D1: return N64 * 2;
    case K_VI32: case K_VI64: return NI * NI;
    case K_RAW: return 256;
    default: return NI * NI;
    }
}

static uint64_t p32(uint32_t lo, uint32_t hi)
{
    return (uint64_t)hi << 32 | lo;
}

static void fill(struct pt_in *in, int kind, int c)
{
    int i, j, k;
    /* defaults: recognizable garbage in upper lanes / unused registers */
    in->v1[0] = in->v1[1] = 0x5555aaaa5555aaaaull;
    in->v2[0] = in->v2[1] = 0x3333cccc3333ccccull;
    in->v3[0] = in->v3[1] = 0x0f0f0f0ff0f0f0f0ull;
    in->v0[0] = in->v0[1] = 0x123456789abcdef0ull;
    in->x2 = 0x1111111111111111ull;
    in->x3 = 0x2222222222222222ull;
    switch (kind) {
    case K_S2:
        i = c / N32, j = c % N32;
        in->v1[0] = p32(F32[i], 0xdeadbeef);
        in->v2[0] = p32(F32[j], 0xfeedface);
        break;
    case K_D2:
        i = c / N64, j = c % N64;
        in->v1[0] = F64[i];
        in->v2[0] = F64[j];
        break;
    case K_S3:
        k = c % 3, c /= 3, i = c / N32, j = c % N32;
        in->v1[0] = p32(F32[i], 0xdeadbeef);
        in->v2[0] = F32[j];
        in->v3[0] = k == 0 ? F32[(i + 2 * j + 1) % N32] : k == 1 ? 0 : F32[(i * j + 7) % N32];
        break;
    case K_D3:
        k = c % 3, c /= 3, i = c / N64, j = c % N64;
        in->v1[0] = F64[i];
        in->v2[0] = F64[j];
        in->v3[0] = k == 0 ? F64[(i + 2 * j + 1) % N64] : k == 1 ? 0x8000000000000000ull
                                                                 : F64[(i * j + 7) % N64];
        break;
    case K_S1:
        in->v1[0] = p32(F32[c], 0xdeadbeef);
        break;
    case K_D1:
        in->v1[0] = F64[c];
        break;
    case K_X1:
        in->x2 = I64[c];
        break;
    case K_V4S:
        i = c / N32, j = c % N32;
        in->v1[0] = p32(F32[i], F32[j]);
        in->v1[1] = p32(F32[(i + j) % N32], F32[(3 * i + 1) % N32]);
        in->v2[0] = p32(F32[j], F32[i]);
        in->v2[1] = p32(F32[(i + 5) % N32], F32[(7 * j + 2) % N32]);
        in->v0[0] = p32(F32[(i + j + 3) % N32], F32[(j + 1) % N32]);
        in->v0[1] = p32(F32[(i + 11) % N32], F32[(i * j) % N32]);
        break;
    case K_V2D:
        i = c / N64, j = c % N64;
        in->v1[0] = F64[i];
        in->v1[1] = F64[j];
        in->v2[0] = F64[j];
        in->v2[1] = F64[(i + j) % N64];
        in->v0[0] = F64[(i + 3) % N64];
        in->v0[1] = F64[(5 * j + 1) % N64];
        break;
    case K_V4S1:
        i = c / 4, j = c % 4;
        in->v1[0] = p32(F32[i], F32[(i + 1 + j) % N32]);
        in->v1[1] = p32(F32[(i + 7 * j) % N32], F32[(3 * i + 5 + j) % N32]);
        break;
    case K_V2D1:
        i = c / 2, j = c % 2;
        in->v1[0] = F64[i];
        in->v1[1] = F64[(i + 1 + 9 * j) % N64];
        break;
    case K_VI32:
        i = c / NI, j = c % NI;
        in->v1[0] = p32((uint32_t)I64[i], (uint32_t)I64[j]);
        in->v1[1] = p32((uint32_t)(I64[(i + j) % NI] >> 32), (uint32_t)I64[(5 * i + 3) % NI]);
        break;
    case K_VI64:
        i = c / NI, j = c % NI;
        in->v1[0] = I64[i];
        in->v1[1] = I64[j];
        break;
    case K_RAW:
        in->v1[0] = rnd(), in->v1[1] = rnd();
        in->v2[0] = rnd(), in->v2[1] = rnd();
        in->v3[0] = rnd(), in->v3[1] = rnd();
        in->v0[0] = rnd(), in->v0[1] = rnd();
        if (c < 16) {           /* some all-zero / all-one lanes */
            in->v1[c & 1] = (c & 2) ? ~0ull : 0;
            in->v2[(c >> 2) & 1] = (c & 8) ? ~0ull : 0;
        }
        break;
    default:                    /* K_INT2 */
        i = c / NI, j = c % NI;
        in->x2 = I64[i];
        in->x3 = I64[j];
        break;
    }
}

static uint64_t total = 0xcbf29ce484222325ull;
static int fails;

static void run_group(const struct grp *g, int cfg, int pre)
{
    static struct pt_in in;
    static uint64_t out[4] __attribute__((aligned(16)));
    int n = ncases(g->kind);
    uint64_t h = 0xcbf29ce484222325ull;

    lcg_state = 0x9e3779b97f4a7c15ull ^ (uint64_t)n;
    for (int c = 0; c < n; c++) {
        fill(&in, g->kind, c);
        pt_set_fpcr(CFG[cfg]);
        pt_set_fpsr(0);
        if (pre) {
            pt_prime_ix();
        }
        g->fn(&in, out);
        uint64_t fpsr = pt_get_fpsr();
        pt_set_fpcr(0);
        h = fnv(h, out[0]);
        h = fnv(h, out[1]);
        h = fnv(h, out[2]);
        h = fnv(h, fpsr);
#ifdef PT_VERBOSE
        uputs("C ");
        upad(g->name, 14);
        uputs(" c");
        udec(cfg);
        uputs(" p");
        udec(pre);
        uputc(' ');
        udec(c);
        uputs(" in=");
        uhex(in.v1[1], 16), uhex(in.v1[0], 16), uputc(' ');
        uhex(in.v2[1], 16), uhex(in.v2[0], 16), uputc(' ');
        uhex(in.v3[0], 16), uputc(' '), uhex(in.v0[1], 16), uhex(in.v0[0], 16), uputc(' ');
        uhex(in.x2, 16), uputc(' '), uhex(in.x3, 16);
        uputs(" out=");
        uhex(out[1], 16), uhex(out[0], 16), uputc(' '), uhex(out[2], 16);
        uputs(" fpsr=");
        uhex(fpsr, 8);
        uputc('\n');
#endif
    }
    uputs("G ");
    upad(g->name, 14);
    uputs(" c");
    udec(cfg);
    uputs(" p");
    udec(pre);
    uputs(" n=");
    udec(n);
    uputs(" h=");
    uhex(h, 16);
    uputc('\n');
    total = fnv(total, h);
}

/* known answers (architecture, not emulator): catches a common bug */
static void kat(const char *name, opfn *fn, uint64_t fpcr, uint64_t a, uint64_t b,
                uint64_t x2, uint64_t x3, int reg, uint64_t mask, uint64_t want, uint64_t want_fpsr)
{
    static struct pt_in in;
    static uint64_t out[4] __attribute__((aligned(16)));
    fill(&in, K_INT2, 0);
    in.v1[0] = a, in.v1[1] = 0;
    in.v2[0] = b, in.v2[1] = 0;
    in.x2 = x2, in.x3 = x3;
    pt_set_fpcr(fpcr);
    pt_set_fpsr(0);
    fn(&in, out);
    uint64_t fpsr = pt_get_fpsr();
    pt_set_fpcr(0);
    uint64_t got = out[reg] & mask;
    int ok = got == want && fpsr == want_fpsr;
    uputs("K ");
    upad(name, 22);
    uputs(" got=");
    uhex(got, 16);
    uputs(" fpsr=");
    uhex(fpsr, 8);
    uputs(ok ? " OK\n" : " FAIL\n");
    fails += !ok;
    total = fnv(total, got);
    total = fnv(total, fpsr);
}

void pt_main(void)
{
    UART[0x30 / 4] = 0x301;     /* UARTEN | TXE | RXE */
    uputs("pt-test: same-ISA passthrough differential test\n");
#define M32 0xffffffffull
#define M64 ~0ull
#define RP (1 << 22)
#define FZ (1 << 24)
#define DN (1 << 25)
    kat("fadd_s 1+2^-24 RN", op_fadd_s, 0, 0x3f800000, 0x33800000, 0, 0, 0, M32, 0x3f800000, 0x10);
    kat("fadd_s 1+2^-24 RP", op_fadd_s, RP, 0x3f800000, 0x33800000, 0, 0, 0, M32, 0x3f800001, 0x10);
    kat("fmul_s max*2", op_fmul_s, 0, 0x7f7fffff, 0x40000000, 0, 0, 0, M32, 0x7f800000, 0x14);
    kat("fdiv_s 1/0", op_fdiv_s, 0, 0x3f800000, 0, 0, 0, 0, M32, 0x7f800000, 0x02);
    kat("fadd_s inf-inf", op_fadd_s, 0, 0x7f800000, 0xff800000, 0, 0, 0, M32, 0x7fc00000, 0x01);
    kat("fadd_s snan", op_fadd_s, 0, 0x7f800001, 0x3f800000, 0, 0, 0, M32, 0x7fc00001, 0x01);
    kat("fadd_s qnan DN", op_fadd_s, DN, 0x7fc12345, 0x3f800000, 0, 0, 0, M32, 0x7fc00000, 0x00);
    kat("fmul_s FZ underflow", op_fmul_s, FZ, 0x00800000, 0x3f000000, 0, 0, 0, M32, 0, 0x08);
    kat("fadd_s FZ denormal in", op_fadd_s, FZ, 0x00000001, 0, 0, 0, 0, M32, 0, 0x80);
    kat("fmul_s denormal out", op_fmul_s, 0, 0x00800000, 0x3f000000, 0, 0, 0, M32, 0x00400000, 0x00);
    kat("fmul_s tiny inexact", op_fmul_s, 0, 0x00800001, 0x3f000000, 0, 0, 0, M32, 0x00400000, 0x18);
    kat("fsqrt_d 2", op_fsqrt_d, 0, 0x4000000000000000, 0, 0, 0, 0, M64, 0x3ff6a09e667f3bcd, 0x10);
    kat("fcvtzs_ws 2^31", op_fcvtzs_ws, 0, 0x4f000000, 0, 0, 0, 2, M32, 0x7fffffff, 0x01);
    kat("fcvtzs_xd -2.5", op_fcvtzs_xd, 0, 0xc004000000000000, 0, 0, 0, 2, M64, 0xfffffffffffffffe, 0x10);
    kat("fcvtas_xs -2.5", op_fcvtas_xs, 0, 0xc0200000, 0, 0, 0, 2, M64, 0xfffffffffffffffd, 0x10);
    kat("fcvt_sd max+half", op_fcvt_sd, 0, 0x47effffff0000000, 0, 0, 0, 0, M32, 0x7f800000, 0x14);
    kat("scvtf_sx 2^24+1", op_scvtf_sx, 0, 0, 0, 0x1000001, 0, 0, M32, 0x4b800000, 0x10);
    kat("fcmp_s qnan", op_fcmp_s, 0, 0x7fc00000, 0, 0, 0, 2, M64, 0x30000000, 0x00);
    kat("fcmpe_s qnan", op_fcmpe_s, 0, 0x7fc00000, 0, 0, 0, 2, M64, 0x30000000, 0x01);
    kat("umulh -1*-1", op_umulh, 0, 0, 0, M64, M64, 2, M64, 0xfffffffffffffffe, 0);
    kat("smulh -1*-1", op_smulh, 0, 0, 0, M64, M64, 2, M64, 0, 0);
    kat("sdiv min/-1", op_sdiv, 0, 0, 0, 0x8000000000000000, M64, 2, M64, 0x8000000000000000, 0);
    kat("udiv x/0", op_udiv, 0, 0, 0, 5, 0, 2, M64, 0, 0);
    kat("crc32cx 0,0", op_crc32cx, 0, 0, 0, 0, 0, 2, M64, 0, 0);
    kat("crc32b ~0,0", op_crc32b, 0, 0, 0, 0xffffffff, 0, 2, M64, 0x2dfd1072, 0);
    for (int g = 0; g < NGROUPS; g++) {
        int fp = FP_GROUP(groups[g].kind);
        for (int cfg = 0; cfg < (fp ? NCFG : 1); cfg++) {
            for (int pre = 0; pre < (fp ? 2 : 1); pre++) {
                run_group(&groups[g], cfg, pre);
            }
        }
    }
    uputs("KAT failures: ");
    udec(fails);
    uputs("\nCHECKSUM ");
    uhex(total, 16);
    uputs("\nDONE\n");
}
