#!/bin/bash
# Syntax-check ranchu_gfx.c against the real QEMU tree (engine/qemu + engine/build-macos).
set -euo pipefail
GFX="$(cd "$(dirname "$0")/.." && pwd)"
ENG="$(cd "$GFX/../engine" && pwd)"
GLIB_CFLAGS="$(pkg-config --cflags glib-2.0)"
cd "$ENG/build-macos"
cc -fsyntax-only -Wall -std=gnu11 -Wmissing-prototypes -Wstrict-prototypes -Wold-style-definition -Wundef \
  $GLIB_CFLAGS -I"$ENG/../host/include" \
  -iquote . -iquote "$ENG/qemu" -iquote "$ENG/qemu/include" \
  -iquote "$ENG/qemu/host/include/aarch64" -iquote "$ENG/qemu/host/include/generic" \
  -D_GNU_SOURCE -D_DARWIN_C_SOURCE -I"$GFX/include" -I"$GFX/integration" \
  "$GFX/integration/ranchu_gfx.c"
echo "ranchu_gfx.c: syntax OK"
