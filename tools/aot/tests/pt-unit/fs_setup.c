/*
 * float_status construction for pt_unit.c, compiled with the QEMU headers
 * (run.sh) so that the layout and the setters are QEMU's own, not the
 * assumptions of aot_rt.h under test.
 */
#include "qemu/osdep.h"
#include "fpu/softfloat-helpers.h"

void arm_set_default_fp_behaviours(float_status *s);
void arm_set_ah_fp_behaviours(float_status *s);
int pt_fs_size(void);
void pt_fs_make(void *p, unsigned cfg);

int pt_fs_size(void)
{
    return sizeof(float_status);
}

/*
 * cfg bit 0: FPCR.AH behaviours (else the default ones), bits 1-3: rounding
 * mode, bit 4: flush_to_zero, bit 5: flush_inputs_to_zero, bit 6:
 * default_nan_mode, bits 8-23: exception flags.  Bits 4-6 off and bit 0 off
 * is FPST_A64/FPST_A32 with FPCR.FZ = FIZ = DN = AH = 0; bits 4-6 on is
 * FPST_STD (AArch32 Neon); bit 0 + bits 4-5 is FPST_AH.
 */
void pt_fs_make(void *p, unsigned cfg)
{
    float_status s;

    memset(&s, 0, sizeof(s));
    if (cfg & 1) {
        arm_set_ah_fp_behaviours(&s);
    } else {
        arm_set_default_fp_behaviours(&s);
    }
    set_float_rounding_mode((cfg >> 1) & 7, &s);
    set_flush_to_zero((cfg >> 4) & 1, &s);
    set_flush_inputs_to_zero((cfg >> 5) & 1, &s);
    set_default_nan_mode((cfg >> 6) & 1, &s);
    set_float_exception_flags((cfg >> 8) & 0xffff, &s);
    memcpy(p, &s, sizeof(s));
}
