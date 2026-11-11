#!/bin/zsh
# 128-bit atomics under MTTCG: correctness and cost (a128.c), JIT vs TCTI
# (vs TCTI + an AOT cache of the test's TBs).
#
#   tools/aot/tests/atomic128/run.sh [--out DIR] [--qemu NAME=PATH]... [--aot NAME] [--smp N]
#
# a128 is a static Android (bionic) binary that runs as /init of a one-file
# initramfs on the image's own kernel (-M virt, -cpu cortex-a76, -smp 4), so the
# 128-bit compare-and-swap really races between vCPU threads. Each QEMU's
# console output is DIR/NAME.txt; the script prints every test line and fails if
# a run is missing "A128 PASS".
#
# Default QEMUs: jit = engine/build-macos-aot-jit, tcti = engine/build-macos-tcti.
# --qemu adds (or replaces) one, e.g. --qemu tcti-old=/tmp/qemu-system-aarch64.
# --aot NAME: also capture every TB of a run of NAME (a TCTI build), build a cache
# with tools/aot/tcg2c.py bound to it, and run NAME with the cache (aot) and with
# its verify variant (verify, QEMU_AOT_VERIFY=64).
#
# Before TCTI had the 128-bit cmpxchg helper, every CASP and STXP pair in a
# CF_PARALLEL TB ended in helper_exit_atomic: all vCPUs stopped while one ran
# the instruction alone (cpu_exec_step_atomic). The ns/update columns show that.
set -e
HERE=${0:A:h}
ROOT="$(cd "$HERE/../../../.." && pwd)"
NDK="${NDK:-$HOME/Library/Android/sdk/ndk/29.0.13113456/toolchains/llvm/prebuilt/darwin-x86_64/bin}"
KERNEL="$ROOT/images/android-33/arm64-v8a/kernel-ranchu"
OUT="$ROOT/engine/run/a128-test"
SMP=4
AOT=
NAMES=(jit tcti)
typeset -A QEMU
QEMU=(jit "$ROOT/engine/build-macos-aot-jit/qemu-system-aarch64"
      tcti "$ROOT/engine/build-macos-tcti/qemu-system-aarch64")
while [ $# -gt 0 ]; do
    case "$1" in
    --out ) OUT="$2"; shift ;;
    --qemu ) n="${2%%=*}"; [ -n "${QEMU[$n]}" ] || NAMES+=("$n"); QEMU[$n]="${2#*=}"; shift ;;
    --aot ) AOT="$2"; shift ;;
    --smp ) SMP="$2"; shift ;;
    -h | --help ) sed -n 2,22p "$0"; exit 0 ;;
    * ) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

"$NDK/aarch64-linux-android29-clang" -static -O2 -march=armv8.2-a -Wall -o "$OUT/init" "$HERE/a128.c"
python3 -I - "$OUT/init" "$OUT/a128.cpio" <<'PYEOF'
import os, sys
data = open(sys.argv[1], "rb").read()
out = bytearray()
for i, (name, body, mode) in enumerate([("init", data, 0o100755), ("TRAILER!!!", b"", 0)]):
    nm = name.encode() + b"\0"
    f = [300001 + i, mode, 0, 0, 1, 0, len(body), 0, 0, 0, 0, len(nm), 0]
    out += b"070701" + b"".join(b"%08x" % v for v in f) + nm
    out += b"\0" * ((4 - (110 + len(nm)) % 4) % 4) + body + b"\0" * ((4 - len(body) % 4) % 4)
open(sys.argv[2], "wb").write(out)
PYEOF

run() {     # run NAME QEMU [ENV...]
    local name="$1" q="$2"
    shift 2
    local t0=$(date +%s)
    env "$@" "$q" -M virt -cpu cortex-a76 -smp "$SMP" -m 512 -accel tcg,thread=multi \
        -display none -monitor none -nic none -no-reboot -serial "file:$OUT/$name.txt" \
        -kernel "$KERNEL" -initrd "$OUT/a128.cpio" -append "console=ttyAMA0 rdinit=/init panic=-1" \
        > "$OUT/$name.stderr" 2>&1 || true
    echo "== $name ($(( $(date +%s) - t0 )) s): $q"
    grep -a "A128 " "$OUT/$name.txt" | sed 's/^.*A128 /   /' || echo "   no output"
}

for n in "${NAMES[@]}"; do
    [ -x "${QEMU[$n]}" ] || { echo "missing ${QEMU[$n]}" >&2; exit 1; }
    run "$n" "${QEMU[$n]}"
done
CHECK=("${NAMES[@]}")
if [ -n "$AOT" ]; then
    Q="${QEMU[$AOT]}"
    run capture "$Q" QEMU_AOT_CAPTURE="$OUT/ops-capture.txt"
    echo "   captured $(grep -c '^TB ' "$OUT/ops-capture.txt") TBs," \
         "$(grep -c 'atomic_cmpxchgo' "$OUT/ops-capture.txt") 128-bit cmpxchg calls," \
         "$(grep -c 'exit_atomic' "$OUT/ops-capture.txt") exit_atomic calls"
    rm -rf "$OUT/gen"
    python3 -I "$ROOT/tools/aot/tcg2c.py" "$OUT/ops-capture.txt" --out "$OUT/gen" --qemu "$Q" | sed 's/^/   /'
    ninja -C "$OUT/gen" -j "${NCPU:-6}" libaot.dylib libaot-verify.dylib > "$OUT/gen/build.log" 2>&1 ||
        { tail -20 "$OUT/gen/build.log"; exit 1; }
    run aot "$Q" QEMU_AOT_LIB="$OUT/gen/libaot.dylib" QEMU_AOT_STATS="$OUT/aot.json"
    run verify "$Q" QEMU_AOT_LIB="$OUT/gen/libaot-verify.dylib" QEMU_AOT_VERIFY=64 \
        QEMU_AOT_STATS="$OUT/verify.json"
    python3 -I - "$OUT" <<'PYEOF'
import json, os, sys
for n in ("aot", "verify"):
    s = json.load(open(os.path.join(sys.argv[1], n + ".json")))
    extra = ""
    if n == "verify":
        extra = (f", compared {s['v_compared']}, not replayable {s['v_unsafe']},"
                 f" mismatches {s['v_mismatch']} (flaky {s['v_flaky']}, chain races {s['v_chainrace']})")
    print(f"   {n}: table hits {s['lookup_hit']}, fp mismatches {s['fp_mismatch']},"
          f" AOT execs {s['aot_execs']}{extra}")
PYEOF
    CHECK+=(capture aot verify)
fi
FAIL=0
for n in "${CHECK[@]}"; do
    grep -aq "A128 PASS" "$OUT/$n.txt" || { echo "FAIL: $n"; FAIL=1; }
done
[ $FAIL = 0 ] && echo PASS
exit $FAIL
