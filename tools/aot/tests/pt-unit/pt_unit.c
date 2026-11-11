/*
 * Host unit test of the same-ISA passthrough (docs/AOT.md, "Same-ISA
 * passthrough"; run.sh builds and runs it).
 *
 * For every helper of tcg2c.py's PASSTHROUGH table this calls the real QEMU
 * helper (objects of the macOS TCTI build of engine/qemu-aot, whose
 * target/arm and fpu sources are those of the iOS engine) and aot_pt_<helper>
 * from aot_rt.h on the same inputs and the same float_status, built with
 * QEMU's own setters (fs_setup.c): default and FPCR.AH behaviours, the
 * rounding modes 0-5 (round-to-integer asserts on the others), flush_to_zero, flush_inputs_to_zero, default_nan_mode and
 * random cumulative flags.  Inputs are random bit patterns, special values
 * and values constructed near the rounding, underflow, overflow and integer
 * range edges; gvec cases use oprsz 8 and 16, every simd_data value the
 * translator can encode and aliased vd/vn/vm/va.
 *
 * Whenever the passthrough accepts (returns 1, or is infallible) its result,
 * every vector register and all bytes of float_status must equal the
 * helper's.  When it declines (returns 0) nothing may have changed.  With a
 * non-zero host FPCR or aot_pt_on == 0 every FP passthrough must decline.
 *
 *   pt_unit [ITERATIONS-PER-HELPER [SEED [HELPER-SUBSTRING]]]
 *   pt_unit bench
 *
 * Prints one line per helper (inline / declined / failed) and exits 1 on any
 * failure.  Built with -ffp-contract=off -mcrc like the cache (run.sh).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "aot_rt.h"

int aot_pt_on = 1;

int pt_fs_size(void);
void pt_fs_make(void *p, unsigned cfg);

/* ------------------------------------------------------------------ cases */

typedef struct Case {
    uint64_t x[3];          /* scalar operands (bit patterns) */
    uint32_t sh;            /* shift / bytes / rounding mode operand */
    uint32_t desc;          /* gvec descriptor */
    uint64_t r;             /* scalar result */
    int d, n, m, a;         /* vector register indices (may alias) */
    uint8_t v[4][16] __attribute__((aligned(16)));
} Case;

typedef void reffn(Case *, char *);
typedef int ptfn(Case *, char *);

enum {
    K_F1, K_F2, K_F3,       /* FP operands of width esz */
    K_I2F,                  /* integer operand (iw bits) [+ shift] */
    K_F2I,                  /* FP operand [+ shift] to integer */
    K_RM,                   /* set_rmode */
    K_GF2, K_GF3, K_GF4,    /* gvec, FP lanes */
    K_GI2, K_GI3,           /* gvec / crypto, raw bytes */
    K_INT,                  /* integer helpers */
    K_CRC,
};
enum { D_NONE, D_IDX, D_SH, D_RM };     /* simd_data contents */

typedef struct Ent {
    const char *name;
    int kind, fallible, esz, iw, shmax, data, oprsz;  /* oprsz: bit 0 = 8, bit 1 = 16 */
    reffn *ref;
    ptfn *pt;
    uint64_t hit, dec, fail;
} Ent;

#define P(x) ((char *)(x))
#define VR(c, i) ((void *)(c)->v[(c)->i])

/* scalar FP: f(a[, b[, c]], fpst) */
#define F1(h, T)                                                                     \
    T helper_##h(T, void *);                                                          \
    static void r_##h(Case *c, char *st) { c->r = helper_##h((T)c->x[0], st); }        \
    static int p_##h(Case *c, char *st)                                               \
    { T o; if (!aot_pt_##h(&o, (T)c->x[0], st)) return 0; c->r = o; return 1; }
#define F2(h, T, RT)                                                                 \
    RT helper_##h(T, T, void *);                                                      \
    static void r_##h(Case *c, char *st) { c->r = helper_##h((T)c->x[0], (T)c->x[1], st); } \
    static int p_##h(Case *c, char *st)                                               \
    { RT o; if (!aot_pt_##h(&o, (T)c->x[0], (T)c->x[1], st)) return 0; c->r = o; return 1; }
#define F3(h, T)                                                                     \
    T helper_##h(T, T, T, void *);                                                    \
    static void r_##h(Case *c, char *st)                                              \
    { c->r = helper_##h((T)c->x[0], (T)c->x[1], (T)c->x[2], st); }                     \
    static int p_##h(Case *c, char *st)                                               \
    { T o; if (!aot_pt_##h(&o, (T)c->x[0], (T)c->x[1], (T)c->x[2], st)) return 0; c->r = o; return 1; }
/* conversions: RT f(AT x, uint32_t shift, fpst) and RT f(AT x, fpst) */
#define CV(h, RT, AT)                                                                \
    RT helper_##h(AT, uint32_t, void *);                                              \
    static void r_##h(Case *c, char *st) { c->r = helper_##h((AT)c->x[0], c->sh, st); } \
    static int p_##h(Case *c, char *st)                                               \
    { RT o; if (!aot_pt_##h(&o, (AT)c->x[0], c->sh, st)) return 0; c->r = o; return 1; }
#define CV0(h, RT, AT)                                                               \
    RT helper_##h(AT, void *);                                                        \
    static void r_##h(Case *c, char *st) { c->r = helper_##h((AT)c->x[0], st); }       \
    static int p_##h(Case *c, char *st)                                               \
    { RT o; if (!aot_pt_##h(&o, (AT)c->x[0], st)) return 0; c->r = o; return 1; }
/* gvec FP */
#define GF2(h)                                                                       \
    void helper_##h(void *, void *, void *, uint32_t);                                \
    static void r_##h(Case *c, char *st) { helper_##h(VR(c, d), VR(c, n), st, c->desc); } \
    static int p_##h(Case *c, char *st) { return aot_pt_##h(P(VR(c, d)), P(VR(c, n)), st, c->desc); }
#define GF3(h)                                                                       \
    void helper_##h(void *, void *, void *, void *, uint32_t);                        \
    static void r_##h(Case *c, char *st)                                              \
    { helper_##h(VR(c, d), VR(c, n), VR(c, m), st, c->desc); }                         \
    static int p_##h(Case *c, char *st)                                               \
    { return aot_pt_##h(P(VR(c, d)), P(VR(c, n)), P(VR(c, m)), st, c->desc); }
#define GF4(h)                                                                       \
    void helper_##h(void *, void *, void *, void *, void *, uint32_t);                \
    static void r_##h(Case *c, char *st)                                              \
    { helper_##h(VR(c, d), VR(c, n), VR(c, m), VR(c, a), st, c->desc); }               \
    static int p_##h(Case *c, char *st)                                               \
    { return aot_pt_##h(P(VR(c, d)), P(VR(c, n)), P(VR(c, m)), P(VR(c, a)), st, c->desc); }
/* gvec / crypto without float_status (infallible) */
#define GI2(h)                                                                       \
    void helper_##h(void *, void *, uint32_t);                                        \
    static void r_##h(Case *c, char *st) { helper_##h(VR(c, d), VR(c, n), c->desc); }  \
    static int p_##h(Case *c, char *st) { aot_pt_##h(P(VR(c, d)), P(VR(c, n)), c->desc); return 1; }
#define GI3(h)                                                                       \
    void helper_##h(void *, void *, void *, uint32_t);                                \
    static void r_##h(Case *c, char *st) { helper_##h(VR(c, d), VR(c, n), VR(c, m), c->desc); } \
    static int p_##h(Case *c, char *st)                                               \
    { aot_pt_##h(P(VR(c, d)), P(VR(c, n)), P(VR(c, m)), c->desc); return 1; }
/* integer */
#define I1(h, RT, AT)                                                                \
    RT helper_##h(AT);                                                                \
    static void r_##h(Case *c, char *st) { c->r = helper_##h((AT)c->x[0]); }           \
    static int p_##h(Case *c, char *st) { c->r = (RT)aot_pt_##h((AT)c->x[0]); return 1; }
#define I2(h)                                                                        \
    uint64_t helper_##h(uint64_t, uint64_t);                                          \
    static void r_##h(Case *c, char *st) { c->r = helper_##h(c->x[0], c->x[1]); }      \
    static int p_##h(Case *c, char *st) { c->r = aot_pt_##h(c->x[0], c->x[1]); return 1; }

#define FBIN(op) F2(vfp_##op##s, uint32_t, uint32_t) F2(vfp_##op##d, uint64_t, uint64_t)
FBIN(add) FBIN(sub) FBIN(mul) FBIN(div) FBIN(min) FBIN(max) FBIN(minnum) FBIN(maxnum)
F2(vfp_cmps_a64, uint32_t, uint64_t) F2(vfp_cmpes_a64, uint32_t, uint64_t)
F2(vfp_cmpd_a64, uint64_t, uint64_t) F2(vfp_cmped_a64, uint64_t, uint64_t)
F3(vfp_muladds, uint32_t) F3(vfp_muladdd, uint64_t)
F1(vfp_sqrts, uint32_t) F1(vfp_sqrtd, uint64_t)
F1(rints, uint32_t) F1(rintd, uint64_t) F1(rints_exact, uint32_t) F1(rintd_exact, uint64_t)
CV0(vfp_fcvtds, uint64_t, uint32_t) CV0(vfp_fcvtsd, uint32_t, uint64_t)
/* int -> FP */
CV(vfp_sltos, uint32_t, uint32_t) CV(vfp_ultos, uint32_t, uint32_t)
CV(vfp_sqtos, uint32_t, uint64_t) CV(vfp_uqtos, uint32_t, uint64_t)
CV(vfp_sltod, uint64_t, uint64_t) CV(vfp_ultod, uint64_t, uint64_t)
CV(vfp_sqtod, uint64_t, uint64_t) CV(vfp_uqtod, uint64_t, uint64_t)
CV0(vfp_sitos, uint32_t, uint32_t) CV0(vfp_uitos, uint32_t, uint32_t)
CV0(vfp_sitod, uint64_t, uint32_t) CV0(vfp_uitod, uint64_t, uint32_t)
/* FP -> int */
CV(vfp_tosls, uint32_t, uint32_t) CV(vfp_touls, uint32_t, uint32_t)
CV(vfp_tosqs, uint64_t, uint32_t) CV(vfp_touqs, uint64_t, uint32_t)
CV(vfp_tosls_round_to_zero, uint32_t, uint32_t) CV(vfp_touls_round_to_zero, uint32_t, uint32_t)
CV(vfp_tosld, uint64_t, uint64_t) CV(vfp_tould, uint64_t, uint64_t)
CV(vfp_tosqd, uint64_t, uint64_t) CV(vfp_touqd, uint64_t, uint64_t)
CV(vfp_tosld_round_to_zero, uint64_t, uint64_t) CV(vfp_tould_round_to_zero, uint64_t, uint64_t)
CV(vfp_tosqd_round_to_zero, uint64_t, uint64_t) CV(vfp_touqd_round_to_zero, uint64_t, uint64_t)
CV0(vfp_tosis, uint32_t, uint32_t) CV0(vfp_touis, uint32_t, uint32_t)
CV0(vfp_tosizs, uint32_t, uint32_t) CV0(vfp_touizs, uint32_t, uint32_t)
CV0(vfp_tosid, uint32_t, uint64_t) CV0(vfp_touid, uint32_t, uint64_t)
CV0(vfp_tosizd, uint32_t, uint64_t) CV0(vfp_touizd, uint32_t, uint64_t)
/* set_rmode */
uint32_t helper_set_rmode(uint32_t, void *);
static void r_set_rmode(Case *c, char *st) { c->r = helper_set_rmode((uint32_t)c->x[0], st); }
static int p_set_rmode(Case *c, char *st) { c->r = aot_pt_set_rmode((uint32_t)c->x[0], st); return 1; }
/* gvec FP */
#define GSD3(op) GF3(gvec_##op##_s) GF3(gvec_##op##_d)
GSD3(fadd) GSD3(fsub) GSD3(fmul) GSD3(fdiv) GSD3(fmin) GSD3(fmax) GSD3(fminnum) GSD3(fmaxnum)
GSD3(fceq) GSD3(fcge) GSD3(fcgt) GSD3(fmul_idx) GSD3(vfma) GSD3(vfms)
#define GSD2(op) GF2(gvec_##op##_s) GF2(gvec_##op##_d)
GSD2(fceq0) GSD2(fcgt0) GSD2(fcge0) GSD2(fclt0) GSD2(fcle0)
GF4(gvec_fmla_idx_s) GF4(gvec_fmla_idx_d) GF4(gvec_fmls_idx_s) GF4(gvec_fmls_idx_d)
GF2(gvec_vcvt_sf) GF2(gvec_vcvt_uf) GF2(gvec_vcvt_sd) GF2(gvec_vcvt_ud)
GF2(gvec_vcvt_rz_fs) GF2(gvec_vcvt_rz_fu) GF2(gvec_vcvt_rm_ss) GF2(gvec_vcvt_rm_us)
GF2(gvec_vcvt_rz_ds) GF2(gvec_vcvt_rz_du) GF2(gvec_vcvt_rm_sd) GF2(gvec_vcvt_rm_ud)
/* integer, crypto, CRC */
I2(muluh_i64) I2(mulsh_i64) I2(udiv64) I2(sdiv64)
I1(rbit, uint32_t, uint32_t) I1(rbit64, uint64_t, uint64_t)
I1(neon_narrow_u8, uint64_t, uint64_t) I1(neon_narrow_u16, uint64_t, uint64_t)
I1(neon_widen_u8, uint64_t, uint32_t) I1(neon_widen_u16, uint64_t, uint32_t)
I1(neon_clz_u16, uint32_t, uint32_t)
uint64_t helper_crc32_64(uint64_t, uint64_t, uint32_t);
uint64_t helper_crc32c_64(uint64_t, uint64_t, uint32_t);
static void r_crc32_64(Case *c, char *st) { c->r = helper_crc32_64(c->x[0], c->x[1], c->sh); }
static int p_crc32_64(Case *c, char *st)
{ uint64_t o; if (!aot_pt_crc32_64(&o, c->x[0], c->x[1], c->sh)) return 0; c->r = o; return 1; }
static void r_crc32c_64(Case *c, char *st) { c->r = helper_crc32c_64(c->x[0], c->x[1], c->sh); }
static int p_crc32c_64(Case *c, char *st) { c->r = aot_pt_crc32c_64(c->x[0], c->x[1], c->sh); return 1; }
GI3(crypto_aese) GI3(crypto_aesd) GI2(crypto_aesmc) GI2(crypto_aesimc)
GI3(crypto_sha256h) GI3(crypto_sha256h2) GI2(crypto_sha256su0) GI3(crypto_sha256su1)
#define PAIR(op) GI3(gvec_##op##_b) GI3(gvec_##op##_h) GI3(gvec_##op##_s)
PAIR(addp) PAIR(smaxp) PAIR(umaxp) PAIR(sminp) PAIR(uminp)
GI3(gvec_addp_d) GI2(gvec_cnt_b) GI2(gvec_rbit_b)

#define E(h, kind, fal, esz, iw, shmax, data, oprsz) \
    { #h, kind, fal, esz, iw, shmax, data, oprsz, r_##h, p_##h, 0, 0, 0 },
#define EF1(h, esz) E(h, K_F1, 1, esz, 0, 0, D_NONE, 0)
#define EF2(h, esz) E(h, K_F2, 1, esz, 0, 0, D_NONE, 0)
#define EBIN(op) EF2(vfp_##op##s, 32) EF2(vfp_##op##d, 64)
#define EI2F(h, iw, sh, esz) E(h, K_I2F, 1, esz, iw, sh, D_NONE, 0)
#define EF2I(h, esz, sh) E(h, K_F2I, 1, esz, 0, sh, D_NONE, 0)
#define EG3(op, data) E(gvec_##op##_s, K_GF3, 1, 32, 0, 0, data, 3) E(gvec_##op##_d, K_GF3, 1, 64, 0, 0, data, 2)
#define EG2(op) E(gvec_##op##_s, K_GF2, 1, 32, 0, 0, D_NONE, 3) E(gvec_##op##_d, K_GF2, 1, 64, 0, 0, D_NONE, 2)
#define EGCV(h, esz, data, shmax, opr) E(h, K_GF2, 1, esz, 0, shmax, data, opr)
#define EGI3(h, opr) E(h, K_GI3, 0, 0, 0, 0, D_NONE, opr)
#define EGI2(h, opr) E(h, K_GI2, 0, 0, 0, 0, D_NONE, opr)
#define EPAIR(op) EGI3(gvec_##op##_b, 3) EGI3(gvec_##op##_h, 3) EGI3(gvec_##op##_s, 3)

static Ent ents[] = {
    EBIN(add) EBIN(sub) EBIN(mul) EBIN(div) EBIN(min) EBIN(max) EBIN(minnum) EBIN(maxnum)
    EF2(vfp_cmps_a64, 32) EF2(vfp_cmpes_a64, 32) EF2(vfp_cmpd_a64, 64) EF2(vfp_cmped_a64, 64)
    E(vfp_muladds, K_F3, 1, 32, 0, 0, D_NONE, 0) E(vfp_muladdd, K_F3, 1, 64, 0, 0, D_NONE, 0)
    EF1(vfp_sqrts, 32) EF1(vfp_sqrtd, 64)
    EF1(rints, 32) EF1(rintd, 64) EF1(rints_exact, 32) EF1(rintd_exact, 64)
    EF1(vfp_fcvtds, 32) EF1(vfp_fcvtsd, 64)
    EI2F(vfp_sltos, 32, 32, 32) EI2F(vfp_ultos, -32, 32, 32) EI2F(vfp_sqtos, 64, 64, 32)
    EI2F(vfp_uqtos, -64, 64, 32) EI2F(vfp_sltod, 32, 32, 64) EI2F(vfp_ultod, -32, 32, 64)
    EI2F(vfp_sqtod, 64, 64, 64) EI2F(vfp_uqtod, -64, 64, 64)
    EI2F(vfp_sitos, 32, 0, 32) EI2F(vfp_uitos, -32, 0, 32) EI2F(vfp_sitod, 32, 0, 64)
    EI2F(vfp_uitod, -32, 0, 64)
    EF2I(vfp_tosls, 32, 32) EF2I(vfp_touls, 32, 32) EF2I(vfp_tosqs, 32, 64) EF2I(vfp_touqs, 32, 64)
    EF2I(vfp_tosls_round_to_zero, 32, 32) EF2I(vfp_touls_round_to_zero, 32, 32)
    EF2I(vfp_tosld, 64, 32) EF2I(vfp_tould, 64, 32) EF2I(vfp_tosqd, 64, 64) EF2I(vfp_touqd, 64, 64)
    EF2I(vfp_tosld_round_to_zero, 64, 32) EF2I(vfp_tould_round_to_zero, 64, 32)
    EF2I(vfp_tosqd_round_to_zero, 64, 64) EF2I(vfp_touqd_round_to_zero, 64, 64)
    EF2I(vfp_tosis, 32, 0) EF2I(vfp_touis, 32, 0) EF2I(vfp_tosizs, 32, 0) EF2I(vfp_touizs, 32, 0)
    EF2I(vfp_tosid, 64, 0) EF2I(vfp_touid, 64, 0) EF2I(vfp_tosizd, 64, 0) EF2I(vfp_touizd, 64, 0)
    E(set_rmode, K_RM, 0, 0, 0, 0, D_NONE, 0)
    EG3(fadd, D_NONE) EG3(fsub, D_NONE) EG3(fmul, D_NONE) EG3(fdiv, D_NONE)
    EG3(fmin, D_NONE) EG3(fmax, D_NONE) EG3(fminnum, D_NONE) EG3(fmaxnum, D_NONE)
    EG3(fceq, D_NONE) EG3(fcge, D_NONE) EG3(fcgt, D_NONE) EG3(fmul_idx, D_IDX)
    EG3(vfma, D_NONE) EG3(vfms, D_NONE)
    EG2(fceq0) EG2(fcgt0) EG2(fcge0) EG2(fclt0) EG2(fcle0)
    E(gvec_fmla_idx_s, K_GF4, 1, 32, 0, 0, D_IDX, 3) E(gvec_fmla_idx_d, K_GF4, 1, 64, 0, 0, D_IDX, 2)
    E(gvec_fmls_idx_s, K_GF4, 1, 32, 0, 0, D_IDX, 3) E(gvec_fmls_idx_d, K_GF4, 1, 64, 0, 0, D_IDX, 2)
    EGCV(gvec_vcvt_sf, 32, D_SH, 32, 3) EGCV(gvec_vcvt_uf, 32, D_SH, 32, 3)
    EGCV(gvec_vcvt_sd, 64, D_SH, 64, 2) EGCV(gvec_vcvt_ud, 64, D_SH, 64, 2)
    EGCV(gvec_vcvt_rz_fs, 32, D_SH, 32, 3) EGCV(gvec_vcvt_rz_fu, 32, D_SH, 32, 3)
    EGCV(gvec_vcvt_rm_ss, 32, D_RM, 0, 3) EGCV(gvec_vcvt_rm_us, 32, D_RM, 0, 3)
    EGCV(gvec_vcvt_rz_ds, 64, D_SH, 64, 2) EGCV(gvec_vcvt_rz_du, 64, D_SH, 64, 2)
    EGCV(gvec_vcvt_rm_sd, 64, D_RM, 0, 2) EGCV(gvec_vcvt_rm_ud, 64, D_RM, 0, 2)
    E(muluh_i64, K_INT, 0, 0, 64, 0, D_NONE, 0) E(mulsh_i64, K_INT, 0, 0, 64, 0, D_NONE, 0)
    E(udiv64, K_INT, 0, 0, 64, 0, D_NONE, 0) E(sdiv64, K_INT, 0, 0, 64, 0, D_NONE, 0)
    E(rbit, K_INT, 0, 0, 32, 0, D_NONE, 0) E(rbit64, K_INT, 0, 0, 64, 0, D_NONE, 0)
    E(neon_narrow_u8, K_INT, 0, 0, 64, 0, D_NONE, 0) E(neon_narrow_u16, K_INT, 0, 0, 64, 0, D_NONE, 0)
    E(neon_widen_u8, K_INT, 0, 0, 32, 0, D_NONE, 0) E(neon_widen_u16, K_INT, 0, 0, 32, 0, D_NONE, 0)
    E(neon_clz_u16, K_INT, 0, 0, 32, 0, D_NONE, 0)
    E(crc32_64, K_CRC, 1, 0, 0, 0, D_NONE, 0) E(crc32c_64, K_CRC, 0, 0, 0, 0, D_NONE, 0)
    EGI3(crypto_aese, 2) EGI3(crypto_aesd, 2) EGI2(crypto_aesmc, 2) EGI2(crypto_aesimc, 2)
    EGI3(crypto_sha256h, 2) EGI3(crypto_sha256h2, 2) EGI2(crypto_sha256su0, 2)
    EGI3(crypto_sha256su1, 2)
    EPAIR(addp) EPAIR(smaxp) EPAIR(umaxp) EPAIR(sminp) EPAIR(uminp)
    EGI3(gvec_addp_d, 2) EGI2(gvec_cnt_b, 3) EGI2(gvec_rbit_b, 3)
};
#define NENTS (int)(sizeof(ents) / sizeof(ents[0]))

/* ------------------------------------------------------------- values */

static uint64_t rs = 0x9e3779b97f4a7c15ull;
static uint64_t rnd(void)
{
    rs ^= rs << 13;
    rs ^= rs >> 7;
    rs ^= rs << 17;
    return rs * 0x2545f4914f6cdd1dull;
}
static unsigned rn(unsigned n) { return (unsigned)(rnd() % n); }

static const uint32_t F32S[] = {
    0x00000000, 0x80000000, 0x3f800000, 0xbf800000, 0x3f800001, 0x3fc00000, 0x3f000000, 0xbf000000,
    0x7f7fffff, 0xff7fffff, 0x00800000, 0x80800000, 0x00800001, 0x007fffff, 0x00000001, 0x80000001,
    0x7f800000, 0xff800000, 0x7fc00000, 0x7fc12345, 0xffc00001, 0x7f800001, 0x7fa00000, 0xffbfffff,
    0x4b000000, 0x4b000001, 0x4f000000, 0xcf000000, 0x4f800000, 0x5f000000, 0x5f800000, 0xdf000000,
    0x4effffff, 0xcf000001, 0x4f7fffff, 0x5effffff, 0x5f7fffff, 0x40200000, 0xc0200000, 0x3effffff,
    0x00400000, 0x80400000, 0x00ffffff, 0x01000000, 0x7f000000, 0x7effffff, 0x33800000, 0x34000000,
};
static const uint64_t F64S[] = {
    0x0000000000000000, 0x8000000000000000, 0x3ff0000000000000, 0xbff0000000000000,
    0x3ff0000000000001, 0x3ff8000000000000, 0x3fe0000000000000, 0xbfe0000000000000,
    0x7fefffffffffffff, 0xffefffffffffffff, 0x0010000000000000, 0x8010000000000000,
    0x0010000000000001, 0x000fffffffffffff, 0x0000000000000001, 0x8000000000000001,
    0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000, 0x7ff8000000012345,
    0xfff8000000000001, 0x7ff0000000000001, 0x7ff4000000000000, 0xfff7ffffffffffff,
    0x4330000000000000, 0x4330000000000001, 0x41e0000000000000, 0xc1e0000000000000,
    0x41f0000000000000, 0x43e0000000000000, 0x43f0000000000000, 0xc3e0000000000000,
    0x41dfffffffc00000, 0x41dfffffffe00000, 0xc1e0000000100000, 0xc1e00000001fffff,
    0x41efffffffe00000, 0x41efffffffffffff, 0x43dfffffffffffff, 0x43efffffffffffff,
    0x47efffffe0000000, 0x47effffff0000000, 0x47efffffefffffff, 0x3810000000000000,
    0x380fffffffffffff, 0x36a0000000000000, 0x36a0000000000001, 0x3800000000000000,
    0x0008000000000000, 0x7fe0000000000000, 0x4004000000000000, 0xc004000000000000,
};
static const uint64_t I64S[] = {
    0, 1, ~0ull, 2, ~1ull, 3, 7, 0x7fffffff, 0x80000000, 0xffffffff, 0x100000000ull,
    0xffffff, 0x1000000, 0x1000001, 0x1ffffff, 0xff800000, 0x7fffff80, 0x7fffffc0,
    0x1fffffffffffff, 0x20000000000000, 0x20000000000001, 0x7fffffffffffffffull,
    0x8000000000000000ull, 0x8000000000000001ull, 0xfffffffffffffc00ull, 0x7ffffffffffffc00ull,
    0x123456789abcdef0ull, 0xfedcba9876543210ull, 0xffffffff80000000ull, 0xffffffff7fffffffull,
};
#define NF32S (sizeof(F32S) / sizeof(F32S[0]))
#define NF64S (sizeof(F64S) / sizeof(F64S[0]))
#define NI64S (sizeof(I64S) / sizeof(I64S[0]))

/* exponent field "near" an interesting point, mantissa with structure */
static uint64_t mant(int mbits)
{
    uint64_t all = (1ull << mbits) - 1, r = rnd() & all;
    switch (rn(10)) {
    case 0: return 0;
    case 1: return 1;
    case 2: return all;
    case 3: return all - 1;
    case 4: return 1ull << (mbits - 1);
    case 5: return (1ull << (mbits - 1)) + 1;
    case 6: return r & ~((1ull << rn(mbits)) - 1);     /* few significant bits */
    case 7: return r | ((1ull << rn(mbits)) - 1);
    default: return r;
    }
}
static uint64_t gen_fp(int esz, int center)
{
    int ebits = esz == 32 ? 8 : 11, mbits = esz == 32 ? 23 : 52;
    int emax = (1 << ebits) - 1, bias = emax >> 1;
    switch (rn(10)) {
    case 0:
    case 1:
        return esz == 32 ? F32S[rn(NF32S)] : F64S[rn(NF64S)];
    case 2:
        return esz == 32 ? (uint32_t)rnd() : rnd();
    default: {
        int e;
        switch (rn(8)) {
        case 0: e = rn(4); break;                               /* zero/denormal/tiny */
        case 1: e = emax - rn(4); break;                        /* huge/inf/NaN */
        case 2: e = bias + center + (int)rn(9) - 4; break;      /* around the center */
        case 3: e = bias + (int)rn(70) - 3; break;              /* integer range */
        default: e = rn(emax + 1); break;
        }
        if (e < 0) e = 0;
        if (e > emax) e = emax;
        return (uint64_t)(rnd() & 1) << (esz - 1) | (uint64_t)e << mbits | mant(mbits);
    }
    }
}
static double bits2d(uint64_t b, int esz)
{
    if (esz == 32) {
        uint32_t u = (uint32_t)b;
        float f;
        memcpy(&f, &u, 4);
        return f;
    }
    double d;
    memcpy(&d, &b, 8);
    return d;
}
static uint64_t d2bits(double d, int esz)
{
    if (esz == 32) {
        float f = (float)d;
        uint32_t u;
        memcpy(&u, &f, 4);
        return u;
    }
    uint64_t u;
    memcpy(&u, &d, 8);
    return u;
}
/* a second operand related to a: equal, negated, neighbours, or with an
 * exponent that puts a*b, a/b or a+b near the underflow/overflow edge */
static uint64_t gen_rel(uint64_t a, int esz)
{
    int ebits = esz == 32 ? 8 : 11, mbits = esz == 32 ? 23 : 52;
    int emax = (1 << ebits) - 1, bias = emax >> 1;
    uint64_t sign = 1ull << (esz - 1), mmask = (1ull << mbits) - 1;
    int ea = (int)((a >> mbits) & emax), e;
    switch (rn(12)) {
    case 0: return a;
    case 1: return a ^ sign;
    case 2: return a + 1;
    case 3: return (a - 1) ^ sign;
    case 4: e = bias + 1 - (ea - bias) + (int)rn(5) - 2; break;      /* a*b ~ 2^(1-bias) */
    case 5: e = bias + bias - (ea - bias) + (int)rn(5) - 2; break;   /* a*b ~ 2^bias */
    case 6: e = ea - (1 - bias) + (int)rn(5) - 2; break;             /* a/b ~ 2^(1-bias) */
    case 7: e = ea + (int)rn(3) - 1; a ^= sign; break;               /* cancellation */
    case 8: e = ea - mbits - 1 + (int)rn(3); break;                   /* half-ulp addend */
    default: return gen_fp(esz, 0);
    }
    if (e < 0) e = 0;
    if (e > emax) e = emax;
    return ((a & sign) ^ ((rnd() & 1) ? sign : 0) ^ (uint64_t)e << mbits) | (rn(2) ? mant(mbits) : (a & mmask));
}
/* addend near -(a*b): exact zeros, tiny results and cancellations */
static uint64_t gen_addend(uint64_t a, uint64_t b, int esz)
{
    if (rn(3) == 0) {
        return gen_rel(a, esz);
    }
    uint64_t c = d2bits(-(bits2d(a, esz) * bits2d(b, esz)), esz);
    switch (rn(4)) {
    case 0: return c;
    case 1: return c + 1;
    case 2: return c - 1;
    default: return c ^ (1ull << (esz - 1));
    }
}
static uint64_t gen_int(int iw)
{
    int w = iw < 0 ? -iw : iw;
    uint64_t v;
    switch (rn(6)) {
    case 0: v = I64S[rn(NI64S)]; break;
    case 1: v = rnd(); break;
    case 2: v = (rnd() >> rn(64)) << rn(64); break;     /* few significant bits */
    case 3: v = ((1ull << rn(64)) - 1) << rn(8); break;
    default: v = rnd() >> rn(64); if (rn(2)) v = -v; break;
    }
    if (w == 32) {
        v = iw < 0 ? (uint32_t)v : (uint64_t)(int64_t)(int32_t)v;
        if (rn(4) == 0) {
            v |= rnd() << 32;           /* garbage above the operand */
        }
    }
    return v;
}
/* FP values around the integer range edges of a conversion with shift sh */
static uint64_t gen_f2i(int esz, int sh)
{
    if (rn(3)) {
        return gen_fp(esz, (int)rn(66) - sh);
    }
    double lim = (double)(1ull << (rn(2) ? 31 : 63)) * (rn(2) ? 1 : 2);
    double v = rn(2) ? lim : -lim;
    v += (double)((int)rn(9) - 4) * 0.25;
    for (int i = 0; i < sh; i++) {
        v *= 0.5;
    }
    uint64_t b = d2bits(v, esz);
    return b + (uint64_t)(int64_t)((int)rn(5) - 2);
}

static unsigned gen_cfg(void)
{
    unsigned cfg;
    switch (rn(16)) {
    case 0: case 1: case 2: case 3: case 4: case 5: case 6: cfg = 0; break;
    case 7: case 8: case 9: cfg = rn(5) << 1; break;
    case 10: cfg = rn(6) << 1; break;                           /* + round to odd */
    case 11: cfg = 0x70; break;                                 /* FPST_STD */
    case 12: cfg = 0x31; break;                                 /* FPST_AH */
    default: cfg = (unsigned)rnd() & 0x71; cfg |= rn(6) << 1; break;
    }
    unsigned fl;
    switch (rn(8)) {
    case 0: case 1: fl = 0; break;
    case 2: case 3: case 4: fl = 0x10; break;
    case 5: fl = 0x10 | ((unsigned)rnd() & 0x7fff); break;
    case 6: fl = (unsigned)rnd() & 0x7fef; break;
    default: fl = 1; break;
    }
    return cfg | fl << 8;
}

static void set_desc(Case *c, const Ent *e)
{
    int oprsz = (e->oprsz == 3 ? (rn(2) ? 16 : 8) : e->oprsz == 2 ? 16 : 8);
    int data = 0;
    if (e->data == D_IDX) {
        data = rn(e->esz == 32 ? 4 : 2);
    } else if (e->data == D_SH) {
        data = rn(e->shmax + 1);
    } else if (e->data == D_RM) {
        data = rn(6);
    }
    c->desc = (16 / 8 - 1) | (uint32_t)(oprsz == 16 ? 2 : oprsz / 8 - 1) << 8 | (uint32_t)data << 10;
}

static void set_regs(Case *c, int nin)
{
    c->d = rn(4);
    c->n = rn(4);
    c->m = rn(4);
    c->a = rn(4);
    if (rn(2)) {                    /* distinct registers */
        c->n = (c->d + 1) & 3;
        c->m = (c->d + 2) & 3;
        c->a = (c->d + 3) & 3;
    }
}

static void fill_fp_lanes(Case *c, const Ent *e)
{
    int nl = 128 / e->esz;
    for (int r = 0; r < 4; r++) {
        for (int l = 0; l < nl; l++) {
            uint64_t v;
            if (e->kind != K_GF2 || e->data == D_NONE) {
                v = gen_fp(e->esz, 0);                          /* FP lanes */
            } else if (e->name[10] == 's' || e->name[10] == 'u') {
                v = gen_int(e->esz == 32 ? -32 : -64);          /* int -> FP */
            } else {
                v = gen_f2i(e->esz, e->data == D_SH ? (int)(c->desc >> 10) : 0);
            }
            memcpy(&c->v[r][l * e->esz / 8], &v, e->esz / 8);
        }
    }
    if ((e->kind == K_GF3 || e->kind == K_GF4) && c->m != c->n && rn(3)) {
        for (int l = 0; l < nl; l++) {
            uint64_t a = 0, b;
            memcpy(&a, &c->v[c->n][l * e->esz / 8], e->esz / 8);
            b = gen_rel(a, e->esz);
            memcpy(&c->v[c->m][l * e->esz / 8], &b, e->esz / 8);
        }
    }
    if ((e->kind == K_GF4 || strstr(e->name, "vfm")) && rn(2)) {
        int acc = e->kind == K_GF4 ? c->a : c->d;
        if (acc != c->n && acc != c->m) {
            int idx = e->data == D_IDX ? (int)(c->desc >> 10) : -1;
            for (int l = 0; l < nl; l++) {
                uint64_t a = 0, b = 0, s;
                memcpy(&a, &c->v[c->n][l * e->esz / 8], e->esz / 8);
                memcpy(&b, &c->v[c->m][(idx < 0 ? l : idx) * e->esz / 8], e->esz / 8);
                s = gen_addend(a, b, e->esz);
                if (strstr(e->name, "fms") || strstr(e->name, "fmls")) {
                    s ^= 1ull << (e->esz - 1);
                }
                memcpy(&c->v[acc][l * e->esz / 8], &s, e->esz / 8);
            }
        }
    }
}

static void gen_case(Case *c, const Ent *e)
{
    memset(c, 0, sizeof(*c));
    for (int r = 0; r < 4; r++) {
        uint64_t w[2] = { rnd(), rnd() };
        memcpy(c->v[r], w, 16);
    }
    c->x[0] = rnd();
    c->x[1] = rnd();
    c->x[2] = rnd();
    switch (e->kind) {
    case K_F1:
        c->x[0] = gen_fp(e->esz, 0);
        break;
    case K_F2:
        c->x[0] = gen_fp(e->esz, 0);
        c->x[1] = gen_rel(c->x[0], e->esz);
        if (rn(2)) {
            uint64_t t = c->x[0];
            c->x[0] = c->x[1];
            c->x[1] = t;
        }
        break;
    case K_F3:
        c->x[0] = gen_fp(e->esz, 0);
        c->x[1] = gen_rel(c->x[0], e->esz);
        c->x[2] = gen_addend(c->x[0], c->x[1], e->esz);
        break;
    case K_I2F:
        c->x[0] = gen_int(e->iw);
        c->sh = e->shmax ? rn(e->shmax + 1) : 0;
        break;
    case K_F2I:
        c->sh = e->shmax ? rn(e->shmax + 1) : 0;
        c->x[0] = gen_f2i(e->esz, (int)c->sh);
        break;
    case K_RM:
        c->x[0] = rn(7);
        break;
    case K_GF2:
    case K_GF3:
    case K_GF4:
        set_desc(c, e);
        set_regs(c, 0);
        fill_fp_lanes(c, e);
        break;
    case K_GI2:
    case K_GI3:
        set_desc(c, e);
        set_regs(c, 0);
        for (int r = 0; r < 4; r++) {
            if (rn(8) == 0) {
                memset(c->v[r], rn(2) ? 0xff : 0, 16);
            }
            if (rn(8) == 0) {
                memset(c->v[r] + rn(16), 0x80, 1);
            }
        }
        break;
    case K_INT:
        c->x[0] = gen_int(e->iw);
        c->x[1] = gen_int(e->iw);
        if (rn(8) == 0) {
            c->x[1] = rn(2) ? 0 : ~0ull;
        }
        break;
    case K_CRC: {
        static const uint32_t B[4] = { 1, 2, 4, 8 };
        c->sh = B[rn(4)];
        c->x[0] = rn(2) ? (uint32_t)rnd() : rnd();
        c->x[1] = c->sh == 8 ? rnd() : rnd() & ((1ull << (8 * c->sh)) - 1);
        break;
    }
    }
}

/* -------------------------------------------------------------- run */

static void set_fpcr(uint64_t v) { __asm__ __volatile__("msr fpcr, %0" :: "r"(v) : "memory"); }
static uint64_t get_fpcr(void)
{
    uint64_t v;
    __asm__ __volatile__("mrs %0, fpcr" : "=r"(v) :: "memory");
    return v;
}

static int FS;

static void dump(const char *what, const Case *c, const char *st)
{
    printf("    %s: x=%016llx %016llx %016llx sh=%u desc=%08x d%d n%d m%d a%d r=%016llx\n      st=",
           what, (unsigned long long)c->x[0], (unsigned long long)c->x[1], (unsigned long long)c->x[2],
           c->sh, c->desc, c->d, c->n, c->m, c->a, (unsigned long long)c->r);
    for (int i = 0; i < FS; i++) {
        printf("%02x", (uint8_t)st[i]);
    }
    printf("\n      v=");
    for (int r = 0; r < 4; r++) {
        for (int i = 15; i >= 0; i--) {
            printf("%02x", c->v[r][i]);
        }
        printf(r == 3 ? "\n" : " ");
    }
}

static void fail(Ent *e, const char *why, const Case *c0, const char *s0, const Case *ca,
                 const char *sa, const Case *cb, const char *sb)
{
    if (e->fail++ < 6) {
        printf("  FAIL %s: %s\n", e->name, why);
        dump("in ", c0, s0);
        dump("ref", ca, sa);
        if (cb) {
            dump("pt ", cb, sb);
        }
    }
}

/*
 * pt_unit bench: per-call time of the helper and of the passthrough for a
 * few helpers, on inputs the passthrough accepts (FP: with Inexact already
 * set, and with all flags clear, where the default build declines and the
 * -DAOT_PT_FPSR build uses the host FPSR).  Both sides run the same loop
 * (status reset, call), so the difference is the call itself.
 */
#include <time.h>
static double now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC_RAW, &t);
    return t.tv_sec * 1e9 + t.tv_nsec;
}
static int bench(void)
{
    static const struct { const char *name; unsigned flags; } B[] = {
        { "vfp_adds", 0x10 }, { "vfp_adds", 0 }, { "vfp_muladdd", 0x10 }, { "vfp_muladdd", 0 },
        { "vfp_divd", 0x10 }, { "vfp_cmps_a64", 0 }, { "vfp_tosls", 0 }, { "vfp_sqtos", 0x10 },
        { "gvec_fadd_s", 0x10 }, { "gvec_fadd_s", 0 }, { "gvec_fmla_idx_s", 0x10 },
        { "crypto_aese", 0 }, { "crypto_aesmc", 0 }, { "crypto_sha256h", 0 }, { "crc32c_64", 0 },
        { "muluh_i64", 0 }, { "udiv64", 0 }, { "neon_narrow_u8", 0 },
    };
    enum { N = 2000000 };
    char st[32], s[32];
    for (unsigned b = 0; b < sizeof(B) / sizeof(B[0]); b++) {
        Ent *e = 0;
        for (int i = 0; i < NENTS; i++) {
            if (!strcmp(ents[i].name, B[b].name)) {
                e = &ents[i];
            }
        }
        Case c0, c;
        int found = 0;
        for (int t = 0; t < 1000000 && !found; t++) {
            gen_case(&c0, e);
            pt_fs_make(st, B[b].flags << 8);
            memcpy(s, st, FS);
            memcpy(&c, &c0, sizeof(c));
            unsigned char after[2];
            found = e->pt(&c, s);
            memcpy(after, s, 2);
            /* FP: an input whose helper call raises nothing new */
            if (found && e->esz && B[b].flags == 0 && (after[0] | after[1])) {
                found = 0;
            }
        }
        if (!found) {
            printf("%-16s flags %02x: no accepted input\n", B[b].name, B[b].flags);
            continue;
        }
        double t0 = now_ns();
        for (int i = 0; i < N; i++) {
            memcpy(s, st, FS);
            e->ref(&c, s);
            __asm__ __volatile__("" ::: "memory");
        }
        double t1 = now_ns();
        int ok = 1;
        for (int i = 0; i < N; i++) {
            memcpy(s, st, FS);
            ok &= e->pt(&c, s);
            __asm__ __volatile__("" ::: "memory");
        }
        double t2 = now_ns();
        printf("%-16s flags %02x: helper %6.2f ns  passthrough %6.2f ns%s\n", B[b].name, B[b].flags,
               (t1 - t0) / N, (t2 - t1) / N, ok ? "" : "  (declined: helper call not included)");
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "bench")) {
        FS = pt_fs_size();
        return bench();
    }
    long iters = argc > 1 ? atol(argv[1]) : 200000;
    if (argc > 2) {
        rs = (strtoull(argv[2], 0, 0) + 1) * 0xbf58476d1ce4e5b9ull | 1;
    }
    const char *only = argc > 3 ? argv[3] : 0;
    FS = pt_fs_size();
    if (FS != 18) {
        printf("float_status is %d bytes, aot_rt.h assumes 18\n", FS);
        return 1;
    }
    if (get_fpcr() != 0) {
        printf("host FPCR is %llx, not 0\n", (unsigned long long)get_fpcr());
        return 1;
    }
    /* the configuration bytes aot_rt.h expects, from QEMU's own setters */
    char st[32], sa[32], sb[32];
    pt_fs_make(st, 0);
    uint64_t c3, c10;
    memcpy(&c3, st + 3, 8);
    memcpy(&c10, st + 10, 8);
    if (c3 != AOT_FS_CFG3 || c10 != AOT_FS_CFG10) {
        printf("float_status config bytes %016llx %016llx, aot_rt.h expects %016llx %016llx\n",
               (unsigned long long)c3, (unsigned long long)c10, (unsigned long long)AOT_FS_CFG3,
               (unsigned long long)AOT_FS_CFG10);
        return 1;
    }
    static const uint64_t BADFPCR[] = { 1 << 24, 1 << 22, 2 << 22, 3 << 22, 1 << 25, 1 << 19 };
    long tfail = 0;
    for (int i = 0; i < NENTS; i++) {
        Ent *e = &ents[i];
        if (only && !strstr(e->name, only)) {
            continue;
        }
        uint64_t dec_fpcr = 0, n_fpcr = 0;
        for (long it = 0; it < iters; it++) {
            Case c0, ca, cb;
            gen_case(&c0, e);
            unsigned cfg = e->kind == K_INT || e->kind == K_CRC || e->kind == K_GI2 || e->kind == K_GI3
                           ? 0 : gen_cfg();
            pt_fs_make(st, cfg);
            memcpy(sa, st, FS);
            memcpy(sb, st, FS);
            memcpy(&ca, &c0, sizeof(c0));
            memcpy(&cb, &c0, sizeof(c0));
            e->ref(&ca, sa);
            int mode = e->fallible && e->esz ? (int)rn(64) : 99;
            int ok;
            if (mode == 0) {                        /* non-zero host FPCR */
                uint64_t v = BADFPCR[rn(6)];
                set_fpcr(v);
                uint64_t got = get_fpcr();
                ok = e->pt(&cb, sb);
                set_fpcr(0);
                if (got) {
                    n_fpcr++;
                    if (ok) {
                        fail(e, "accepted with host FPCR != 0", &c0, st, &ca, sa, &cb, sb);
                    } else if (memcmp(&c0, &cb, sizeof(c0)) || memcmp(st, sb, FS)) {
                        fail(e, "declined (host FPCR) but changed state", &c0, st, &ca, sa, &cb, sb);
                    } else {
                        dec_fpcr++;
                    }
                    continue;
                }
            } else if (mode == 1) {                 /* QEMU_AOT_PT_FP=0 */
                aot_pt_on = 0;
                ok = e->pt(&cb, sb);
                aot_pt_on = 1;
                if (ok) {
                    fail(e, "accepted with aot_pt_on == 0", &c0, st, &ca, sa, &cb, sb);
                } else if (memcmp(&c0, &cb, sizeof(c0)) || memcmp(st, sb, FS)) {
                    fail(e, "declined (aot_pt_on) but changed state", &c0, st, &ca, sa, &cb, sb);
                }
                continue;
            } else {
                ok = e->pt(&cb, sb);
            }
            if (ok) {
                e->hit++;
                if (memcmp(&ca, &cb, sizeof(ca)) || memcmp(sa, sb, FS)) {
                    fail(e, e->fallible ? "accepted, result or status differs" : "result or status differs",
                         &c0, st, &ca, sa, &cb, sb);
                }
            } else {
                e->dec++;
                if (!e->fallible) {
                    fail(e, "infallible returned 0", &c0, st, &ca, sa, &cb, sb);
                } else if (memcmp(&c0, &cb, sizeof(c0)) || memcmp(st, sb, FS)) {
                    fail(e, "declined but changed state", &c0, st, &ca, sa, &cb, sb);
                }
            }
        }
        printf("%-28s inline %9llu declined %9llu failed %llu%s", e->name, (unsigned long long)e->hit,
               (unsigned long long)e->dec, (unsigned long long)e->fail,
               e->hit ? "" : "  (never inline)");
        if (n_fpcr) {
            printf("  (host FPCR != 0: %llu/%llu declined)", (unsigned long long)dec_fpcr,
                   (unsigned long long)n_fpcr);
        }
        printf("\n");
        tfail += (long)e->fail;
    }
    printf("pt-unit: %d helpers, %ld iterations each, %ld failures: %s\n", NENTS, iters, tfail,
           tfail ? "FAIL" : "PASS");
    return tfail != 0;
}
