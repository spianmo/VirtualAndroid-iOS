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

static inline uint64_t aot_mask(unsigned len)
{
    return len >= 64 ? ~0ull : ((1ull << len) - 1);
}

#endif
