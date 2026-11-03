#!/bin/bash
# Build the standalone libva_gfx harness (macOS host).
set -euo pipefail
GFX="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$GFX/.." && pwd)"
OUT="$GFX/build-macos/tests"
mkdir -p "$OUT"
clang -O1 -g -std=c11 -Wall -Wno-unused-function \
  -I"$GFX/include" -I"$ROOT/engine/qemu/include" \
  "$GFX/tests/va_gfx_harness.c" -o "$OUT/va_gfx_harness" \
  -framework CoreFoundation -framework CoreGraphics -framework IOSurface -framework ImageIO
echo "built $OUT/va_gfx_harness"
