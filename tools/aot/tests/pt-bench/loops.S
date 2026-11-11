/*
 * Hot loops for the same-ISA passthrough benchmark (run.sh): each loop body
 * is one TB that goes through the helpers named in its comment.  x0 is the
 * iteration count; the loops keep their values in the normal range.
 */
    .text
    .p2align 4
    .global loop_fp_scalar                  /* vfp_muladdd, vfp_muls, vfp_adds, vfp_divd */
loop_fp_scalar:
    fmov    d0, #1.0
    fmov    d1, #0.5
    fmov    d2, #3.0
    fmov    s3, #1.0
    ldr     s4, =0x3f800001
    fmov    s5, #1.0
    fmov    s6, #0.125
    fmov    d7, #1.0
    fmov    d16, #3.0
    fdiv    d17, d7, d16                    /* raise Inexact once */
1:  fmadd   d0, d1, d2, d0
    fmul    s3, s3, s4
    fadd    s5, s5, s6
    fdiv    d7, d16, d2
    fmadd   d0, d1, d2, d0
    fmul    s3, s3, s4
    fadd    s5, s5, s6
    fdiv    d7, d16, d2
    subs    x0, x0, #1
    b.ne    1b
    fmov    x0, d0
    ret

    .p2align 4
    .global loop_fp_vector                  /* gvec_vfma_s, gvec_fmul_s, gvec_fadd_d, gvec_fmla_idx_s */
loop_fp_vector:
    fmov    v0.4s, #1.0
    fmov    v1.4s, #0.5
    fmov    v2.4s, #3.0
    fmov    v3.4s, #1.0
    fmov    v4.4s, #1.0
    fmov    v5.2d, #1.0
    fmov    v6.2d, #0.125
    fmov    d7, #1.0
    fmov    d16, #3.0
    fdiv    d17, d7, d16
1:  fmla    v0.4s, v1.4s, v2.4s
    fmul    v3.4s, v3.4s, v4.4s
    fadd    v5.2d, v5.2d, v6.2d
    fmla    v0.4s, v1.4s, v2.s[1]
    fmla    v0.4s, v1.4s, v2.4s
    fmul    v3.4s, v3.4s, v4.4s
    fadd    v5.2d, v5.2d, v6.2d
    fmla    v0.4s, v1.4s, v2.s[1]
    subs    x0, x0, #1
    b.ne    1b
    fmov    x0, d0
    ret

    .p2align 4
    .global loop_fp_convert                 /* set_rmode, vfp_tosls, vfp_sltos, rintd, vfp_cmpd_a64 */
loop_fp_convert:
    fmov    s1, #1.5
    fmov    d2, #2.5
    mov     w3, #12345
    mov     w4, #0
1:  fcvtzs  w5, s1
    scvtf   s6, w3
    frintm  d7, d2
    fcmp    d7, d2
    cinc    w4, w4, lt
    fcvtzs  w5, s1
    scvtf   s6, w3
    frintm  d7, d2
    fcmp    d7, d2
    cinc    w4, w4, lt
    subs    x0, x0, #1
    b.ne    1b
    mov     w0, w4
    ret

    .p2align 4
    .global loop_crypto                     /* crypto_aese, crypto_aesmc, crypto_sha256h/h2/su0/su1 */
loop_crypto:
    movi    v0.16b, #0x5a
    movi    v1.16b, #0x33
    movi    v2.4s, #1
    movi    v3.4s, #2
    movi    v4.4s, #3
1:  aese    v0.16b, v1.16b
    aesmc   v0.16b, v0.16b
    aese    v0.16b, v1.16b
    aesmc   v0.16b, v0.16b
    sha256h q2, q3, v4.4s
    sha256h2 q3, q2, v4.4s
    sha256su0 v4.4s, v0.4s
    sha256su1 v4.4s, v2.4s, v3.4s
    subs    x0, x0, #1
    b.ne    1b
    fmov    x0, d0
    ret

    .p2align 4
    .global loop_int                        /* crc32c_64, crc32_64, udiv64, muluh_i64, rbit64 */
loop_int:
    mov     x1, #0x1234
    mov     w2, #0
    mov     x3, #7
    mov     x5, #0
1:  crc32cx w2, w2, x1
    crc32cx w2, w2, x0
    crc32w  w6, w2, w1
    udiv    x4, x0, x3
    umulh   x5, x4, x1
    rbit    x7, x5
    add     x1, x1, x7
    subs    x0, x0, #1
    b.ne    1b
    mov     w0, w2
    ret

    .global pt_cntvct
pt_cntvct:
    isb
    mrs     x0, cntvct_el0
    ret
    .global pt_cntfrq
pt_cntfrq:
    mrs     x0, cntfrq_el0
    ret
