#!/bin/bash
# Build the AOT translation cache (docs/AOT.md) for the iOS / iOS Simulator
# TCTI QEMU and package it as va_aot.framework next to that QEMU framework.
#
#   engine/scripts/ios/build_aot.sh [-p ios|ios_simulator] [-c CAPTURE.txt]
#                                   [--prof PROF.tsv] [--max N]
#                                   [--no-passthrough] [--out DIR]
#
#   -p      platform (default ios_simulator)
#   -c      op capture (QEMU_AOT_CAPTURE) from a TCTI build of the same source
#           and configuration; without -c the last capture is reused
#   --prof  tbprof TSV: keep the hottest TBs first (with --max)
#   --max   cap the number of TBs (0 = all captured TBs)
#   --no-passthrough
#           plain helper calls for FP/crypto/CRC (no same-ISA passthrough,
#           docs/AOT.md); also AOT_PASSTHROUGH=0 in the environment
#   --out   generate and compile into DIR only (toolchain checks): no
#           framework, nothing written under qemu-tcti/
#
# The cache calls QEMU helpers at offsets from aot_anchor read from this exact
# QEMU binary (nm), so run it again after every rebuild of the TCTI framework
# (QEMU rejects a stale table and falls back to plain TCTI). Output:
#   engine/build-ios/<platform>-<arch>/qemu-tcti/
#       aot/                        generated C, objects, libaot.dylib,
#                                   bound-qemu.sha1 (QEMU binary it is bound to)
#       Frameworks/va_aot.framework what make_xcframeworks.sh pairs with the
#                                   QEMU slice it was bound to
# The app passes the framework's binary to QEMU as QEMU_AOT_LIB.
set -e
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PLATFORM=ios_simulator
ARCH=arm64
CAPTURE=
PROF=
MAX=0
PASSTHROUGH="${AOT_PASSTHROUGH:-1}"
GEN_ONLY=
while [ $# -gt 0 ]; do
    case "$1" in
    -p ) PLATFORM="$2"; shift ;;
    -c ) CAPTURE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift ;;
    --prof ) PROF="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift ;;
    --max ) MAX="$2"; shift ;;
    --no-passthrough ) PASSTHROUGH=0 ;;
    --out ) mkdir -p "$2"; GEN_ONLY="$(cd "$2" && pwd)"; shift ;;
    -h | --help ) sed -n 2,28p "$0"; exit 0 ;;
    * ) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
export PLATFORM ARCH
. "$SELF_DIR/common.sh"

Q="$PLAT_DIR/qemu-tcti"
QBIN="$Q/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu"
GEN="${GEN_ONLY:-$Q/aot}"
[ -f "$QBIN" ] || die "missing $QBIN: run build_qemu.sh -p $PLATFORM -b tcti first"
[ -n "$GEN_ONLY" ] && [ -z "$CAPTURE" ] && die "--out needs -c CAPTURE.txt"
mkdir -p "$GEN"
if [ -n "$CAPTURE" ]; then
    [ -f "$CAPTURE" ] || die "no capture at $CAPTURE"
    ln -sf "$CAPTURE" "$GEN/capture.txt"
    if [ -n "$PROF" ]; then ln -sf "$PROF" "$GEN/prof.tsv"; else rm -f "$GEN/prof.tsv"; fi
    echo "$MAX" > "$GEN/max"
fi
[ -e "$GEN/capture.txt" ] || die "no capture yet: pass -c CAPTURE.txt"
PROF_ARGS=()
[ -e "$GEN/prof.tsv" ] && PROF_ARGS=(--prof "$GEN/prof.tsv")
MAX="$(cat "$GEN/max" 2>/dev/null || echo 0)"
PT_ARGS=()
[ "$PASSTHROUGH" = 0 ] && PT_ARGS=(--no-passthrough)

say "generating C from $(readlink "$GEN/capture.txt"), bound to $QBIN" \
    "(passthrough $([ "$PASSTHROUGH" = 0 ] && echo off || echo on))"
# tcg2c.py adds -mcrc (CRC32 is not in the arm64 iOS baseline; AES/SHA-256
# are) and -ffp-contract=off for the passthrough code
python3 -I "$ROOT/tools/aot/tcg2c.py" "$GEN/capture.txt" --out "$GEN" --max "$MAX" "${PROF_ARGS[@]}" \
    "${PT_ARGS[@]}" --qemu "$QBIN" --cc "$(xcrun --sdk $SDK --find clang)" \
    --cflags "-arch $ARCH -isysroot $SDKROOT $CFLAGS_TARGET" \
    --ldflags "-install_name @rpath/va_aot.framework/va_aot"
say "compiling ($NCPU jobs)"
ninja -C "$GEN" -j "$NCPU" libaot.dylib
if [ -n "$GEN_ONLY" ]; then
    say "done: $GEN/libaot.dylib ($(du -h "$GEN/libaot.dylib" | cut -f1)), not packaged"
    exit 0
fi
say "packaging va_aot.framework"
cp "$GEN/libaot.dylib" "$GEN/libva_aot.dylib"
make_framework "$GEN/libva_aot.dylib" "$Q/Frameworks"
# what this cache was bound to (make_xcframeworks.sh checks it)
shasum "$QBIN" | awk '{print $1}' > "$GEN/bound-qemu.sha1"
say "done: $Q/Frameworks/va_aot.framework ($(du -h "$Q/Frameworks/va_aot.framework/va_aot" | cut -f1))"
