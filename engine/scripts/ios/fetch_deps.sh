#!/bin/bash
# Fetches what build_deps.sh needs on a fresh clone (both are git-ignored):
#   third_party/UTM   UTM at the commit our recipe follows (its patches/ are
#                     applied to the dependencies; patches/sources has the URLs)
#   third_party/dl    the dependency source tarballs and libucontext
#
#   engine/scripts/ios/fetch_deps.sh [-f]     -f: download again even if present
#
# Network access goes through the usual https_proxy/http_proxy variables.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
UTM_DIR="$ROOT/third_party/UTM"
UTM_REPO="https://github.com/utmapp/UTM.git"
UTM_COMMIT="ebce1808d7507ac03bd43af9d48f2c2e64071e91"
DL="$ROOT/third_party/dl"
FORCE=
[ "${1:-}" = "-f" ] && FORCE=y

say () { printf '\033[0;32m[fetch_deps] %s\033[0m\n' "$*"; }

if [ ! -d "$UTM_DIR/.git" ]; then
    say "cloning UTM into third_party/UTM"
    git clone --filter=blob:none --no-checkout "$UTM_REPO" "$UTM_DIR"
fi
if [ "$(git -C "$UTM_DIR" rev-parse HEAD 2>/dev/null)" != "$UTM_COMMIT" ]; then
    say "checking out UTM $UTM_COMMIT"
    git -C "$UTM_DIR" fetch --quiet origin "$UTM_COMMIT" 2>/dev/null || true
    git -C "$UTM_DIR" checkout --quiet "$UTM_COMMIT"
fi

# URLs and the libucontext pin come from UTM itself.
# shellcheck disable=SC1091
. "$UTM_DIR/patches/sources"

mkdir -p "$DL"
for url in "$FFI_SRC" "$ICONV_SRC" "$GETTEXT_SRC" "$GLIB_SRC" "$PIXMAN_SRC" "$ZSTD_SRC" "$SLIRP_SRC"; do
    f="$DL/$(basename "$url")"
    if [ -n "$FORCE" ] || [ ! -s "$f" ]; then
        say "downloading $(basename "$url")"
        curl -fL --retry 3 -o "$f.part" "$url"
        mv "$f.part" "$f"
    fi
done

if [ ! -d "$DL/libucontext/.git" ]; then
    say "cloning libucontext"
    git clone --quiet "$LIBUCONTEXT_REPO" "$DL/libucontext"
fi
git -C "$DL/libucontext" checkout --quiet "$LIBUCONTEXT_COMMIT"
say "done: third_party/UTM @ ${UTM_COMMIT:0:7}, sources in third_party/dl"
