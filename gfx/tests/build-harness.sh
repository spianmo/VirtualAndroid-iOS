#!/bin/bash
# Build the standalone libva_gfx harness. usage: build-harness.sh [macos|ios-sim]
set -euo pipefail
GFX="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$GFX/.." && pwd)"
PLATFORM="${1:-macos}"
OUT="$GFX/build-$PLATFORM/tests"
mkdir -p "$OUT"
case "$PLATFORM" in
  macos)   SDK=macosx;          TARGET=arm64-apple-macos13.0 ;;
  ios-sim) SDK=iphonesimulator; TARGET=arm64-apple-ios15.0-simulator ;;
esac
"$(xcrun --sdk $SDK -f clang)" -target $TARGET -isysroot "$(xcrun --sdk $SDK --show-sdk-path)" \
  -O1 -g -std=c11 -Wall -Wno-unused-function \
  -I"$GFX/include" -I"$ROOT/engine/qemu/include" \
  "$GFX/tests/va_gfx_harness.c" -o "$OUT/va_gfx_harness" \
  -framework CoreFoundation -framework CoreGraphics -framework IOSurface -framework ImageIO
codesign -f -s - "$OUT/va_gfx_harness" 2>/dev/null
echo "built $OUT/va_gfx_harness"
