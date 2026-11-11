/*
 * Runtime support for AOT-generated TB functions (see tcg2c.py and
 * engine/qemu-aot/tcg/aot.c).  Generated code does not include any QEMU
 * header: CPU state is addressed by raw offsets taken from the capture build,
 * and the table's layout signature pins it to that QEMU build.
 *
 * Function ABI: uintptr_t f(void *env, const uintptr_t *R, uintptr_t *ra)
 *   R[0 .. nexits)            TCTI stream addresses of this TB's exits
 *   R[nexits .. +icount)      per-insn unwind return addresses (GETPC)
 *   R[nexits+icount .. )      pooled constants (possible host pointers)
 *   *ra                       = tcti_call_return_address (helpers' GETPC)
 * Returns the TCTI stream address to continue dispatching at.
 */
#ifndef AOT_RT_H
#define AOT_RT_H
#include <stdint.h>
#include <string.h>

#ifndef AOT_PAGE_BITS
#define AOT_PAGE_BITS 12
#endif
#define AOT_PAGE_MASK (~(uint64_t)((1u << AOT_PAGE_BITS) - 1))
#define AOT_TLB_ENTRY_BITS 5
#define AOT_TLB_ADDEND 24

#define likely(x)   __builtin_expect(!!(x), 1)
#define unlikely(x) __builtin_expect(!!(x), 0)

typedef uintptr_t (*aot_fn_t)(void *, const uintptr_t *, uintptr_t *);

#ifdef AOT_STATIC
/* Statically linked into QEMU: call helpers directly by symbol. */
#define H(k, sym) ((void *)&sym)
#else
/* dylib: helper addresses bound at load time by QEMU. */
extern void *aot_H[] __attribute__((visibility("hidden")));
#define H(k, sym) (aot_H[k])
#endif
extern void *aot_RT[] __attribute__((visibility("hidden")));

#define G8(o)   (*(uint8_t *)(env + (o)))
#define G32(o)  (*(uint32_t *)(env + (o)))
#define G64(o)  (*(uint64_t *)(env + (o)))
#define PTR(x)  ((char *)(uintptr_t)(x))

#ifdef AOT_VERIFY
#define AOT_FN(k) aot_v_##k
#define RT_JOURNAL(p, n) ((void (*)(void *, uint32_t))aot_RT[0])((void *)(p), (n))
#define RT_UNSAFE()      ((void (*)(void))aot_RT[1])()
#define RT_SLOW_BEGIN()  ((void (*)(void))aot_RT[2])()
#define RT_SLOW_END(ok)  ((void (*)(int))aot_RT[3])(ok)
#else
#define AOT_FN(k) aot_f_##k
#define RT_JOURNAL(p, n) ((void)0)
#define RT_UNSAFE()      ((void)0)
#define RT_SLOW_BEGIN()  ((void)0)
#define RT_SLOW_END(ok)  ((void)0)
#endif

/*
 * goto_tb: R[k] is the TCTI goto_tb gadget of this TB, followed by its
 * jump slot.  If the slot is chained to a TB that also has native code
 * ([gadget_aot_enter, rec] header), tail-call it directly; otherwise let the
 * TCTI dispatcher take the slot (chained TCTI TB or unchained exit).
 * rec layout: call at word 0, w[] at word 5 (see AotRec in tcg/aot.c).
 */
#if defined(AOT_VERIFY) || defined(AOT_NO_CHAIN)
#define AOT_GOTO_TB(k) return R[k]
#else
#define AOT_GOTO_TB(k) do { \
        uintptr_t p_ = R[k]; \
        uintptr_t t_ = __atomic_load_n((uintptr_t *)(p_ + 8), __ATOMIC_RELAXED); \
        if (*(uintptr_t *)t_ == (uintptr_t)aot_RT[4]) { \
            const uintptr_t *r_ = *(const uintptr_t **)(t_ + 8); \
            __attribute__((musttail)) return ((aot_fn_t)r_[0])(env_, r_ + 5, ra); \
        } \
        return p_; \
    } while (0)
#endif

/*
 * exit_tb from lookup_and_goto_ptr: let QEMU look up the next TB and
 * continue there (natively when it has AOT code); R[k] on a miss.
 */
#if defined(AOT_VERIFY) || defined(AOT_NO_CHAIN)
#define AOT_GOTO_PTR(k) return R[k]
#else
#define AOT_GOTO_PTR(k) \
    __attribute__((musttail)) return ((aot_fn_t)aot_RT[5])(env_, (const uintptr_t *)R[k], ra)
#endif

/*
 * Softmmu TLB fast path, same test as the aarch64 JIT backend:
 * comparator == (addr [+ s_mask - a_mask]) & (page_mask | a_mask).
 * Returns the host address or 0 (miss, MMIO, watchpoint, misalignment...).
 */
static inline __attribute__((always_inline)) uintptr_t
aot_tlb(char *env, uint64_t addr, int ofs, int is_write, unsigned s_bits, unsigned a_bits)
{
    uint64_t mask = *(uint64_t *)(env + ofs);
    char *table = *(char **)(env + ofs + 8);
    char *ent = table + ((addr >> (AOT_PAGE_BITS - AOT_TLB_ENTRY_BITS)) & mask);
    uint64_t cmp = *(uint64_t *)(ent + (is_write ? 8 : 0));
    uint64_t a_mask = (1ull << a_bits) - 1, s_mask = (1ull << s_bits) - 1;
    uint64_t x = addr + (a_bits >= s_bits ? 0 : s_mask - a_mask);
    if (likely(cmp == (x & (AOT_PAGE_MASK | a_mask)))) {
        return (uintptr_t)(addr + *(uint64_t *)(ent + AOT_TLB_ADDEND));
    }
    return 0;
}

static inline uint64_t aot_ldh(uintptr_t h, unsigned s)
{
    switch (s) {
    case 0: return *(uint8_t *)h;
    case 1: { uint16_t v; memcpy(&v, (void *)h, 2); return v; }
    case 2: { uint32_t v; memcpy(&v, (void *)h, 4); return v; }
    default: { uint64_t v; memcpy(&v, (void *)h, 8); return v; }
    }
}

static inline void aot_sth(uintptr_t h, unsigned s, uint64_t v)
{
    switch (s) {
    case 0: *(uint8_t *)h = v; break;
    case 1: { uint16_t x = v; memcpy((void *)h, &x, 2); break; }
    case 2: { uint32_t x = v; memcpy((void *)h, &x, 4); break; }
    default: memcpy((void *)h, &v, 8); break;
    }
}

static inline uint64_t aot_bswap(uint64_t v, unsigned s)
{
    switch (s) {
    case 0: return v;
    case 1: return __builtin_bswap16(v);
    case 2: return __builtin_bswap32(v);
    default: return __builtin_bswap64(v);
    }
}

static inline uint64_t aot_sext(uint64_t v, unsigned s)
{
    switch (s) {
    case 0: return (uint64_t)(int64_t)(int8_t)v;
    case 1: return (uint64_t)(int64_t)(int16_t)v;
    case 2: return (uint64_t)(int64_t)(int32_t)v;
    default: return v;
    }
}

/* Integer division with AArch64 sdiv/udiv semantics (TCTI uses those). */
static inline uint32_t aot_div32(uint32_t a, uint32_t b)
{
    if (b == 0) return 0;
    if ((int32_t)a == INT32_MIN && (int32_t)b == -1) return a;
    return (uint32_t)((int32_t)a / (int32_t)b);
}
static inline uint32_t aot_rem32(uint32_t a, uint32_t b)
{
    return a - aot_div32(a, b) * b;
}
static inline uint32_t aot_divu32(uint32_t a, uint32_t b) { return b ? a / b : 0; }
static inline uint32_t aot_remu32(uint32_t a, uint32_t b) { return a - aot_divu32(a, b) * b; }
static inline uint64_t aot_div64(uint64_t a, uint64_t b)
{
    if (b == 0) return 0;
    if ((int64_t)a == INT64_MIN && (int64_t)b == -1) return a;
    return (uint64_t)((int64_t)a / (int64_t)b);
}
static inline uint64_t aot_rem64(uint64_t a, uint64_t b) { return a - aot_div64(a, b) * b; }
static inline uint64_t aot_divu64(uint64_t a, uint64_t b) { return b ? a / b : 0; }
static inline uint64_t aot_remu64(uint64_t a, uint64_t b) { return a - aot_divu64(a, b) * b; }

/* Vector temps (TCG_TYPE_V64/V128) are kept as 128-bit values; V64 ops only
 * ever load/store the low 8 bytes and all TCG vector ops are lane-local. */
typedef uint64_t aot_v128 __attribute__((vector_size(16)));
typedef uint8_t  aot_u8  __attribute__((vector_size(16)));
typedef int8_t   aot_s8  __attribute__((vector_size(16)));
typedef uint16_t aot_u16 __attribute__((vector_size(16)));
typedef int16_t  aot_s16 __attribute__((vector_size(16)));
typedef uint32_t aot_u32 __attribute__((vector_size(16)));
typedef int32_t  aot_s32 __attribute__((vector_size(16)));
typedef uint64_t aot_u64 __attribute__((vector_size(16)));
typedef int64_t  aot_s64 __attribute__((vector_size(16)));

static inline aot_v128 aot_vld(const char *p, int is128)
{
    aot_v128 v = { 0, 0 };
    memcpy(&v, p, is128 ? 16 : 8);
    return v;
}
static inline void aot_vst(char *p, aot_v128 v, int is128)
{
    memcpy(p, &v, is128 ? 16 : 8);
}

/* AArch64 SSHL lane semantics (TCTI aa64_sshl_vec). */
static inline aot_v128 aot_sshl8(aot_v128 a_, aot_v128 b_)
{
    int8_t a[16], r[16]; uint8_t b[16]; memcpy(a, &a_, 16); memcpy(b, &b_, 16);
    for (int i = 0; i < 16; i++) {
        int c = (int8_t)b[i];
        r[i] = c >= 0 ? (c >= 8 ? 0 : (int8_t)((uint8_t)a[i] << c)) : (-c >= 8 ? (a[i] < 0 ? -1 : 0) : a[i] >> -c);
    }
    aot_v128 o; memcpy(&o, r, 16); return o;
}
static inline aot_v128 aot_sshl16(aot_v128 a_, aot_v128 b_)
{
    int16_t a[8], r[8]; uint16_t b[8]; memcpy(a, &a_, 16); memcpy(b, &b_, 16);
    for (int i = 0; i < 8; i++) {
        int c = (int8_t)b[i];
        r[i] = c >= 0 ? (c >= 16 ? 0 : (int16_t)((uint16_t)a[i] << c)) : (-c >= 16 ? (a[i] < 0 ? -1 : 0) : a[i] >> -c);
    }
    aot_v128 o; memcpy(&o, r, 16); return o;
}
static inline aot_v128 aot_sshl32(aot_v128 a_, aot_v128 b_)
{
    int32_t a[4], r[4]; uint32_t b[4]; memcpy(a, &a_, 16); memcpy(b, &b_, 16);
    for (int i = 0; i < 4; i++) {
        int c = (int8_t)b[i];
        r[i] = c >= 0 ? (c >= 32 ? 0 : (int32_t)((uint32_t)a[i] << c)) : (-c >= 32 ? (a[i] < 0 ? -1 : 0) : a[i] >> -c);
    }
    aot_v128 o; memcpy(&o, r, 16); return o;
}
static inline aot_v128 aot_sshl64(aot_v128 a_, aot_v128 b_)
{
    int64_t a[2], r[2]; uint64_t b[2]; memcpy(a, &a_, 16); memcpy(b, &b_, 16);
    for (int i = 0; i < 2; i++) {
        int c = (int8_t)b[i];
        r[i] = c >= 0 ? (c >= 64 ? 0 : (int64_t)((uint64_t)a[i] << c)) : (-c >= 64 ? (a[i] < 0 ? -1 : 0) : a[i] >> -c);
    }
    aot_v128 o; memcpy(&o, r, 16); return o;
}

/*
 * AArch64 USHL lane semantics: TCTI's shlv_vec gadget is USHL, and TCTI
 * expands shrv/rotlv/rotrv into shlv with negative counts (right shifts).
 */
#define AOT_USHL(BITS, U, N)                                                    \
static inline aot_v128 aot_ushl##BITS(aot_v128 a_, aot_v128 b_)                \
{                                                                               \
    U a[N], b[N], r[N]; memcpy(a, &a_, 16); memcpy(b, &b_, 16);                 \
    for (int i = 0; i < N; i++) {                                               \
        int c = (int8_t)b[i];                                                   \
        r[i] = c >= 0 ? (c >= BITS ? 0 : (U)(a[i] << c)) : (-c >= BITS ? 0 : a[i] >> -c); \
    }                                                                           \
    aot_v128 o; memcpy(&o, r, 16); return o;                                    \
}
AOT_USHL(8, uint8_t, 16)
AOT_USHL(16, uint16_t, 8)
AOT_USHL(32, uint32_t, 4)
AOT_USHL(64, uint64_t, 2)

static inline uint64_t aot_mask(unsigned len)
{
    return len >= 64 ? ~0ull : ((1ull << len) - 1);
}

/* ===================================================================== */
/*
 * Same-ISA passthrough (docs/AOT.md "Same-ISA passthrough").  Guest and host
 * are both AArch64, so tcg2c.py (unless --no-passthrough) emits helper calls
 * whose architectural result is one host instruction or a short exact
 * sequence as aot_pt_<helper>() below.  Infallible ones (integer, crypto,
 * CRC, pairwise/bit Neon) always produce the helper's result.  Fallible ones
 * (all FP) return 0 when they cannot prove that their result and flags are
 * bit-identical to the helper's; nothing has been written at that point and
 * the generated code calls the original helper with the same arguments.
 *
 * Exactness rules:
 *
 *  1. Host FP environment.  QEMU's vCPU threads run with host FPCR == 0
 *     (RNE, no FZ/FZ16/FIZ/DN/AH, no trap enables); QEMU never writes the
 *     host FPCR (no fesetround/msr fpcr outside tests).  Every FP
 *     passthrough reads the host FPCR (one volatile mrs, ~1 cycle) and falls
 *     back unless it is 0, so a device model or library that changes it on
 *     a vCPU thread cannot make results wrong (the FPCR of the thread that
 *     loads the cache says nothing about the vCPU threads, so it is not
 *     checked at load time).  aot_pt_on, set by aot_table.c's constructor,
 *     is cleared by QEMU_AOT_PT_FP=0 (FP passthrough off at run time, A/B;
 *     integer, crypto and CRC passthrough stay on).  The cache is compiled with
 *     -ffp-contract=off and without fast-math, so C float operators,
 *     __builtin_fma, sqrt and the frint builtins are single IEEE operations
 *     in that environment, and the default build never reads FPSR, so the
 *     compiler is free to schedule them.
 *
 *  2. float_status, QEMU 10.0 include/fpu/softfloat-types.h (18 bytes):
 *       [0..1]  float_exception_flags     [2] float_rounding_mode
 *       [3..17] floatx80 precision and behaviour, 2- and 3-NaN rules,
 *               infzeronan rule, tininess_before_rounding, flush_to_zero,
 *               ftz_detection, flush_inputs_to_zero, default_nan_mode,
 *               default_nan_pattern, snan_bit_is_one, no_signaling_nans,
 *               rebias_overflow, rebias_underflow
 *     Bytes 3..17 must equal AOT_FS_CFG3/AOT_FS_CFG10: the status QEMU builds
 *     for FPST_A64/FPST_A32 with FPCR.FZ = FIZ = DN = AH = 0 (reset values
 *     plus arm_set_default_fp_behaviours()).  Every other state (FZ, FIZ,
 *     DN, AH = 1, the AArch32 "standard FPSCR" status with FZ+DN, ...) falls
 *     back.  Ops that round with the FPCR mode also need byte 2 == RNE;
 *     conversions to integer and FRINT* instead pick the host rounding
 *     instruction from byte 2 (RNE, -Inf, +Inf, zero, ties-away; the
 *     round-to-odd modes fall back).  Byte 2 is checked as a byte of its
 *     own, so a set_rmode just before is forwarded by the compiler.
 *
 *  3. Cumulative exception flags.  The guest FPSR is assembled from
 *     float_exception_flags (vfp_get_fpsr), and the verifier compares the
 *     whole float_status, so the inline path must leave exactly the flags
 *     the helper would leave (including QEMU-internal ones such as
 *     invalid_cvti or input_denormal_used).  The default build never reads
 *     the host FPSR.  It only accepts inputs for which the helper can raise
 *     at most Inexact, and it knows whether Inexact is raised:
 *       - add/sub/mul/div/sqrt/fma: QEMU's own hardfloat rule
 *         (fpu/softfloat.c float*_gen2, float*_muladd, float*_sqrt):
 *         Inexact already set, RNE, inputs zero or normal (div: divisor
 *         normal, sqrt: +0 or positive normal), and the result neither
 *         infinite nor <= the smallest normal unless it is an exact zero
 *         (zero operands).  The host result is then the correctly rounded
 *         one, no flag can change (Inexact is already set), and softfloat
 *         itself returns this same value from its hardfloat path.
 *       - min/max/minnum/maxnum, compares, fcvt s->d, FRINT[NMPZAI]:
 *         no input NaN or denormal; these then never raise anything.
 *       - int->fp, fp->int, fcvt d->s, FRINTX: Inexact is computed exactly
 *         (significant-bit width, round trip, rounded != unrounded) and ORed
 *         in.  NaN, infinite (fp->int), denormal, out-of-range and possibly
 *         tiny results fall back.
 *     Every NaN or denormal input falls back, so NaN propagation, default
 *     NaN, the 3-NaN and inf*0+NaN rules, the Invalid sub-flags and
 *     input_denormal_used/IDC always come from softfloat itself.
 *     With -DAOT_PT_FPSR (tcg2c.py --pt-fpsr) the rounding arithmetic also
 *     runs when Inexact is still clear: one volatile asm block clears the
 *     host FPSR, executes the instruction and reads FPSR back.  Only IXC may
 *     be set (merged as float_flag_inexact, QEMU's FPSR_IXC mapping); IOC,
 *     DZC, OFC, UFC or IDC fall back, and so do the input classes above.
 *     Clearing inside the same block means that stale bits (QEMU's own C
 *     code runs FP instructions on this thread too) cannot leak in, and the
 *     compiler cannot move the operation across the FPSR accesses (the asm
 *     is volatile and produces the result, so it can neither be hoisted
 *     above the msr nor sunk below the mrs).  It is off by default: on
 *     Apple cores (M2 Max) an FPSR write plus read costs ~16 ns, more than
 *     softfloat's slow path (~9 ns for float64_add with Inexact clear).
 *     Half precision helpers are never passed through.
 *
 *  4. gvec helpers: desc must be a constant of the TB (tcg2c.py checks),
 *     maxsz 16 (AdvSIMD; SVE vector lengths fall back to the helper) and
 *     oprsz 8 or 16 (16 for 64-bit lanes and crypto).  The tail from oprsz
 *     to maxsz is zeroed like clear_tail(); simd_data (index, fixed-point
 *     shift, rounding mode) is decoded from the constant.  Every input is
 *     loaded before vd is written, so vd may alias vn, vm or va.  Lanes
 *     above oprsz never influence a decision or a flag.
 *
 *  5. Saturating Neon helpers (they set vfp.qc) stay helper calls.
 *
 *  6. Crypto, CRC, integer: the helpers' operand roles (AESE/AESD: vn state,
 *     vm round key, the xor commutes; AESMC/AESIMC: vm; SHA256H: vd abcd,
 *     vn efgh, vm wk; SHA256H2: vd efgh, vn abcd; SHA256SU0: vd, vm;
 *     SHA256SU1: vd, vn, vm); crc32 "bytes" is a TB constant (1, 2, 4, 8)
 *     and val above it is zero (translate-a64.c do_crc32); the accumulator
 *     is used as 32 bits, and crc32_64 (zlib) falls back when the 64-bit
 *     accumulator has bits above 31 because zlib's handling of those
 *     depends on its version; sdiv64/udiv64: x/0 = 0, INT64_MIN/-1 =
 *     INT64_MIN; mulsh/muluh: high half of the 128-bit product.
 */
#include <arm_neon.h>
#include <arm_acle.h>

#define AOT_INL static inline __attribute__((always_inline))

#ifdef AOT_PT_STATS
extern uint64_t aot_pt_cnt[][2] __attribute__((visibility("hidden")));
#define AOT_PT_HIT(i)  __atomic_fetch_add(&aot_pt_cnt[i][0], 1, __ATOMIC_RELAXED)
#define AOT_PT_MISS(i) __atomic_fetch_add(&aot_pt_cnt[i][1], 1, __ATOMIC_RELAXED)
#else
#define AOT_PT_HIT(i)  ((void)0)
#define AOT_PT_MISS(i) ((void)0)
#endif

extern int aot_pt_on __attribute__((visibility("hidden")));

/* host FPCR (rule 1); volatile so it is re-read after every helper call */
AOT_INL uint64_t aot_fpcr(void)
{
    uint64_t v;
    __asm__ __volatile__("mrs %0, fpcr" : "=r"(v));
    return v;
}

/* float_status bytes 3..10 and 10..17 for FPCR.{FZ,FIZ,DN,AH} = 0 */
#define AOT_FS_CFG3  0x0100010352010000ull
#define AOT_FS_CFG10 0x0000000040000001ull
#define AOT_FS_INEXACT 0x10             /* float_flag_inexact */

AOT_INL int aot_fs_cfg(const char *st)
{
    uint64_t a, b;
    memcpy(&a, st + 3, 8);
    memcpy(&b, st + 10, 8);
    return likely(((a ^ AOT_FS_CFG3) | (b ^ AOT_FS_CFG10) | aot_fpcr()) == 0 && aot_pt_on);
}
AOT_INL int aot_fs_rm(const char *st) { return *(const uint8_t *)(st + 2); }
AOT_INL int aot_fs_rne(const char *st) { return aot_fs_cfg(st) && aot_fs_rm(st) == 0; }
AOT_INL int aot_fs_ix(const char *st)
{
    uint16_t f;
    memcpy(&f, st, 2);
    return f & AOT_FS_INEXACT;
}
AOT_INL void aot_fs_set_ix(char *st)
{
    uint16_t f;
    memcpy(&f, st, 2);
    f |= AOT_FS_INEXACT;
    memcpy(st, &f, 2);
}

AOT_INL uint32_t aot_bf(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
AOT_INL float aot_fb(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
AOT_INL uint64_t aot_bd(double f) { uint64_t u; memcpy(&u, &f, 8); return u; }
AOT_INL double aot_db(uint64_t u) { double f; memcpy(&f, &u, 8); return f; }

/* Raw-bit classes.  zon: zero or normal.  nrm: normal.  ord: zero, normal
 * or infinite (not NaN, not denormal).  big: smallest normal < |x| < inf. */
#define AOT_A32(x) ((uint32_t)(x) & 0x7fffffffu)
#define AOT_A64(x) ((uint64_t)(x) & 0x7fffffffffffffffull)
AOT_INL int aot_zon32(uint32_t x) { uint32_t a = AOT_A32(x); return a == 0 || a - 0x00800000u < 0x7f000000u; }
AOT_INL int aot_nrm32(uint32_t x) { return AOT_A32(x) - 0x00800000u < 0x7f000000u; }
AOT_INL int aot_ord32(uint32_t x) { uint32_t a = AOT_A32(x); return a == 0 || a - 0x00800000u <= 0x7f000000u; }
AOT_INL int aot_big32(uint32_t x) { return AOT_A32(x) - 0x00800001u < 0x7effffffu; }
AOT_INL int aot_zon64(uint64_t x)
{
    uint64_t a = AOT_A64(x);
    return a == 0 || a - 0x0010000000000000ull < 0x7fe0000000000000ull;
}
AOT_INL int aot_nrm64(uint64_t x) { return AOT_A64(x) - 0x0010000000000000ull < 0x7fe0000000000000ull; }
AOT_INL int aot_ord64(uint64_t x)
{
    uint64_t a = AOT_A64(x);
    return a == 0 || a - 0x0010000000000000ull <= 0x7fe0000000000000ull;
}
AOT_INL int aot_big64(uint64_t x) { return AOT_A64(x) - 0x0010000000000001ull < 0x7fdfffffffffffffull; }

enum { AOT_ADD, AOT_SUB, AOT_MUL, AOT_DIV };

/* inputs allowed by QEMU's hardfloat for op; result acceptable */
#define AOT_PRE(W, op, a, b) \
    ((op) == AOT_DIV ? aot_zon##W(a) && aot_nrm##W(b) : aot_zon##W(a) && aot_zon##W(b))
#define AOT_EXACT0(W, op, a, b)                                         \
    ((op) == AOT_DIV ? AOT_A##W(a) == 0 :                               \
     (op) == AOT_MUL ? AOT_A##W(a) == 0 || AOT_A##W(b) == 0 :           \
     AOT_A##W(a) == 0 && AOT_A##W(b) == 0)

#ifdef AOT_PT_FPSR
/* FPSR cumulative bits other than IXC: IOC DZC OFC UFC IDC */
#define AOT_FPSR_BAD 0x8full
#define AOT_FPSR_IXC 0x10ull
#define AOT_FPSR_OP(insn, out, s, ...) \
    __asm__ __volatile__("msr fpsr, xzr\n\t" insn "\n\tmrs %1, fpsr" : "=&w"(out), "=r"(s) : __VA_ARGS__)
/* returns 1 when only IXC (or nothing) was raised, after merging it */
AOT_INL int aot_fpsr_merge(uint64_t s, char *st)
{
    if (unlikely(s & AOT_FPSR_BAD)) {
        return 0;
    }
    if (s & AOT_FPSR_IXC) {
        aot_fs_set_ix(st);
    }
    return 1;
}
#endif

/* ---------------------------------------------------- scalar arithmetic */

AOT_INL int aot_pt_ar32(uint32_t *r, uint32_t a, uint32_t b, char *st, int op)
{
    if (!aot_fs_rne(st) || !AOT_PRE(32, op, a, b)) {
        return 0;
    }
    float x = aot_fb(a), y = aot_fb(b), z;
    if (likely(aot_fs_ix(st))) {
        z = op == AOT_ADD ? x + y : op == AOT_SUB ? x - y : op == AOT_MUL ? x * y : x / y;
        uint32_t u = aot_bf(z);
        if (!aot_big32(u) && !AOT_EXACT0(32, op, a, b)) {
            return 0;
        }
        *r = u;
        return 1;
    }
#ifdef AOT_PT_FPSR
    uint64_t s;
    switch (op) {
    case AOT_ADD: AOT_FPSR_OP("fadd %s0, %s2, %s3", z, s, "w"(x), "w"(y)); break;
    case AOT_SUB: AOT_FPSR_OP("fsub %s0, %s2, %s3", z, s, "w"(x), "w"(y)); break;
    case AOT_MUL: AOT_FPSR_OP("fmul %s0, %s2, %s3", z, s, "w"(x), "w"(y)); break;
    default:      AOT_FPSR_OP("fdiv %s0, %s2, %s3", z, s, "w"(x), "w"(y)); break;
    }
    if (aot_fpsr_merge(s, st)) {
        *r = aot_bf(z);
        return 1;
    }
#endif
    return 0;
}

AOT_INL int aot_pt_ar64(uint64_t *r, uint64_t a, uint64_t b, char *st, int op)
{
    if (!aot_fs_rne(st) || !AOT_PRE(64, op, a, b)) {
        return 0;
    }
    double x = aot_db(a), y = aot_db(b), z;
    if (likely(aot_fs_ix(st))) {
        z = op == AOT_ADD ? x + y : op == AOT_SUB ? x - y : op == AOT_MUL ? x * y : x / y;
        uint64_t u = aot_bd(z);
        if (!aot_big64(u) && !AOT_EXACT0(64, op, a, b)) {
            return 0;
        }
        *r = u;
        return 1;
    }
#ifdef AOT_PT_FPSR
    uint64_t s;
    switch (op) {
    case AOT_ADD: AOT_FPSR_OP("fadd %d0, %d2, %d3", z, s, "w"(x), "w"(y)); break;
    case AOT_SUB: AOT_FPSR_OP("fsub %d0, %d2, %d3", z, s, "w"(x), "w"(y)); break;
    case AOT_MUL: AOT_FPSR_OP("fmul %d0, %d2, %d3", z, s, "w"(x), "w"(y)); break;
    default:      AOT_FPSR_OP("fdiv %d0, %d2, %d3", z, s, "w"(x), "w"(y)); break;
    }
    if (aot_fpsr_merge(s, st)) {
        *r = aot_bd(z);
        return 1;
    }
#endif
    return 0;
}

#define AOT_PT_AR(name, op)                                                       \
AOT_INL int aot_pt_vfp_##name##s(uint32_t *r, uint32_t a, uint32_t b, char *st)  \
{ return aot_pt_ar32(r, a, b, st, op); }                                          \
AOT_INL int aot_pt_vfp_##name##d(uint64_t *r, uint64_t a, uint64_t b, char *st)  \
{ return aot_pt_ar64(r, a, b, st, op); }
AOT_PT_AR(add, AOT_ADD)
AOT_PT_AR(sub, AOT_SUB)
AOT_PT_AR(mul, AOT_MUL)
AOT_PT_AR(div, AOT_DIV)

/* float*_muladd(a, b, c, 0) = a * b + c; FMADD Rd = Ra + Rn * Rm */
AOT_INL int aot_pt_vfp_muladds(uint32_t *r, uint32_t a, uint32_t b, uint32_t c, char *st)
{
    if (!aot_fs_rne(st) || !aot_zon32(a) || !aot_zon32(b) || !aot_zon32(c)) {
        return 0;
    }
    float x = aot_fb(a), y = aot_fb(b), w = aot_fb(c);
    if (likely(aot_fs_ix(st))) {
        uint32_t u = aot_bf(__builtin_fmaf(x, y, w));
        if (AOT_A32(a) && AOT_A32(b) && !aot_big32(u)) {
            return 0;
        }
        *r = u;
        return 1;
    }
#ifdef AOT_PT_FPSR
    float z;
    uint64_t s;
    AOT_FPSR_OP("fmadd %s0, %s2, %s3, %s4", z, s, "w"(x), "w"(y), "w"(w));
    if (aot_fpsr_merge(s, st)) {
        *r = aot_bf(z);
        return 1;
    }
#endif
    return 0;
}

AOT_INL int aot_pt_vfp_muladdd(uint64_t *r, uint64_t a, uint64_t b, uint64_t c, char *st)
{
    if (!aot_fs_rne(st) || !aot_zon64(a) || !aot_zon64(b) || !aot_zon64(c)) {
        return 0;
    }
    double x = aot_db(a), y = aot_db(b), w = aot_db(c);
    if (likely(aot_fs_ix(st))) {
        uint64_t u = aot_bd(__builtin_fma(x, y, w));
        if (AOT_A64(a) && AOT_A64(b) && !aot_big64(u)) {
            return 0;
        }
        *r = u;
        return 1;
    }
#ifdef AOT_PT_FPSR
    double z;
    uint64_t s;
    AOT_FPSR_OP("fmadd %d0, %d2, %d3, %d4", z, s, "w"(x), "w"(y), "w"(w));
    if (aot_fpsr_merge(s, st)) {
        *r = aot_bd(z);
        return 1;
    }
#endif
    return 0;
}

/* hardfloat sqrt: +0 or positive normal */
AOT_INL int aot_pt_vfp_sqrts(uint32_t *r, uint32_t a, char *st)
{
    if (!aot_fs_rne(st) || !aot_zon32(a) || (a >> 31)) {
        return 0;
    }
    float x = aot_fb(a);
    if (likely(aot_fs_ix(st))) {
        *r = aot_bf(__builtin_sqrtf(x));
        return 1;
    }
#ifdef AOT_PT_FPSR
    float z;
    uint64_t s;
    AOT_FPSR_OP("fsqrt %s0, %s2", z, s, "w"(x));
    if (aot_fpsr_merge(s, st)) {
        *r = aot_bf(z);
        return 1;
    }
#endif
    return 0;
}

AOT_INL int aot_pt_vfp_sqrtd(uint64_t *r, uint64_t a, char *st)
{
    if (!aot_fs_rne(st) || !aot_zon64(a) || (a >> 63)) {
        return 0;
    }
    double x = aot_db(a);
    if (likely(aot_fs_ix(st))) {
        *r = aot_bd(__builtin_sqrt(x));
        return 1;
    }
#ifdef AOT_PT_FPSR
    double z;
    uint64_t s;
    AOT_FPSR_OP("fsqrt %d0, %d2", z, s, "w"(x));
    if (aot_fpsr_merge(s, st)) {
        *r = aot_bd(z);
        return 1;
    }
#endif
    return 0;
}

/* FMIN/FMAX/FMINNM/FMAXNM never round and raise nothing without NaN or
 * denormal inputs (softfloat parts_minmax) */
#define AOT_PT_MINMAX(name, insn)                                                 \
AOT_INL int aot_pt_vfp_##name##s(uint32_t *r, uint32_t a, uint32_t b, char *st)  \
{                                                                                 \
    if (!aot_fs_cfg(st) || !aot_ord32(a) || !aot_ord32(b)) {                      \
        return 0;                                                                 \
    }                                                                             \
    float z;                                                                      \
    __asm__(insn " %s0, %s1, %s2" : "=w"(z) : "w"(aot_fb(a)), "w"(aot_fb(b)));    \
    *r = aot_bf(z);                                                               \
    return 1;                                                                     \
}                                                                                 \
AOT_INL int aot_pt_vfp_##name##d(uint64_t *r, uint64_t a, uint64_t b, char *st)  \
{                                                                                 \
    if (!aot_fs_cfg(st) || !aot_ord64(a) || !aot_ord64(b)) {                      \
        return 0;                                                                 \
    }                                                                             \
    double z;                                                                     \
    __asm__(insn " %d0, %d1, %d2" : "=w"(z) : "w"(aot_db(a)), "w"(aot_db(b)));    \
    *r = aot_bd(z);                                                               \
    return 1;                                                                     \
}
AOT_PT_MINMAX(min, "fmin")
AOT_PT_MINMAX(max, "fmax")
AOT_PT_MINMAX(minnum, "fminnm")
AOT_PT_MINMAX(maxnum, "fmaxnm")

/* vfp_cmp*_a64: NZCV in bits 31:28 (float_rel_to_flags); quiet and
 * signalling compares agree without NaN inputs */
AOT_INL uint64_t aot_nzcv(int lt, int eq)
{
    return eq ? 0x60000000u : lt ? 0x80000000u : 0x20000000u;
}
#define AOT_PT_CMP(name)                                                            \
AOT_INL int aot_pt_vfp_##name##s_a64(uint64_t *r, uint32_t a, uint32_t b, char *st) \
{                                                                                   \
    if (!aot_fs_cfg(st) || !aot_ord32(a) || !aot_ord32(b)) {                        \
        return 0;                                                                   \
    }                                                                               \
    *r = aot_nzcv(aot_fb(a) < aot_fb(b), aot_fb(a) == aot_fb(b));                   \
    return 1;                                                                       \
}                                                                                   \
AOT_INL int aot_pt_vfp_##name##d_a64(uint64_t *r, uint64_t a, uint64_t b, char *st) \
{                                                                                   \
    if (!aot_fs_cfg(st) || !aot_ord64(a) || !aot_ord64(b)) {                        \
        return 0;                                                                   \
    }                                                                               \
    *r = aot_nzcv(aot_db(a) < aot_db(b), aot_db(a) == aot_db(b));                   \
    return 1;                                                                       \
}
AOT_PT_CMP(cmp)
AOT_PT_CMP(cmpe)

/* ---------------------------------------------------------- conversions */

AOT_INL int aot_pt_vfp_fcvtds(uint64_t *r, uint32_t a, char *st)
{
    if (!aot_fs_cfg(st) || !aot_ord32(a)) {
        return 0;
    }
    *r = aot_bd((double)aot_fb(a));
    return 1;
}

AOT_INL int aot_pt_vfp_fcvtsd(uint32_t *r, uint64_t a, char *st)
{
    if (!aot_fs_rne(st) || !aot_zon64(a)) {
        return 0;
    }
    float z = (float)aot_db(a);
    uint32_t u = aot_bf(z);
    if (AOT_A64(a) && !aot_big32(u)) {
        return 0;                       /* overflow or possibly tiny */
    }
    if ((double)z != aot_db(a) && !aot_fs_ix(st)) {
        aot_fs_set_ix(st);
    }
    *r = u;
    return 1;
}

/* integer (sign- or zero-extended to 64 bits) to float/double, scaled by
 * 2^-shift; scaling a result >= 2^-64 is exact, so only the integer's
 * significant-bit width decides Inexact */
AOT_INL int aot_iwidth_ok(uint64_t v, int bits)
{
    return v == 0 || 64 - __builtin_clzll(v) - __builtin_ctzll(v) <= bits;
}
AOT_INL int aot_pt_i2f32(uint32_t *r, uint64_t x, int sgn, uint32_t shift, char *st)
{
    if (!aot_fs_rne(st) || shift > 64) {
        return 0;
    }
    float z = sgn ? (float)(int64_t)x : (float)x;
    if (shift) {
        z *= aot_fb((127 - shift) << 23);
    }
    if (!aot_iwidth_ok(sgn && (int64_t)x < 0 ? -x : x, 24) && !aot_fs_ix(st)) {
        aot_fs_set_ix(st);
    }
    *r = aot_bf(z);
    return 1;
}
AOT_INL int aot_pt_i2f64(uint64_t *r, uint64_t x, int sgn, uint32_t shift, char *st)
{
    if (!aot_fs_rne(st) || shift > 64) {
        return 0;
    }
    double z = sgn ? (double)(int64_t)x : (double)x;
    if (shift) {
        z *= aot_db((uint64_t)(1023 - shift) << 52);
    }
    if (!aot_iwidth_ok(sgn && (int64_t)x < 0 ? -x : x, 53) && !aot_fs_ix(st)) {
        aot_fs_set_ix(st);
    }
    *r = aot_bd(z);
    return 1;
}
#define AOT_PT_I2F(name, sgn, ext)                                                         \
AOT_INL int aot_pt_vfp_##name##tos(uint32_t *r, ext x, uint32_t shift, char *st)          \
{ return aot_pt_i2f32(r, sgn ? (uint64_t)(int64_t)(x) : (uint64_t)(x), sgn, shift, st); }  \
AOT_INL int aot_pt_vfp_##name##tod(uint64_t *r, ext x, uint32_t shift, char *st)          \
{ return aot_pt_i2f64(r, sgn ? (uint64_t)(int64_t)(x) : (uint64_t)(x), sgn, shift, st); }
AOT_PT_I2F(sl, 1, int32_t)
AOT_PT_I2F(ul, 0, uint32_t)
AOT_PT_I2F(sq, 1, int64_t)
AOT_PT_I2F(uq, 0, uint64_t)
/* AArch32 VCVT from integer (no shift) */
AOT_INL int aot_pt_vfp_sitos(uint32_t *r, int32_t x, char *st) { return aot_pt_i2f32(r, (uint64_t)(int64_t)x, 1, 0, st); }
AOT_INL int aot_pt_vfp_uitos(uint32_t *r, uint32_t x, char *st) { return aot_pt_i2f32(r, x, 0, 0, st); }
AOT_INL int aot_pt_vfp_sitod(uint64_t *r, int32_t x, char *st) { return aot_pt_i2f64(r, (uint64_t)(int64_t)x, 1, 0, st); }
AOT_INL int aot_pt_vfp_uitod(uint64_t *r, uint32_t x, char *st) { return aot_pt_i2f64(r, x, 0, 0, st); }

/* round to an integral value in mode rm (byte 2 encoding); -1 = invalid */
AOT_INL double aot_rnd64(double y, int rm)
{
    switch (rm) {
    case 0:  return __builtin_roundeven(y);
    case 1:  return __builtin_floor(y);
    case 2:  return __builtin_ceil(y);
    case 3:  return __builtin_trunc(y);
    default: return __builtin_round(y);
    }
}
AOT_INL float aot_rnd32(float y, int rm)
{
    switch (rm) {
    case 0:  return __builtin_roundevenf(y);
    case 1:  return __builtin_floorf(y);
    case 2:  return __builtin_ceilf(y);
    case 3:  return __builtin_truncf(y);
    default: return __builtin_roundf(y);
    }
}

/*
 * float/double (as an exact double x, zero or normal) times 2^shift,
 * rounded in mode rm, to a bits-wide integer.  Out of range (Invalid) falls
 * back; Inexact iff the rounded value differs.
 */
AOT_INL int aot_pt_f2i(uint64_t *r, double x, int rm, uint32_t shift, int sgn, int bits, char *st)
{
    if (rm > 4 || shift > 64) {
        return 0;
    }
    double y = shift ? x * aot_db((uint64_t)(1023 + shift) << 52) : x;
    double z = aot_rnd64(y, rm);
    double lim = aot_db((uint64_t)(1023 + bits - sgn) << 52);     /* 2^(bits-sgn) */
    if (sgn ? !(z >= -lim && z < lim) : !(z >= 0 && z < lim)) {
        return 0;
    }
    *r = sgn ? (uint64_t)(int64_t)z : (uint64_t)z;
    if (z != y && !aot_fs_ix(st)) {
        aot_fs_set_ix(st);
    }
    return 1;
}
/* vfp_to{sl,ul,sq,uq}{s,d}(x, shift, fpst): current rounding mode;
 * *_round_to_zero: RZ.  The result is the integer sign- or zero-extended to
 * 64 bits (vfp_tosld returns int32 in a uint64_t, like the helper). */
#define AOT_PT_F2I1(fn, p, W, cvt, rmx, sgn, bits, rt)                            \
AOT_INL int fn(rt *r, uint##W##_t a, uint32_t shift, char *st)                    \
{                                                                                 \
    uint64_t v;                                                                   \
    if (!aot_fs_cfg(st) || !aot_zon##W(a) ||                                      \
        !aot_pt_f2i(&v, cvt(a), rmx, shift, sgn, bits, st)) {                     \
        return 0;                                                                 \
    }                                                                             \
    *r = (rt)v;                                                                   \
    return 1;                                                                     \
}
#define AOT_F2D(a) ((double)aot_fb(a))
#define AOT_PT_F2I(name, sgn, bits, rts, rtd)                                                         \
AOT_PT_F2I1(aot_pt_vfp_to##name##s, s, 32, AOT_F2D, aot_fs_rm(st), sgn, bits, rts)                   \
AOT_PT_F2I1(aot_pt_vfp_to##name##d, d, 64, aot_db, aot_fs_rm(st), sgn, bits, rtd)                    \
AOT_PT_F2I1(aot_pt_vfp_to##name##s_round_to_zero, s, 32, AOT_F2D, 3, sgn, bits, rts)                 \
AOT_PT_F2I1(aot_pt_vfp_to##name##d_round_to_zero, d, 64, aot_db, 3, sgn, bits, rtd)
AOT_PT_F2I(sl, 1, 32, uint32_t, uint64_t)
AOT_PT_F2I(ul, 0, 32, uint32_t, uint64_t)
AOT_PT_F2I(sq, 1, 64, uint64_t, uint64_t)
AOT_PT_F2I(uq, 0, 64, uint64_t, uint64_t)
/* AArch32 VCVT to integer: vfp_to{si,ui}{s,d} (FPSCR mode) and *z (zero) */
#define AOT_PT_F2I32(name, sgn, rm)                                                     \
AOT_INL int aot_pt_vfp_to##name##s(uint32_t *r, uint32_t a, char *st)                  \
{                                                                                       \
    uint64_t v;                                                                         \
    if (!aot_fs_cfg(st) || !aot_zon32(a) ||                                             \
        !aot_pt_f2i(&v, (double)aot_fb(a), rm < 0 ? aot_fs_rm(st) : rm, 0, sgn, 32, st)) { \
        return 0;                                                                       \
    }                                                                                   \
    *r = (uint32_t)v;                                                                   \
    return 1;                                                                           \
}                                                                                       \
AOT_INL int aot_pt_vfp_to##name##d(uint32_t *r, uint64_t a, char *st)                  \
{                                                                                       \
    uint64_t v;                                                                         \
    if (!aot_fs_cfg(st) || !aot_zon64(a) ||                                             \
        !aot_pt_f2i(&v, aot_db(a), rm < 0 ? aot_fs_rm(st) : rm, 0, sgn, 32, st)) {      \
        return 0;                                                                       \
    }                                                                                   \
    *r = (uint32_t)v;                                                                   \
    return 1;                                                                           \
}
AOT_PT_F2I32(si, 1, -1)
AOT_PT_F2I32(ui, 0, -1)
AOT_PT_F2I32(siz, 1, 3)
AOT_PT_F2I32(uiz, 0, 3)

/* rint{s,d}: FRINT[NMPZAI], Inexact suppressed by the helper;
 * rint{s,d}_exact: FRINTX, Inexact when the value changes */
#define AOT_PT_RINT(sfx, exact)                                                     \
AOT_INL int aot_pt_rints##sfx(uint32_t *r, uint32_t a, char *st)                    \
{                                                                                   \
    if (!aot_fs_cfg(st) || !aot_ord32(a) || aot_fs_rm(st) > 4) {                    \
        return 0;                                                                   \
    }                                                                               \
    float z = aot_rnd32(aot_fb(a), aot_fs_rm(st));                                  \
    if (exact && z != aot_fb(a) && !aot_fs_ix(st)) {                                \
        aot_fs_set_ix(st);                                                          \
    }                                                                               \
    *r = aot_bf(z);                                                                 \
    return 1;                                                                       \
}                                                                                   \
AOT_INL int aot_pt_rintd##sfx(uint64_t *r, uint64_t a, char *st)                    \
{                                                                                   \
    if (!aot_fs_cfg(st) || !aot_ord64(a) || aot_fs_rm(st) > 4) {                    \
        return 0;                                                                   \
    }                                                                               \
    double z = aot_rnd64(aot_db(a), aot_fs_rm(st));                                 \
    if (exact && z != aot_db(a) && !aot_fs_ix(st)) {                                \
        aot_fs_set_ix(st);                                                          \
    }                                                                               \
    *r = aot_bd(z);                                                                 \
    return 1;                                                                       \
}
AOT_PT_RINT(, 0)
AOT_PT_RINT(_exact, 1)

/* set_rmode: exactly the helper (returns the old mode byte) */
AOT_INL uint32_t aot_pt_set_rmode(uint32_t rm, char *st)
{
    uint32_t old = *(uint8_t *)(st + 2);
    *(uint8_t *)(st + 2) = (uint8_t)rm;
    return old;
}

/* ------------------------------------------------------ gvec helpers */

typedef float  aot_f32v __attribute__((vector_size(16)));
typedef double aot_f64v __attribute__((vector_size(16)));

AOT_INL int aot_oprsz(uint32_t desc)
{
    uint32_t f = (desc >> 8) & 3;
    return f == 2 ? (int)(desc & 0xff) * 8 + 8 : (int)f * 8 + 8;
}
AOT_INL int32_t aot_sdata(uint32_t desc) { return (int32_t)desc >> 10; }

AOT_INL aot_v128 aot_ld16(const char *p)
{
    aot_v128 v;
    memcpy(&v, p, 16);
    return v;
}
/* store oprsz bytes and clear the tail up to maxsz == 16 */
AOT_INL void aot_st16(char *p, aot_v128 v, int oprsz)
{
    if (oprsz == 8) {
        v[1] = 0;
    }
    memcpy(p, &v, 16);
}
/* all lanes of mask set (lanes above oprsz are ignored) */
AOT_INL int aot_all32(aot_u32 m, int oprsz)
{
    if (oprsz == 8) {
        m |= (aot_u32){ 0, 0, ~0u, ~0u };
    }
    return vminvq_u32(m) == ~0u;
}
AOT_INL int aot_all64(aot_u64 m) { return (m[0] & m[1]) == ~0ull; }

/* lane classes, like the scalar ones */
AOT_INL aot_u32 aot_vzon32(aot_v128 v)
{
    aot_u32 a = (aot_u32)v & 0x7fffffffu;
    return (aot_u32)((a == 0) | (a - 0x00800000u < 0x7f000000u));
}
AOT_INL aot_u32 aot_vnrm32(aot_v128 v) { return (aot_u32)(((aot_u32)v & 0x7fffffffu) - 0x00800000u < 0x7f000000u); }
AOT_INL aot_u32 aot_vord32(aot_v128 v)
{
    aot_u32 a = (aot_u32)v & 0x7fffffffu;
    return (aot_u32)((a == 0) | (a - 0x00800000u <= 0x7f000000u));
}
AOT_INL aot_u32 aot_vbig32(aot_v128 v) { return (aot_u32)(((aot_u32)v & 0x7fffffffu) - 0x00800001u < 0x7effffffu); }
AOT_INL aot_u32 aot_vz32(aot_v128 v) { return (aot_u32)(((aot_u32)v & 0x7fffffffu) == 0); }
AOT_INL aot_u64 aot_vzon64(aot_v128 v)
{
    aot_u64 a = (aot_u64)v & 0x7fffffffffffffffull;
    return (aot_u64)((a == 0) | (a - 0x0010000000000000ull < 0x7fe0000000000000ull));
}
AOT_INL aot_u64 aot_vnrm64(aot_v128 v)
{
    return (aot_u64)(((aot_u64)v & 0x7fffffffffffffffull) - 0x0010000000000000ull < 0x7fe0000000000000ull);
}
AOT_INL aot_u64 aot_vord64(aot_v128 v)
{
    aot_u64 a = (aot_u64)v & 0x7fffffffffffffffull;
    return (aot_u64)((a == 0) | (a - 0x0010000000000000ull <= 0x7fe0000000000000ull));
}
AOT_INL aot_u64 aot_vbig64(aot_v128 v)
{
    return (aot_u64)(((aot_u64)v & 0x7fffffffffffffffull) - 0x0010000000000001ull < 0x7fdfffffffffffffull);
}
AOT_INL aot_u64 aot_vz64(aot_v128 v) { return (aot_u64)(((aot_u64)v & 0x7fffffffffffffffull) == 0); }

#define AOT_VPRE(W, op, n, m) \
    ((op) == AOT_DIV ? aot_vzon##W(n) & aot_vnrm##W(m) : aot_vzon##W(n) & aot_vzon##W(m))
#define AOT_VEXACT0(W, op, n, m) \
    ((op) == AOT_DIV ? aot_vz##W(n) : (op) == AOT_MUL ? aot_vz##W(n) | aot_vz##W(m) : aot_vz##W(n) & aot_vz##W(m))

/* d = n op m for 32-bit lanes; n, m already loaded (m may be a splat) */
AOT_INL int aot_gvec_ar32(char *d, aot_v128 vn, aot_v128 vm, char *st, int oprsz, int op)
{
    if (!aot_fs_rne(st) || !aot_all32(AOT_VPRE(32, op, vn, vm), oprsz)) {
        return 0;
    }
    aot_f32v x = (aot_f32v)vn, y = (aot_f32v)vm, z;
    if (likely(aot_fs_ix(st))) {
        z = op == AOT_ADD ? x + y : op == AOT_SUB ? x - y : op == AOT_MUL ? x * y : x / y;
        if (!aot_all32(aot_vbig32((aot_v128)z) | AOT_VEXACT0(32, op, vn, vm), oprsz)) {
            return 0;
        }
        aot_st16(d, (aot_v128)z, oprsz);
        return 1;
    }
#ifdef AOT_PT_FPSR
    uint64_t s;
#define AOT_V32OP(i) do { if (oprsz == 8) AOT_FPSR_OP(i " %0.2s, %2.2s, %3.2s", z, s, "w"(x), "w"(y)); \
                          else AOT_FPSR_OP(i " %0.4s, %2.4s, %3.4s", z, s, "w"(x), "w"(y)); } while (0)
    switch (op) {
    case AOT_ADD: AOT_V32OP("fadd"); break;
    case AOT_SUB: AOT_V32OP("fsub"); break;
    case AOT_MUL: AOT_V32OP("fmul"); break;
    default:      AOT_V32OP("fdiv"); break;
    }
#undef AOT_V32OP
    if (aot_fpsr_merge(s, st)) {
        aot_st16(d, (aot_v128)z, oprsz);
        return 1;
    }
#endif
    return 0;
}

AOT_INL int aot_gvec_ar64(char *d, aot_v128 vn, aot_v128 vm, char *st, int op)
{
    if (!aot_fs_rne(st) || !aot_all64(AOT_VPRE(64, op, vn, vm))) {
        return 0;
    }
    aot_f64v x = (aot_f64v)vn, y = (aot_f64v)vm, z;
    if (likely(aot_fs_ix(st))) {
        z = op == AOT_ADD ? x + y : op == AOT_SUB ? x - y : op == AOT_MUL ? x * y : x / y;
        if (!aot_all64(aot_vbig64((aot_v128)z) | AOT_VEXACT0(64, op, vn, vm))) {
            return 0;
        }
        aot_st16(d, (aot_v128)z, 16);
        return 1;
    }
#ifdef AOT_PT_FPSR
    uint64_t s;
    switch (op) {
    case AOT_ADD: AOT_FPSR_OP("fadd %0.2d, %2.2d, %3.2d", z, s, "w"(x), "w"(y)); break;
    case AOT_SUB: AOT_FPSR_OP("fsub %0.2d, %2.2d, %3.2d", z, s, "w"(x), "w"(y)); break;
    case AOT_MUL: AOT_FPSR_OP("fmul %0.2d, %2.2d, %3.2d", z, s, "w"(x), "w"(y)); break;
    default:      AOT_FPSR_OP("fdiv %0.2d, %2.2d, %3.2d", z, s, "w"(x), "w"(y)); break;
    }
    if (aot_fpsr_merge(s, st)) {
        aot_st16(d, (aot_v128)z, 16);
        return 1;
    }
#endif
    return 0;
}

#define AOT_PT_GAR(name, op)                                                                  \
AOT_INL int aot_pt_gvec_##name##_s(char *d, char *n, char *m, char *st, uint32_t desc)         \
{ return aot_gvec_ar32(d, aot_ld16(n), aot_ld16(m), st, aot_oprsz(desc), op); }               \
AOT_INL int aot_pt_gvec_##name##_d(char *d, char *n, char *m, char *st, uint32_t desc)         \
{ return aot_gvec_ar64(d, aot_ld16(n), aot_ld16(m), st, op); }
AOT_PT_GAR(fadd, AOT_ADD)
AOT_PT_GAR(fsub, AOT_SUB)
AOT_PT_GAR(fmul, AOT_MUL)
AOT_PT_GAR(fdiv, AOT_DIV)

/* FMUL (by element): d[i] = n[i] * m[idx], idx = simd_data */
AOT_INL int aot_pt_gvec_fmul_idx_s(char *d, char *n, char *m, char *st, uint32_t desc)
{
    aot_u32 vm = (aot_u32)aot_ld16(m);
    vm = (aot_u32){ 0 } + vm[aot_sdata(desc) & 3];
    return aot_gvec_ar32(d, aot_ld16(n), (aot_v128)vm, st, aot_oprsz(desc), AOT_MUL);
}
AOT_INL int aot_pt_gvec_fmul_idx_d(char *d, char *n, char *m, char *st, uint32_t desc)
{
    aot_u64 vm = (aot_u64)aot_ld16(m);
    vm = (aot_u64){ 0 } + vm[aot_sdata(desc) & 1];
    return aot_gvec_ar64(d, aot_ld16(n), (aot_v128)vm, st, AOT_MUL);
}

/* fused multiply-add lanes: d = fma(n, m, a) (n negated for fms) */
AOT_INL int aot_gvec_fma32(char *d, aot_v128 vn, aot_v128 vm, aot_v128 va, char *st, int oprsz)
{
    if (!aot_fs_rne(st) || !aot_all32(aot_vzon32(vn) & aot_vzon32(vm) & aot_vzon32(va), oprsz)) {
        return 0;
    }
    float32x4_t x = (float32x4_t)vn, y = (float32x4_t)vm, w = (float32x4_t)va, z;
    if (likely(aot_fs_ix(st))) {
        z = vfmaq_f32(w, x, y);
        if (!aot_all32(aot_vbig32((aot_v128)z) | aot_vz32(vn) | aot_vz32(vm), oprsz)) {
            return 0;
        }
        aot_st16(d, (aot_v128)z, oprsz);
        return 1;
    }
#ifdef AOT_PT_FPSR
    uint64_t s;
    if (oprsz == 8) {
        __asm__ __volatile__("mov %0.16b, %4.16b\n\tmsr fpsr, xzr\n\tfmla %0.2s, %2.2s, %3.2s\n\tmrs %1, fpsr"
                             : "=&w"(z), "=r"(s) : "w"(x), "w"(y), "w"(w));
    } else {
        __asm__ __volatile__("mov %0.16b, %4.16b\n\tmsr fpsr, xzr\n\tfmla %0.4s, %2.4s, %3.4s\n\tmrs %1, fpsr"
                             : "=&w"(z), "=r"(s) : "w"(x), "w"(y), "w"(w));
    }
    if (aot_fpsr_merge(s, st)) {
        aot_st16(d, (aot_v128)z, oprsz);
        return 1;
    }
#endif
    return 0;
}
AOT_INL int aot_gvec_fma64(char *d, aot_v128 vn, aot_v128 vm, aot_v128 va, char *st)
{
    if (!aot_fs_rne(st) || !aot_all64(aot_vzon64(vn) & aot_vzon64(vm) & aot_vzon64(va))) {
        return 0;
    }
    float64x2_t x = (float64x2_t)vn, y = (float64x2_t)vm, w = (float64x2_t)va, z;
    if (likely(aot_fs_ix(st))) {
        z = vfmaq_f64(w, x, y);
        if (!aot_all64(aot_vbig64((aot_v128)z) | aot_vz64(vn) | aot_vz64(vm))) {
            return 0;
        }
        aot_st16(d, (aot_v128)z, 16);
        return 1;
    }
#ifdef AOT_PT_FPSR
    uint64_t s;
    __asm__ __volatile__("mov %0.16b, %4.16b\n\tmsr fpsr, xzr\n\tfmla %0.2d, %2.2d, %3.2d\n\tmrs %1, fpsr"
                         : "=&w"(z), "=r"(s) : "w"(x), "w"(y), "w"(w));
    if (aot_fpsr_merge(s, st)) {
        aot_st16(d, (aot_v128)z, 16);
        return 1;
    }
#endif
    return 0;
}
#define AOT_NEG32 ((aot_v128){ 0x8000000080000000ull, 0x8000000080000000ull })
#define AOT_NEG64 ((aot_v128){ 0x8000000000000000ull, 0x8000000000000000ull })
/* gvec_vfma: d = fma(n, m, d); gvec_vfms: d = fma(-n, m, d) */
AOT_INL int aot_pt_gvec_vfma_s(char *d, char *n, char *m, char *st, uint32_t desc)
{ return aot_gvec_fma32(d, aot_ld16(n), aot_ld16(m), aot_ld16(d), st, aot_oprsz(desc)); }
AOT_INL int aot_pt_gvec_vfms_s(char *d, char *n, char *m, char *st, uint32_t desc)
{ return aot_gvec_fma32(d, aot_ld16(n) ^ AOT_NEG32, aot_ld16(m), aot_ld16(d), st, aot_oprsz(desc)); }
AOT_INL int aot_pt_gvec_vfma_d(char *d, char *n, char *m, char *st, uint32_t desc)
{ return aot_gvec_fma64(d, aot_ld16(n), aot_ld16(m), aot_ld16(d), st); }
AOT_INL int aot_pt_gvec_vfms_d(char *d, char *n, char *m, char *st, uint32_t desc)
{ return aot_gvec_fma64(d, aot_ld16(n) ^ AOT_NEG64, aot_ld16(m), aot_ld16(d), st); }
/* gvec_fmla_idx: d = fma(n, m[idx], a); gvec_fmls_idx: fma(-n, m[idx], a) */
AOT_INL int aot_pt_gvec_fmla_idx_s(char *d, char *n, char *m, char *a, char *st, uint32_t desc)
{
    aot_u32 vm = (aot_u32)aot_ld16(m);
    vm = (aot_u32){ 0 } + vm[aot_sdata(desc) & 3];
    return aot_gvec_fma32(d, aot_ld16(n), (aot_v128)vm, aot_ld16(a), st, aot_oprsz(desc));
}
AOT_INL int aot_pt_gvec_fmls_idx_s(char *d, char *n, char *m, char *a, char *st, uint32_t desc)
{
    aot_u32 vm = (aot_u32)aot_ld16(m);
    vm = (aot_u32){ 0 } + vm[aot_sdata(desc) & 3];
    return aot_gvec_fma32(d, aot_ld16(n) ^ AOT_NEG32, (aot_v128)vm, aot_ld16(a), st, aot_oprsz(desc));
}
AOT_INL int aot_pt_gvec_fmla_idx_d(char *d, char *n, char *m, char *a, char *st, uint32_t desc)
{
    aot_u64 vm = (aot_u64)aot_ld16(m);
    vm = (aot_u64){ 0 } + vm[aot_sdata(desc) & 1];
    return aot_gvec_fma64(d, aot_ld16(n), (aot_v128)vm, aot_ld16(a), st);
}
AOT_INL int aot_pt_gvec_fmls_idx_d(char *d, char *n, char *m, char *a, char *st, uint32_t desc)
{
    aot_u64 vm = (aot_u64)aot_ld16(m);
    vm = (aot_u64){ 0 } + vm[aot_sdata(desc) & 1];
    return aot_gvec_fma64(d, aot_ld16(n) ^ AOT_NEG64, (aot_v128)vm, aot_ld16(a), st);
}

/* min/max and compares: no NaN or denormal lane */
#define AOT_PT_GNOFLAG(name, f32, f64)                                                    \
AOT_INL int aot_pt_gvec_##name##_s(char *d, char *n, char *m, char *st, uint32_t desc)     \
{                                                                                         \
    aot_v128 vn = aot_ld16(n), vm = aot_ld16(m);                                          \
    int oprsz = aot_oprsz(desc);                                                          \
    if (!aot_fs_cfg(st) || !aot_all32(aot_vord32(vn) & aot_vord32(vm), oprsz)) {          \
        return 0;                                                                         \
    }                                                                                     \
    aot_st16(d, (aot_v128)f32((float32x4_t)vn, (float32x4_t)vm), oprsz);                  \
    return 1;                                                                             \
}                                                                                         \
AOT_INL int aot_pt_gvec_##name##_d(char *d, char *n, char *m, char *st, uint32_t desc)     \
{                                                                                         \
    aot_v128 vn = aot_ld16(n), vm = aot_ld16(m);                                          \
    if (!aot_fs_cfg(st) || !aot_all64(aot_vord64(vn) & aot_vord64(vm))) {                 \
        return 0;                                                                         \
    }                                                                                     \
    aot_st16(d, (aot_v128)f64((float64x2_t)vn, (float64x2_t)vm), 16);                     \
    return 1;                                                                             \
}
AOT_PT_GNOFLAG(fmin, vminq_f32, vminq_f64)
AOT_PT_GNOFLAG(fmax, vmaxq_f32, vmaxq_f64)
AOT_PT_GNOFLAG(fminnum, vminnmq_f32, vminnmq_f64)
AOT_PT_GNOFLAG(fmaxnum, vmaxnmq_f32, vmaxnmq_f64)
/* float*_ceq(n, m) = n == m; cge = n >= m; cgt = n > m (all-ones lanes) */
AOT_PT_GNOFLAG(fceq, vceqq_f32, vceqq_f64)
AOT_PT_GNOFLAG(fcge, vcgeq_f32, vcgeq_f64)
AOT_PT_GNOFLAG(fcgt, vcgtq_f32, vcgtq_f64)

/* compares with zero: FCMEQ/FCMGT/FCMGE/FCMLT/FCMLE #0 */
#define AOT_PT_GCMP0(name, f32, f64)                                                      \
AOT_INL int aot_pt_gvec_##name##_s(char *d, char *n, char *st, uint32_t desc)             \
{                                                                                         \
    aot_v128 vn = aot_ld16(n);                                                            \
    int oprsz = aot_oprsz(desc);                                                          \
    if (!aot_fs_cfg(st) || !aot_all32(aot_vord32(vn), oprsz)) {                           \
        return 0;                                                                         \
    }                                                                                     \
    aot_st16(d, (aot_v128)f32((float32x4_t)vn), oprsz);                                   \
    return 1;                                                                             \
}                                                                                         \
AOT_INL int aot_pt_gvec_##name##_d(char *d, char *n, char *st, uint32_t desc)             \
{                                                                                         \
    aot_v128 vn = aot_ld16(n);                                                            \
    if (!aot_fs_cfg(st) || !aot_all64(aot_vord64(vn))) {                                  \
        return 0;                                                                         \
    }                                                                                     \
    aot_st16(d, (aot_v128)f64((float64x2_t)vn), 16);                                      \
    return 1;                                                                             \
}
AOT_PT_GCMP0(fceq0, vceqzq_f32, vceqzq_f64)
AOT_PT_GCMP0(fcgt0, vcgtzq_f32, vcgtzq_f64)
AOT_PT_GCMP0(fcge0, vcgezq_f32, vcgezq_f64)
AOT_PT_GCMP0(fclt0, vcltzq_f32, vcltzq_f64)
AOT_PT_GCMP0(fcle0, vclezq_f32, vclezq_f64)

/* int32 lanes -> float, scaled by 2^-shift (shift = simd_data) */
AOT_INL int aot_gvec_i2f32(char *d, char *n, char *st, uint32_t desc, int sgn)
{
    int oprsz = aot_oprsz(desc), shift = aot_sdata(desc);
    if (!aot_fs_rne(st) || shift < 0 || shift > 32) {
        return 0;
    }
    aot_v128 vn = aot_ld16(n);
    float32x4_t z = sgn ? vcvtq_f32_s32((int32x4_t)vn) : vcvtq_f32_u32((uint32x4_t)vn);
    if (shift) {
        z = vmulq_n_f32(z, aot_fb((127 - shift) << 23));
    }
    /* exact iff the significant bits fit in 24: clz(v & -v) - clz(v) <= 23 */
    uint32x4_t v = sgn ? vreinterpretq_u32_s32(vabsq_s32((int32x4_t)vn)) : (uint32x4_t)vn;
    uint32x4_t lsb = vandq_u32(v, vreinterpretq_u32_s32(vnegq_s32(vreinterpretq_s32_u32(v))));
    aot_u32 ex = (aot_u32)((aot_u32)vclzq_u32(lsb) <= (aot_u32)vclzq_u32(v) + 23);
    if (!aot_all32(ex, oprsz) && !aot_fs_ix(st)) {
        aot_fs_set_ix(st);
    }
    aot_st16(d, (aot_v128)z, oprsz);
    return 1;
}
AOT_INL int aot_pt_gvec_vcvt_sf(char *d, char *n, char *st, uint32_t desc) { return aot_gvec_i2f32(d, n, st, desc, 1); }
AOT_INL int aot_pt_gvec_vcvt_uf(char *d, char *n, char *st, uint32_t desc) { return aot_gvec_i2f32(d, n, st, desc, 0); }

/* int64 lanes -> double (16-byte only) */
AOT_INL int aot_gvec_i2f64(char *d, char *n, char *st, uint32_t desc, int sgn)
{
    int shift = aot_sdata(desc);
    uint64_t r[2], x[2];
    if (aot_oprsz(desc) != 16 || shift < 0 || shift > 64 || !aot_fs_rne(st)) {
        return 0;
    }
    memcpy(x, n, 16);
    aot_pt_i2f64(&r[0], x[0], sgn, shift, st);      /* cannot fail now */
    aot_pt_i2f64(&r[1], x[1], sgn, shift, st);
    memcpy(d, r, 16);
    return 1;
}
AOT_INL int aot_pt_gvec_vcvt_sd(char *d, char *n, char *st, uint32_t desc) { return aot_gvec_i2f64(d, n, st, desc, 1); }
AOT_INL int aot_pt_gvec_vcvt_ud(char *d, char *n, char *st, uint32_t desc) { return aot_gvec_i2f64(d, n, st, desc, 0); }

/* float lanes -> int32 lanes: round(n * 2^shift) in mode rm */
AOT_INL int aot_gvec_f2i32(char *d, char *n, char *st, int oprsz, int rm, int shift, int sgn)
{
    if (!aot_fs_cfg(st) || rm < 0 || rm > 4 || shift < 0 || shift > 32) {
        return 0;
    }
    aot_v128 vn = aot_ld16(n);
    if (!aot_all32(aot_vzon32(vn), oprsz)) {
        return 0;
    }
    float32x4_t y = (float32x4_t)vn, z;
    if (shift) {
        y = vmulq_n_f32(y, aot_fb((127 + shift) << 23));
    }
    switch (rm) {
    case 0:  z = vrndnq_f32(y); break;
    case 1:  z = vrndmq_f32(y); break;
    case 2:  z = vrndpq_f32(y); break;
    case 3:  z = vrndq_f32(y); break;
    default: z = vrndaq_f32(y); break;
    }
    /* in range: signed -2^31 <= z < 2^31, unsigned 0 <= z < 2^32 */
    float lim = sgn ? 2147483648.0f : 4294967296.0f;
    aot_u32 ok = (aot_u32)(((aot_f32v)z < lim) & ((aot_f32v)z >= (sgn ? -lim : 0.0f)));
    if (!aot_all32(ok, oprsz)) {
        return 0;
    }
    aot_v128 r = sgn ? (aot_v128)vcvtq_s32_f32(z) : (aot_v128)vcvtq_u32_f32(z);
    if (!aot_all32((aot_u32)((aot_f32v)z == (aot_f32v)y), oprsz) && !aot_fs_ix(st)) {
        aot_fs_set_ix(st);
    }
    aot_st16(d, r, oprsz);
    return 1;
}
/* double lanes -> int64 lanes (16-byte only) */
AOT_INL int aot_gvec_f2i64(char *d, char *n, char *st, int oprsz, int rm, int shift, int sgn)
{
    uint64_t x[2], r[2];
    if (oprsz != 16 || !aot_fs_cfg(st)) {
        return 0;
    }
    memcpy(x, n, 16);
    if (!aot_zon64(x[0]) || !aot_zon64(x[1])) {
        return 0;
    }
    /* aot_pt_f2i only sets Inexact after its checks pass; a failure on
     * lane 1 after lane 0 set it would leave a flag behind, so check both
     * lanes first with a scratch status copy */
    char tmp[18];
    memcpy(tmp, st, 18);
    if (!aot_pt_f2i(&r[0], aot_db(x[0]), rm, shift, sgn, 64, tmp) ||
        !aot_pt_f2i(&r[1], aot_db(x[1]), rm, shift, sgn, 64, tmp)) {
        return 0;
    }
    memcpy(st, tmp, 2);
    memcpy(d, r, 16);
    return 1;
}
AOT_INL int aot_pt_gvec_vcvt_rz_fs(char *d, char *n, char *st, uint32_t desc)
{ return aot_gvec_f2i32(d, n, st, aot_oprsz(desc), 3, aot_sdata(desc), 1); }
AOT_INL int aot_pt_gvec_vcvt_rz_fu(char *d, char *n, char *st, uint32_t desc)
{ return aot_gvec_f2i32(d, n, st, aot_oprsz(desc), 3, aot_sdata(desc), 0); }
AOT_INL int aot_pt_gvec_vcvt_rm_ss(char *d, char *n, char *st, uint32_t desc)
{ return aot_gvec_f2i32(d, n, st, aot_oprsz(desc), aot_sdata(desc), 0, 1); }
AOT_INL int aot_pt_gvec_vcvt_rm_us(char *d, char *n, char *st, uint32_t desc)
{ return aot_gvec_f2i32(d, n, st, aot_oprsz(desc), aot_sdata(desc), 0, 0); }
AOT_INL int aot_pt_gvec_vcvt_rz_ds(char *d, char *n, char *st, uint32_t desc)
{ return aot_gvec_f2i64(d, n, st, aot_oprsz(desc), 3, aot_sdata(desc), 1); }
AOT_INL int aot_pt_gvec_vcvt_rz_du(char *d, char *n, char *st, uint32_t desc)
{ return aot_gvec_f2i64(d, n, st, aot_oprsz(desc), 3, aot_sdata(desc), 0); }
AOT_INL int aot_pt_gvec_vcvt_rm_sd(char *d, char *n, char *st, uint32_t desc)
{ return aot_gvec_f2i64(d, n, st, aot_oprsz(desc), aot_sdata(desc), 0, 1); }
AOT_INL int aot_pt_gvec_vcvt_rm_ud(char *d, char *n, char *st, uint32_t desc)
{ return aot_gvec_f2i64(d, n, st, aot_oprsz(desc), aot_sdata(desc), 0, 0); }

/* ---------------------------------------------- integer, crypto, CRC */

AOT_INL uint64_t aot_pt_muluh_i64(uint64_t a, uint64_t b) { return (uint64_t)(((__uint128_t)a * b) >> 64); }
AOT_INL uint64_t aot_pt_mulsh_i64(uint64_t a, uint64_t b)
{
    return (uint64_t)(((__int128_t)(int64_t)a * (int64_t)b) >> 64);
}
AOT_INL uint64_t aot_pt_udiv64(uint64_t a, uint64_t b) { return aot_divu64(a, b); }
AOT_INL uint64_t aot_pt_sdiv64(uint64_t a, uint64_t b) { return aot_div64(a, b); }
AOT_INL uint32_t aot_pt_rbit(uint32_t x) { return __builtin_bitreverse32(x); }
AOT_INL uint64_t aot_pt_rbit64(uint64_t x) { return __builtin_bitreverse64(x); }

AOT_INL uint64_t aot_pt_crc32c_64(uint64_t acc, uint64_t val, uint32_t bytes)
{
    switch (bytes) {
    case 1:  return __crc32cb((uint32_t)acc, (uint8_t)val);
    case 2:  return __crc32ch((uint32_t)acc, (uint16_t)val);
    case 4:  return __crc32cw((uint32_t)acc, (uint32_t)val);
    default: return __crc32cd((uint32_t)acc, val);
    }
}
AOT_INL int aot_pt_crc32_64(uint64_t *r, uint64_t acc, uint64_t val, uint32_t bytes)
{
    if (acc >> 32) {
        return 0;
    }
    switch (bytes) {
    case 1:  *r = __crc32b((uint32_t)acc, (uint8_t)val); break;
    case 2:  *r = __crc32h((uint32_t)acc, (uint16_t)val); break;
    case 4:  *r = __crc32w((uint32_t)acc, (uint32_t)val); break;
    default: *r = __crc32d((uint32_t)acc, val); break;
    }
    return 1;
}

/* AES/SHA-256 (desc: oprsz == maxsz == 16, checked by tcg2c) */
AOT_INL uint8x16_t aot_ldq8(const char *p) { uint8x16_t v; memcpy(&v, p, 16); return v; }
AOT_INL uint32x4_t aot_ldq32(const char *p) { uint32x4_t v; memcpy(&v, p, 16); return v; }
AOT_INL void aot_stq8(char *p, uint8x16_t v) { memcpy(p, &v, 16); }
AOT_INL void aot_stq32(char *p, uint32x4_t v) { memcpy(p, &v, 16); }
AOT_INL void aot_pt_crypto_aese(char *d, char *n, char *m, uint32_t desc) { aot_stq8(d, vaeseq_u8(aot_ldq8(n), aot_ldq8(m))); }
AOT_INL void aot_pt_crypto_aesd(char *d, char *n, char *m, uint32_t desc) { aot_stq8(d, vaesdq_u8(aot_ldq8(n), aot_ldq8(m))); }
AOT_INL void aot_pt_crypto_aesmc(char *d, char *m, uint32_t desc) { aot_stq8(d, vaesmcq_u8(aot_ldq8(m))); }
AOT_INL void aot_pt_crypto_aesimc(char *d, char *m, uint32_t desc) { aot_stq8(d, vaesimcq_u8(aot_ldq8(m))); }
AOT_INL void aot_pt_crypto_sha256h(char *d, char *n, char *m, uint32_t desc)
{ aot_stq32(d, vsha256hq_u32(aot_ldq32(d), aot_ldq32(n), aot_ldq32(m))); }
AOT_INL void aot_pt_crypto_sha256h2(char *d, char *n, char *m, uint32_t desc)
{ aot_stq32(d, vsha256h2q_u32(aot_ldq32(d), aot_ldq32(n), aot_ldq32(m))); }
AOT_INL void aot_pt_crypto_sha256su0(char *d, char *m, uint32_t desc)
{ aot_stq32(d, vsha256su0q_u32(aot_ldq32(d), aot_ldq32(m))); }
AOT_INL void aot_pt_crypto_sha256su1(char *d, char *n, char *m, uint32_t desc)
{ aot_stq32(d, vsha256su1q_u32(aot_ldq32(d), aot_ldq32(n), aot_ldq32(m))); }

/* pairwise integer ops: d = [pairs of n | pairs of m]; for oprsz 8 the
 * 128-bit op on [n.lo | m.lo] has the 64-bit result in its low half */
#define AOT_PT_PAIR(name, T, Q)                                               \
AOT_INL void aot_pt_gvec_##name(char *d, char *n, char *m, uint32_t desc)    \
{                                                                             \
    aot_v128 a = aot_ld16(n), b = aot_ld16(m), r;                             \
    if (aot_oprsz(desc) == 16) {                                              \
        r = (aot_v128)Q((T)a, (T)b);                                          \
    } else {                                                                  \
        aot_v128 c = { a[0], b[0] };                                          \
        r = (aot_v128)Q((T)c, (T)c);                                          \
        r[1] = 0;                                                             \
    }                                                                         \
    memcpy(d, &r, 16);                                                        \
}
AOT_PT_PAIR(addp_b, uint8x16_t, vpaddq_u8)
AOT_PT_PAIR(addp_h, uint16x8_t, vpaddq_u16)
AOT_PT_PAIR(addp_s, uint32x4_t, vpaddq_u32)
AOT_PT_PAIR(addp_d, uint64x2_t, vpaddq_u64)
AOT_PT_PAIR(smaxp_b, int8x16_t, vpmaxq_s8)
AOT_PT_PAIR(smaxp_h, int16x8_t, vpmaxq_s16)
AOT_PT_PAIR(smaxp_s, int32x4_t, vpmaxq_s32)
AOT_PT_PAIR(umaxp_b, uint8x16_t, vpmaxq_u8)
AOT_PT_PAIR(umaxp_h, uint16x8_t, vpmaxq_u16)
AOT_PT_PAIR(umaxp_s, uint32x4_t, vpmaxq_u32)
AOT_PT_PAIR(sminp_b, int8x16_t, vpminq_s8)
AOT_PT_PAIR(sminp_h, int16x8_t, vpminq_s16)
AOT_PT_PAIR(sminp_s, int32x4_t, vpminq_s32)
AOT_PT_PAIR(uminp_b, uint8x16_t, vpminq_u8)
AOT_PT_PAIR(uminp_h, uint16x8_t, vpminq_u16)
AOT_PT_PAIR(uminp_s, uint32x4_t, vpminq_u32)

/* bytewise unary: CNT, RBIT */
AOT_INL void aot_pt_gvec_cnt_b(char *d, char *n, uint32_t desc)
{
    aot_v128 r = (aot_v128)vcntq_u8((uint8x16_t)aot_ld16(n));
    aot_st16(d, r, aot_oprsz(desc));
}
AOT_INL void aot_pt_gvec_rbit_b(char *d, char *n, uint32_t desc)
{
    aot_v128 r = (aot_v128)vrbitq_u8((uint8x16_t)aot_ld16(n));
    aot_st16(d, r, aot_oprsz(desc));
}

/* Neon narrow/widen without saturation (neon_helper.c) */
AOT_INL uint64_t aot_pt_neon_narrow_u8(uint64_t x)
{
    return (x & 0xffu) | ((x >> 8) & 0xff00u) | ((x >> 16) & 0xff0000u) | ((x >> 24) & 0xff000000u);
}
AOT_INL uint64_t aot_pt_neon_narrow_u16(uint64_t x)
{
    return (x & 0xffffu) | ((x >> 16) & 0xffff0000u);
}
AOT_INL uint64_t aot_pt_neon_widen_u8(uint32_t x)
{
    return (uint64_t)(uint8_t)x | (uint64_t)(uint8_t)(x >> 8) << 16 |
           (uint64_t)(uint8_t)(x >> 16) << 32 | (uint64_t)(uint8_t)(x >> 24) << 48;
}
AOT_INL uint64_t aot_pt_neon_widen_u16(uint32_t x)
{
    return (uint64_t)(uint16_t)x | (uint64_t)(x >> 16) << 32;
}
AOT_INL uint32_t aot_clz16(uint32_t x) { return x ? __builtin_clz(x) - 16 : 16; }
AOT_INL uint32_t aot_pt_neon_clz_u16(uint32_t x)
{
    return aot_clz16(x & 0xffff) | aot_clz16(x >> 16) << 16;
}

#endif
