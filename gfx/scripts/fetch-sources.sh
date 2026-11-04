#!/bin/bash
# Fetch pinned gfxstream/aemu sources (shallow) into gfx/src and apply our patches.
set -euo pipefail
GFX="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$GFX/src"
fetch() { # name url sha
  local dir="$GFX/src/$1"
  if [ ! -d "$dir/.git" ]; then
    git init -q "$dir"
    git -C "$dir" remote add origin "$2"
  fi
  if ! git -C "$dir" cat-file -e "$3^{commit}" 2>/dev/null; then
    git -C "$dir" fetch --depth 1 origin "$3"
  fi
  git -C "$dir" checkout -q "$3"
}
GFXSTREAM_SHA=d047a57228332d995d36600792fa9ccc26cf8ae6   # 2025-03-26 main
AEMU_SHA=3c1ced8a369417db591eb7cd083af5bb2c317975        # 2025-03-26 main
fetch gfxstream https://android.googlesource.com/platform/hardware/google/gfxstream "$GFXSTREAM_SHA"
fetch aemu https://android.googlesource.com/platform/hardware/google/aemu "$AEMU_SHA"
# ANGLE: WebKit's ANGLE subset at UTM's pinned commit (sparse + shallow + blobless, ~0.2 GB).
WEBKIT_SHA=ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10
if [ ! -d "$GFX/src/webkit/Source/ThirdParty/ANGLE" ]; then
  git init -q "$GFX/src/webkit"
  git -C "$GFX/src/webkit" remote add origin https://github.com/utmapp/WebKit.git
  git -C "$GFX/src/webkit" config core.sparseCheckout true
  printf '/Source/ThirdParty/ANGLE/\n/Configurations/\n/Tools/ccache/\n' \
    > "$GFX/src/webkit/.git/info/sparse-checkout"
  git -C "$GFX/src/webkit" fetch --depth 1 --filter=blob:none origin "$WEBKIT_SHA"
  git -C "$GFX/src/webkit" checkout -q FETCH_HEAD
fi

# LZ4 (BSD-2) for the snapshot TextureSaver/Loader (only lib/lz4.{c,h}).
if [ ! -f "$GFX/src/lz4/lib/lz4.c" ]; then
  git init -q "$GFX/src/lz4"
  git -C "$GFX/src/lz4" remote add origin https://github.com/lz4/lz4.git
  git -C "$GFX/src/lz4" config core.sparseCheckout true
  printf '/lib/lz4.c\n/lib/lz4.h\n/lib/LICENSE\n' > "$GFX/src/lz4/.git/info/sparse-checkout"
  git -C "$GFX/src/lz4" fetch --depth 1 --filter=blob:none origin tag v1.10.0
  git -C "$GFX/src/lz4" checkout -q v1.10.0
fi

for p in gfxstream:gfxstream aemu:aemu angle:webkit; do
  name=${p%%:*}; dir=${p#*:}
  if [ -f "$GFX/patches/$name.patch" ]; then
    if git -C "$GFX/src/$dir" apply --check "$GFX/patches/$name.patch" 2>/dev/null; then
      git -C "$GFX/src/$dir" apply "$GFX/patches/$name.patch"
      echo "applied $name.patch"
    else
      echo "$name.patch already applied or does not apply cleanly; skipping"
    fi
  fi
done
