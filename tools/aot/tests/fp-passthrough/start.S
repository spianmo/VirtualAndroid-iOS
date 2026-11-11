/*
 * Entry for the passthrough differential test (EL1, MMU off at reset).
 * Enables FP/SIMD, builds an identity map with 1 GB blocks (Device below
 * 1 GB for the PL011, Normal write-back for RAM) so that guest accesses take
 * the softmmu fast path (and the AOT verifier can replay them), then calls
 * pt_main() and powers off through PSCI (HVC conduit on virt).
 */
    .section .text.boot, "ax"
    .global _start
_start:
    ldr     x0, =__stack_top
    mov     sp, x0
    mov     x0, #(3 << 20)              /* CPACR_EL1.FPEN = 0b11 */
    msr     cpacr_el1, x0
    isb
    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
1:  cmp     x0, x1
    b.hs    2f
    str     xzr, [x0], #8
    b       1b
2:  ldr     x0, =__pt_l1
    mov     x1, #0
3:  str     xzr, [x0, x1, lsl #3]       /* clear 512 entries */
    add     x1, x1, #1
    cmp     x1, #512
    b.lo    3b
    mov     x1, #0x401                  /* 0 GB: Device (AttrIndx 0), AF, block */
    str     x1, [x0]
    ldr     x1, =0x40000705             /* 1 GB: Normal (AttrIndx 1), AF, ISH, block */
    str     x1, [x0, #8]
    ldr     x1, =0xff00                 /* MAIR: attr0 Device-nGnRnE, attr1 Normal WB */
    msr     mair_el1, x1
    ldr     x1, =0x200803519            /* TCR: T0SZ 25, WBWA, ISH, 4K, EPD1, IPS 40 bit */
    msr     tcr_el1, x1
    msr     ttbr0_el1, x0
    dsb     ish
    isb
    mrs     x1, sctlr_el1
    orr     x1, x1, #(1 << 0)           /* M */
    orr     x1, x1, #(1 << 2)           /* C */
    orr     x1, x1, #(1 << 12)          /* I */
    bic     x1, x1, #(1 << 1)           /* no alignment checks */
    msr     sctlr_el1, x1
    isb
    bl      pt_main
    ldr     x0, =0x84000008             /* PSCI SYSTEM_OFF */
    hvc     #0
4:  wfi
    b       4b
