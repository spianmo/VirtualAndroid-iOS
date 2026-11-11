/*
 * One function per tested instruction (sequence), each its own small TB:
 *   void op(const struct pt_in *in, uint64_t out[3])
 * in:  v1 = in[0..15], v2 = in[16..31], v3 = in[32..47], v0 = in[48..63],
 *      x2 = in[64], x3 = in[72]
 * out: v0 (128 bits), x4 (integer results, NZCV for compares)
 * Every instruction below goes through the QEMU helper named in the
 * comment (QEMU 10.0 target/arm), which the AOT cache passes through.
 */
#define OP(name, ...)                       \
    .global name;                           \
    .p2align 4;                             \
name:                                       \
    ldp     q1, q2, [x0];                   \
    ldp     q3, q0, [x0, #32];              \
    ldp     x2, x3, [x0, #64];              \
    mov     x4, #0;                         \
    __VA_ARGS__;                            \
    str     q0, [x1];                       \
    str     x4, [x1, #16];                  \
    ret;

    .text
/* FP environment */
    .global pt_set_fpcr, pt_set_fpsr, pt_get_fpsr, pt_prime_ix
pt_set_fpcr:
    msr     fpcr, x0
    ret
pt_set_fpsr:
    msr     fpsr, x0
    ret
pt_get_fpsr:
    mrs     x0, fpsr
    ret
pt_prime_ix:                                /* 1/3: raises Inexact (vfp_divs) */
    fmov    s30, #1.0
    fmov    s29, #3.0
    fdiv    s31, s30, s29
    ret

/* scalar binary: vfp_{add,sub,mul,div,min,max,minnum,maxnum}{s,d} */
OP(op_fadd_s, fadd s0, s1, s2)
OP(op_fsub_s, fsub s0, s1, s2)
OP(op_fmul_s, fmul s0, s1, s2)
OP(op_fdiv_s, fdiv s0, s1, s2)
OP(op_fmin_s, fmin s0, s1, s2)
OP(op_fmax_s, fmax s0, s1, s2)
OP(op_fminnm_s, fminnm s0, s1, s2)
OP(op_fmaxnm_s, fmaxnm s0, s1, s2)
OP(op_fadd_d, fadd d0, d1, d2)
OP(op_fsub_d, fsub d0, d1, d2)
OP(op_fmul_d, fmul d0, d1, d2)
OP(op_fdiv_d, fdiv d0, d1, d2)
OP(op_fmin_d, fmin d0, d1, d2)
OP(op_fmax_d, fmax d0, d1, d2)
OP(op_fminnm_d, fminnm d0, d1, d2)
OP(op_fmaxnm_d, fmaxnm d0, d1, d2)
/* compares: vfp_cmp{s,d}_a64, vfp_cmpe{s,d}_a64 */
OP(op_fcmp_s, fcmp s1, s2; mrs x4, nzcv)
OP(op_fcmpe_s, fcmpe s1, s2; mrs x4, nzcv)
OP(op_fcmp_d, fcmp d1, d2; mrs x4, nzcv)
OP(op_fcmpe_d, fcmpe d1, d2; mrs x4, nzcv)
OP(op_fcmp0_s, fcmp s1, #0.0; mrs x4, nzcv)
/* fused multiply-add: vfp_muladd{s,d} (FMSUB/FNMADD negate inputs) */
OP(op_fmadd_s, fmadd s0, s1, s2, s3)
OP(op_fmsub_s, fmsub s0, s1, s2, s3)
OP(op_fnmadd_s, fnmadd s0, s1, s2, s3)
OP(op_fmadd_d, fmadd d0, d1, d2, d3)
OP(op_fnmsub_d, fnmsub d0, d1, d2, d3)
/* unary */
OP(op_fsqrt_s, fsqrt s0, s1)
OP(op_fsqrt_d, fsqrt d0, d1)
OP(op_fcvt_ds, fcvt d0, s1)                 /* vfp_fcvtds */
OP(op_fcvt_sd, fcvt s0, d1)                 /* vfp_fcvtsd */
OP(op_frintn_s, frintn s0, s1)              /* set_rmode + rints */
OP(op_frintm_s, frintm s0, s1)
OP(op_frintp_s, frintp s0, s1)
OP(op_frintz_s, frintz s0, s1)
OP(op_frinta_s, frinta s0, s1)
OP(op_frinti_s, frinti s0, s1)
OP(op_frintx_s, frintx s0, s1)              /* rints_exact */
OP(op_frintn_d, frintn d0, d1)
OP(op_frintm_d, frintm d0, d1)
OP(op_frinta_d, frinta d0, d1)
OP(op_frinti_d, frinti d0, d1)
OP(op_frintx_d, frintx d0, d1)
/* float -> int: vfp_to{sl,ul,sq,uq}{s,d} with set_rmode */
OP(op_fcvtzs_ws, fcvtzs w4, s1)
OP(op_fcvtzs_xs, fcvtzs x4, s1)
OP(op_fcvtzu_ws, fcvtzu w4, s1)
OP(op_fcvtzu_xs, fcvtzu x4, s1)
OP(op_fcvtzs_wd, fcvtzs w4, d1)
OP(op_fcvtzs_xd, fcvtzs x4, d1)
OP(op_fcvtzu_wd, fcvtzu w4, d1)
OP(op_fcvtzu_xd, fcvtzu x4, d1)
OP(op_fcvtns_ws, fcvtns w4, s1)
OP(op_fcvtms_xd, fcvtms x4, d1)
OP(op_fcvtps_wd, fcvtps w4, d1)
OP(op_fcvtas_xs, fcvtas x4, s1)
OP(op_fcvtau_wd, fcvtau w4, d1)
OP(op_fcvtzs_ws8, fcvtzs w4, s1, #8)        /* fixed point */
OP(op_fcvtzu_xd32, fcvtzu x4, d1, #32)
OP(op_fcvtzs_xd64, fcvtzs x4, d1, #64)
/* int -> float: vfp_{sq,uq}to{s,d} */
OP(op_scvtf_sx, scvtf s0, x2)
OP(op_scvtf_sw, scvtf s0, w2)
OP(op_ucvtf_sx, ucvtf s0, x2)
OP(op_ucvtf_sw, ucvtf s0, w2)
OP(op_scvtf_dx, scvtf d0, x2)
OP(op_scvtf_dw, scvtf d0, w2)
OP(op_ucvtf_dx, ucvtf d0, x2)
OP(op_scvtf_sx3, scvtf s0, x2, #3)
OP(op_ucvtf_sw16, ucvtf s0, w2, #16)
OP(op_scvtf_dx40, scvtf d0, x2, #40)
OP(op_ucvtf_dx64, ucvtf d0, x2, #64)

/* vector arithmetic: gvec_f{add,sub,mul,div,min,max,minnum,maxnum}_{s,d} */
#define V3(n, i)                                    \
OP(op_##n##_4s, i v0.4s, v1.4s, v2.4s)              \
OP(op_##n##_2s, i v0.2s, v1.2s, v2.2s)              \
OP(op_##n##_2d, i v0.2d, v1.2d, v2.2d)
V3(vfadd, fadd)
V3(vfsub, fsub)
V3(vfmul, fmul)
V3(vfdiv, fdiv)
V3(vfmin, fmin)
V3(vfmax, fmax)
V3(vfminnm, fminnm)
V3(vfmaxnm, fmaxnm)
V3(vfcmeq, fcmeq)                           /* gvec_fceq_s/d */
V3(vfcmge, fcmge)
V3(vfcmgt, fcmgt)
V3(vfmla, fmla)                             /* gvec_vfma_s/d */
V3(vfmls, fmls)                             /* gvec_vfms_s/d */
/* by element: gvec_fmul_idx_{s,d}, gvec_fmla_idx_{s,d}, gvec_fmls_idx_s */
OP(op_vfmul_e4s, fmul v0.4s, v1.4s, v2.s[2])
OP(op_vfmul_e2s, fmul v0.2s, v1.2s, v2.s[3])
OP(op_vfmul_e2d, fmul v0.2d, v1.2d, v2.d[1])
OP(op_vfmla_e4s, fmla v0.4s, v1.4s, v2.s[1])
OP(op_vfmla_e2s, fmla v0.2s, v1.2s, v2.s[0])
OP(op_vfmla_e2d, fmla v0.2d, v1.2d, v2.d[1])
OP(op_vfmls_e4s, fmls v0.4s, v1.4s, v2.s[3])
/* compare with zero: gvec_f{ceq,cgt,cge,clt,cle}0_{s,d} */
OP(op_vfcmeq0_4s, fcmeq v0.4s, v1.4s, #0.0)
OP(op_vfcmgt0_4s, fcmgt v0.4s, v1.4s, #0.0)
OP(op_vfcmge0_2s, fcmge v0.2s, v1.2s, #0.0)
OP(op_vfcmlt0_4s, fcmlt v0.4s, v1.4s, #0.0)
OP(op_vfcmle0_2d, fcmle v0.2d, v1.2d, #0.0)
OP(op_vfcmeq0_2d, fcmeq v0.2d, v1.2d, #0.0)
/* conversions: gvec_vcvt_{sf,uf,sd,ud,rz_*,rm_*} */
OP(op_vscvtf_4s, scvtf v0.4s, v1.4s)
OP(op_vucvtf_2s, ucvtf v0.2s, v1.2s)
OP(op_vscvtf_4s5, scvtf v0.4s, v1.4s, #5)
OP(op_vucvtf_4s32, ucvtf v0.4s, v1.4s, #32)
OP(op_vscvtf_2d, scvtf v0.2d, v1.2d)
OP(op_vucvtf_2d20, ucvtf v0.2d, v1.2d, #20)
OP(op_vfcvtzs_4s, fcvtzs v0.4s, v1.4s)
OP(op_vfcvtzu_2s, fcvtzu v0.2s, v1.2s)
OP(op_vfcvtzs_4s4, fcvtzs v0.4s, v1.4s, #4)
OP(op_vfcvtzu_4s31, fcvtzu v0.4s, v1.4s, #31)
OP(op_vfcvtns_4s, fcvtns v0.4s, v1.4s)
OP(op_vfcvtms_2s, fcvtms v0.2s, v1.2s)
OP(op_vfcvtpu_4s, fcvtpu v0.4s, v1.4s)
OP(op_vfcvtas_4s, fcvtas v0.4s, v1.4s)
OP(op_vfcvtzs_2d, fcvtzs v0.2d, v1.2d)
OP(op_vfcvtnu_2d, fcvtnu v0.2d, v1.2d)
OP(op_vfcvtzs_2d10, fcvtzs v0.2d, v1.2d, #10)
/* aliasing: vd == vn, vd == vm (pairwise and indexed helpers copy vm) */
OP(op_alias_fadd, fadd v1.4s, v1.4s, v2.4s; mov v0.16b, v1.16b)
OP(op_alias_fmla_e, fmla v2.4s, v1.4s, v2.s[0]; mov v0.16b, v2.16b)
OP(op_alias_fmul_e, fmul v2.2d, v2.2d, v2.d[1]; mov v0.16b, v2.16b)
OP(op_alias_fmls, fmls v0.4s, v0.4s, v0.4s)
OP(op_alias_addp, addp v2.16b, v1.16b, v2.16b; mov v0.16b, v2.16b)
OP(op_alias_aesmc, aesmc v0.16b, v0.16b)
OP(op_alias_sha256h, sha256h q2, q1, v2.4s; mov v0.16b, v2.16b)

/* integer Neon: gvec_addp_*, gvec_{u,s}{max,min}p_*, gvec_cnt_b, gvec_rbit_b,
 * neon_narrow_u8/u16 (XTN), neon_widen_u8/u16 (SHLL), neon_clz_u16 */
OP(op_addp_16b, addp v0.16b, v1.16b, v2.16b)
OP(op_addp_8b, addp v0.8b, v1.8b, v2.8b)
OP(op_addp_8h, addp v0.8h, v1.8h, v2.8h)
OP(op_addp_2s, addp v0.2s, v1.2s, v2.2s)
OP(op_addp_2d, addp v0.2d, v1.2d, v2.2d)
OP(op_umaxp_16b, umaxp v0.16b, v1.16b, v2.16b)
OP(op_uminp_8b, uminp v0.8b, v1.8b, v2.8b)
OP(op_smaxp_8h, smaxp v0.8h, v1.8h, v2.8h)
OP(op_sminp_4s, sminp v0.4s, v1.4s, v2.4s)
OP(op_cnt_16b, cnt v0.16b, v1.16b)
OP(op_cnt_8b, cnt v0.8b, v1.8b)
OP(op_rbit_16b, rbit v0.16b, v1.16b)
OP(op_rbit_8b, rbit v0.8b, v1.8b)
OP(op_xtn_8b, xtn v0.8b, v1.8h)
OP(op_xtn2_4h, xtn2 v0.8h, v1.4s)
OP(op_shll_8h, shll v0.8h, v1.8b, #8)
OP(op_shll2_2d, shll2 v0.2d, v1.4s, #32)
OP(op_clz_8h, clz v0.8h, v1.8h)
OP(op_clz_4h, clz v0.4h, v1.4h)
/* crypto: crypto_aes{e,d,mc,imc}, crypto_sha256{h,h2,su0,su1} */
OP(op_aese, aese v0.16b, v1.16b)
OP(op_aesd, aesd v0.16b, v1.16b)
OP(op_aesmc, aesmc v0.16b, v1.16b)
OP(op_aesimc, aesimc v0.16b, v1.16b)
OP(op_aese_mc, aese v0.16b, v1.16b; aesmc v0.16b, v0.16b)
OP(op_sha256h, sha256h q0, q1, v2.4s)
OP(op_sha256h2, sha256h2 q0, q1, v2.4s)
OP(op_sha256su0, sha256su0 v0.4s, v1.4s)
OP(op_sha256su1, sha256su1 v0.4s, v1.4s, v2.4s)
/* CRC: crc32_64, crc32c_64 (bytes 1, 2, 4, 8) */
OP(op_crc32b, crc32b w4, w2, w3)
OP(op_crc32h, crc32h w4, w2, w3)
OP(op_crc32w, crc32w w4, w2, w3)
OP(op_crc32x, crc32x w4, w2, x3)
OP(op_crc32cb, crc32cb w4, w2, w3)
OP(op_crc32ch, crc32ch w4, w2, w3)
OP(op_crc32cw, crc32cw w4, w2, w3)
OP(op_crc32cx, crc32cx w4, w2, x3)
/* integer: mulsh_i64/muluh_i64 (TCTI), sdiv64/udiv64, rbit/rbit64 */
OP(op_smulh, smulh x4, x2, x3)
OP(op_umulh, umulh x4, x2, x3)
OP(op_sdiv, sdiv x4, x2, x3)
OP(op_udiv, udiv x4, x2, x3)
OP(op_rbit_x, rbit x4, x2)
OP(op_rbit_w, rbit w4, w2)

/* added by the review (passthrough-review): more conversion and rounding
 * forms, AdvSIMD scalar forms, FNMUL, 2D by-element FMLS, AES decrypt round */
OP(op_frintp_d, frintp d0, d1)
OP(op_frintz_d, frintz d0, d1)
OP(op_fnmul_s, fnmul s0, s1, s2)
OP(op_fnmadd_d, fnmadd d0, d1, d2, d3)
OP(op_fcvtzu_ws12, fcvtzu w4, s1, #12)
OP(op_fcvtnu_xs, fcvtnu x4, s1)
OP(op_fcvtmu_wd, fcvtmu w4, d1)
OP(op_fcvtpu_xd, fcvtpu x4, d1)
OP(op_scvtf_sw32, scvtf s0, w2, #32)
OP(op_ucvtf_dw, ucvtf d0, w2)
OP(op_fcvtzs_s1, fcvtzs s0, s1)             /* AdvSIMD scalar */
OP(op_fcvtzu_d1, fcvtzu d0, d1, #3)
OP(op_scvtf_s1, scvtf s0, s1)
OP(op_ucvtf_d1, ucvtf d0, d1, #7)
OP(op_vucvtf_4s, ucvtf v0.4s, v1.4s)
OP(op_vscvtf_2d64, scvtf v0.2d, v1.2d, #64)
OP(op_vfcvtzu_2d64, fcvtzu v0.2d, v1.2d, #64)
OP(op_vfcvtmu_2d, fcvtmu v0.2d, v1.2d)
OP(op_vfcvtps_2d, fcvtps v0.2d, v1.2d)
OP(op_vfcvtau_4s, fcvtau v0.4s, v1.4s)
OP(op_vfmls_e2d, fmls v0.2d, v1.2d, v2.d[0])
OP(op_vfmls_e2s, fmls v0.2s, v1.2s, v2.s[2])
OP(op_vfcmgt0_2s, fcmgt v0.2s, v1.2s, #0.0)
OP(op_vfcmle0_4s, fcmle v0.4s, v1.4s, #0.0)
OP(op_aesd_imc, aesd v0.16b, v1.16b; aesimc v0.16b, v0.16b)
OP(op_addp_4h, addp v0.4h, v1.4h, v2.4h)
OP(op_smaxp_16b, smaxp v0.16b, v1.16b, v2.16b)
OP(op_uminp_8h, uminp v0.8h, v1.8h, v2.8h)
OP(op_umaxp_2s, umaxp v0.2s, v1.2s, v2.2s)
