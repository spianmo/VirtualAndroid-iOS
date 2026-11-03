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

for p in gfxstream aemu; do
  if [ -f "$GFX/patches/$p.patch" ]; then
    if git -C "$GFX/src/$p" apply --check "$GFX/patches/$p.patch" 2>/dev/null; then
      git -C "$GFX/src/$p" apply "$GFX/patches/$p.patch"
      echo "applied $p.patch"
    else
      echo "$p.patch already applied or does not apply cleanly; skipping"
    fi
  fi
done
