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
