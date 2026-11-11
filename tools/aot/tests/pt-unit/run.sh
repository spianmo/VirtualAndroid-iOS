#!/bin/bash
# Host unit test of the same-ISA passthrough (pt_unit.c; docs/AOT.md,
# "Same-ISA passthrough").
#
#   tools/aot/tests/pt-unit/run.sh [--out DIR] [--build DIR] [ITERATIONS [SEED [HELPER]]]
#
# Links pt_unit.c against the real helper objects of a QEMU build of
# engine/qemu-aot (default engine/build-macos-aot-tcti, read only: target/arm
# vfp/vec/neon/crypto/a64/op helpers, fpu/softfloat, tcg-runtime, crc32c,
# aes), with every other symbol those objects reference stubbed out (a stub
# aborts if it is ever called), and runs it, for the default build and the
# -DAOT_PT_FPSR variant.  Also runs pt-proto-check.py first.
# Output in DIR (default engine/run/pr-unit).  Exit status 0 on success.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
AOT="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$AOT/../.." && pwd)"
OUT="$ROOT/engine/run/pr-unit"
B="$ROOT/engine/build-macos-aot-tcti"
while [ $# -gt 0 ]; do
    case "$1" in
    --out ) OUT="$2"; shift ;;
    --build ) B="$(cd "$2" && pwd)"; shift ;;
    -h | --help ) sed -n 2,13p "$0"; exit 0 ;;
    * ) break ;;
    esac
    shift
done
mkdir -p "$OUT"
CC="${CC:-clang}"
OBJS=(
    "$B/libqemu-aarch64-softmmu.a.p/target_arm_tcg_vfp_helper.c.o"
    "$B/libqemu-aarch64-softmmu.a.p/target_arm_tcg_vec_helper.c.o"
    "$B/libqemu-aarch64-softmmu.a.p/target_arm_tcg_neon_helper.c.o"
    "$B/libqemu-aarch64-softmmu.a.p/target_arm_tcg_crypto_helper.c.o"
    "$B/libqemu-aarch64-softmmu.a.p/target_arm_tcg_helper-a64.c.o"
    "$B/libqemu-aarch64-softmmu.a.p/target_arm_tcg_op_helper.c.o"
    "$B/libcommon.a.p/fpu_softfloat.c.o"
    "$B/libcommon.a.p/accel_tcg_tcg-runtime.c.o"
    "$B/libqemuutil.a.p/util_crc32c.c.o"
    "$B/libqemuutil.a.p/crypto_aes.c.o"
    "$B/libqemuutil.a.p/crypto_clmul.c.o"
    "$B/libqemuutil.a.p/util_host-utils.c.o"
)
for o in "${OBJS[@]}"; do
    [ -f "$o" ] || { echo "missing $o (tools/aot/build-variants.sh)" >&2; exit 1; }
done

echo "pt-unit: prototype check"
python3 -I -B "$AOT/tests/pt-proto-check.py"

# fs_setup.c with the QEMU build's own include flags (from softfloat.c's
# compile command, made independent of the build directory)
QFLAGS="$(python3 -I - "$B" <<'PYEOF'
import json, shlex, sys, os
b = sys.argv[1]
for e in json.load(open(os.path.join(b, "compile_commands.json"))):
    if e["file"].endswith("fpu/softfloat.c"):
        a = shlex.split(e["command"])[1:]
        out, skip = [], False
        for i, x in enumerate(a):
            if skip:
                skip = False
                continue
            if x in ("-o", "-c", "-MQ", "-MF"):
                skip = True
                continue
            if x == "-MD" or x.endswith("softfloat.c"):
                continue
            if x.startswith("-W"):
                continue
            prev = a[i - 1] if i else ""
            if prev in ("-iquote", "-I") and not os.path.isabs(x):
                x = os.path.normpath(os.path.join(e["directory"], x))
            elif x.startswith("-I") and len(x) > 2 and not os.path.isabs(x[2:]):
                x = "-I" + os.path.normpath(os.path.join(e["directory"], x[2:]))
            out.append(x)
        print(shlex.join(out))
        break
PYEOF
)"
eval "$CC $QFLAGS -w -c \"$HERE/fs_setup.c\" -o \"$OUT/fs_setup.o\""
for v in "" _fpsr; do
    "$CC" -O2 -ffp-contract=off -mcrc -Wall -Wno-unused-function -I"$AOT" -DAOT_PAGE_BITS=12 \
        ${v:+-DAOT_PT_FPSR} -c "$HERE/pt_unit.c" -o "$OUT/pt_unit$v.o"
done

# stub every symbol the helper objects need from the rest of QEMU
link() {
    local v="$1"
    shift
    "$CC" -o "$OUT/pt_unit$v" "$OUT/pt_unit$v.o" "$OUT/fs_setup.o" "$@" "${OBJS[@]}" -lz
}
if link "" 2> "$OUT/link1.log"; then
    link _fpsr
else
    python3 -I - "$OUT/link1.log" "$OUT/stubs.c" <<'PYEOF'
import re, sys
syms = sorted(set(re.findall(r'^\s+"_([A-Za-z0-9_$.]+)", referenced from', open(sys.argv[1]).read(), re.M)))
with open(sys.argv[2], "w") as f:
    f.write("#include <stdio.h>\n#include <stdlib.h>\n")
    f.write("static void pt_stub(const char *s) { fprintf(stderr, \"pt-unit: stub %s called\\n\", s); abort(); }\n")
    for s in syms:
        f.write(f"void {s}(void) {{ pt_stub(\"{s}\"); }}\n")
print(f"  {len(syms)} stubs")
PYEOF
    "$CC" -O1 -w -c "$OUT/stubs.c" -o "$OUT/stubs.o"
    for v in "" _fpsr; do
        link "$v" "$OUT/stubs.o" 2> "$OUT/link2.log" || { tail -30 "$OUT/link2.log"; exit 1; }
    done
fi
ok=1
for v in "" _fpsr; do
    echo "pt-unit: running pt_unit$v (${v:+-DAOT_PT_FPSR, }results in $OUT/pt_unit$v.txt)"
    "$OUT/pt_unit$v" "$@" > "$OUT/pt_unit$v.txt" || ok=0
    grep -v " failed 0\( \|\$\)" "$OUT/pt_unit$v.txt" | grep -v "^pt-unit:" | head -60
    grep -c "(never inline)" "$OUT/pt_unit$v.txt" | sed 's/^/  helpers never inline: /'
    tail -1 "$OUT/pt_unit$v.txt"
done
[ $ok = 1 ]
