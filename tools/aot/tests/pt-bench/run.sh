#!/bin/bash
# Same-ISA passthrough benchmark (docs/AOT.md, "Same-ISA passthrough").
#
#   tools/aot/tests/pt-bench/run.sh [--out DIR] [--iters N] [--reps R]
#
# Builds bench.elf (loops.S + bench.c, bare-metal, NDK clang) and times each
# hot loop with the guest counter on -M virt -cpu cortex-a76 -smp 1 under the
# JIT, plain TCTI and TCTI + an AOT cache captured from the same program:
# --no-passthrough, passthrough (default build) and --pt-fpsr.  Prints ns
# per loop iteration (best of R runs) and the speedup of the passthrough over
# --no-passthrough.  Output in DIR (default engine/run/pr-bench).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
OUT="$ROOT/engine/run/pr-bench"
ITERS=4000000
REPS=3
while [ $# -gt 0 ]; do
    case "$1" in
    --out ) OUT="$2"; shift ;;
    --iters ) ITERS="$2"; shift ;;
    --reps ) REPS="$2"; shift ;;
    -h | --help ) sed -n 2,12p "$0"; exit 0 ;;
    * ) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
JIT="$ROOT/engine/build-macos-aot-jit/qemu-system-aarch64"
TCTI="$ROOT/engine/build-macos-aot-tcti/qemu-system-aarch64"
NDK="${NDK:-$HOME/Library/Android/sdk/ndk/29.0.13113456/toolchains/llvm/prebuilt/darwin-x86_64/bin}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
FPT="$HERE/../fp-passthrough"
CC="$NDK/clang --target=aarch64-none-elf"
$CC -march=armv8.2-a+crypto+crc -c "$FPT/start.S" -o "$OUT/start.o"
$CC -march=armv8.2-a+crypto+crc -c "$HERE/loops.S" -o "$OUT/loops.o"
$CC -O2 -ffreestanding -fno-builtin -nostdlib -mgeneral-regs-only -mstrict-align -fno-stack-protector \
    -Wall -DITERS="$ITERS" -c "$HERE/bench.c" -o "$OUT/bench.o"
"$NDK/ld.lld" -T "$FPT/link.ld" -o "$OUT/bench.elf" "$OUT/start.o" "$OUT/loops.o" "$OUT/bench.o"

run() {     # run NAME QEMU [ENV...]
    local name="$1" q="$2"
    shift 2
    env "$@" "$q" -M virt -cpu cortex-a76 -smp 1 -m 256 -display none -monitor none \
        -serial "file:$OUT/$name.txt" -kernel "$OUT/bench.elf" > "$OUT/$name.stderr" 2>&1
    grep -q DONE "$OUT/$name.txt" || { echo "$name did not finish" >&2; cat "$OUT/$name.stderr" >&2; exit 1; }
}
gen() {     # gen DIR [tcg2c flags]
    local d="$1"
    shift
    rm -rf "$d"
    python3 -I "$ROOT/tools/aot/tcg2c.py" "$OUT/capture.txt" --out "$d" --qemu "$TCTI" "$@" > "$d.gen.txt"
    ninja -C "$d" -j "${NCPU:-6}" libaot.dylib > "$d.build.txt" 2>&1 || { tail "$d.build.txt"; exit 1; }
}

echo "pt-bench: $OUT/bench.elf, $ITERS iterations per loop, best of $REPS"
run cap-run "$TCTI" QEMU_AOT_CAPTURE="$OUT/capture.txt"
gen "$OUT/gen-nopt" --no-passthrough
gen "$OUT/gen-pt"
gen "$OUT/gen-fpsr" --pt-fpsr
CONFIGS="jit tcti aot-nopt aot-pt aot-fpsr"
for r in $(seq "$REPS"); do
    run "jit.$r" "$JIT"
    run "tcti.$r" "$TCTI"
    run "aot-nopt.$r" "$TCTI" QEMU_AOT_LIB="$OUT/gen-nopt/libaot.dylib"
    run "aot-pt.$r" "$TCTI" QEMU_AOT_LIB="$OUT/gen-pt/libaot.dylib"
    run "aot-fpsr.$r" "$TCTI" QEMU_AOT_LIB="$OUT/gen-fpsr/libaot.dylib"
done
python3 -I - "$OUT" "$REPS" $CONFIGS <<'PYEOF'
import sys, os, json
out, reps, cfgs = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
best, res = {}, {}
for c in cfgs:
    for r in range(1, reps + 1):
        for l in open(os.path.join(out, f"{c}.{r}.txt")):
            p = l.split()
            if p and p[0] == "B":
                ns = int(p[3]) / int(p[2])
                k = (c, p[1])
                best[k] = min(best.get(k, 1e30), ns)
                res.setdefault(p[1], {}).setdefault(c, []).append(round(ns, 2))
loops = list(res)
print(f"{'ns/iteration':12s} " + " ".join(f"{c:>9s}" for c in cfgs) + "   pt vs nopt  fpsr vs nopt")
for l in loops:
    row = [best[(c, l)] for c in cfgs]
    sp = best[("aot-nopt", l)] / best[("aot-pt", l)]
    sf = best[("aot-nopt", l)] / best[("aot-fpsr", l)]
    print(f"{l:12s} " + " ".join(f"{v:9.2f}" for v in row) + f"   {sp:9.2f}x  {sf:11.2f}x")
json.dump({"all_runs_ns_per_iter": res}, open(os.path.join(out, "bench.json"), "w"), indent=1)
PYEOF
