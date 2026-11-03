#!/bin/bash
# Cross-compile QEMU (aarch64-softmmu only) for iOS / iOS Simulator as a
# shared library (UTM's --enable-shared-lib) and wrap it as a framework.
#
#   engine/scripts/ios/build_qemu.sh [-p ios|ios_simulator] [-a arm64] [-b tcg|tcti]
#                                    [-s QEMU_SRC] [-c] [-x] [--reconfigure]
#
#   -p   platform (default ios_simulator)
#   -b   TCG backend: tcg (JIT, default on the simulator) or tcti (UTM's
#        threaded interpreter, no JIT; default on device)
#   -s   QEMU source tree (default engine/qemu; e.g. engine/qemu-ios)
#   -c   clean this platform/backend's QEMU build first
#   -x   debug build (keeps debug info, -O0)
#   --reconfigure  re-run configure even if the build dir is configured
#
# Requires build_deps.sh for the same platform.  Output:
#   engine/build-ios/<platform>-<arch>/qemu-<backend>/
#       build/                      meson/ninja build dir
#       install/                    make install (lib, bin, include)
#       Frameworks/qemu-aarch64-softmmu.framework
#       bin/va-qemu-launch          dlopen launcher (CLI test harness)
set -e
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PLATFORM=ios_simulator
ARCH=arm64
BACKEND=
QEMU_SRC=
CLEAN=
RECONF=
while [ $# -gt 0 ]; do
    case "$1" in
    -p ) PLATFORM="$2"; shift ;;
    -a ) ARCH="$2"; shift ;;
    -b ) BACKEND="$2"; shift ;;
    -s ) QEMU_SRC="$2"; shift ;;
    -c ) CLEAN=y ;;
    -x ) DEBUG=1 ;;
    --reconfigure ) RECONF=y ;;
    -h | --help ) sed -n 2,22p "$0"; exit 0 ;;
    * ) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
export PLATFORM ARCH DEBUG
. "$SELF_DIR/common.sh"

if [ -z "$BACKEND" ]; then
    if [ "$PLATFORM" = ios_simulator ]; then BACKEND=tcg; else BACKEND=tcti; fi
fi
QEMU_SRC="$(cd "${QEMU_SRC:-$ROOT/engine/qemu}" && pwd)"
Q="$PLAT_DIR/qemu-$BACKEND"
BUILD="$Q/build"
INSTALL="$Q/install"
QFW="$Q/Frameworks"

if [ -n "$(git -C "$QEMU_SRC" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    say "WARNING: $QEMU_SRC has uncommitted changes (another agent may be mid-edit);"
    say "         use -s engine/qemu-ios (branch ios = master + iOS fixes) for a stable tree"
fi
# --disable-download needs the wrap subprojects checked out (git-ignored, so a
# fresh worktree lacks them): borrow them from engine/qemu when possible.
for sp in dtc keycodemapdb berkeley-softfloat-3 berkeley-testfloat-3; do
    if [ ! -d "$QEMU_SRC/subprojects/$sp" ] && [ -d "$ROOT/engine/qemu/subprojects/$sp" ]; then
        say "copying subprojects/$sp from engine/qemu"
        rsync -a "$ROOT/engine/qemu/subprojects/$sp" "$QEMU_SRC/subprojects/"
    fi
done
[ -f "$PREFIX/lib/pkgconfig/glib-2.0.pc" ] || die "dependencies missing: run build_deps.sh -p $PLATFORM first"
[ -x "$QEMU_SRC/configure" ] || die "no QEMU source at $QEMU_SRC"

[ -n "$CLEAN" ] && rm -rf "$Q"
mkdir -p "$BUILD" "$INSTALL" "$QFW" "$Q/bin"

case "$BACKEND" in
tcg )
    BACKEND_FLAGS=""
    ;;
tcti )
    # same extra flags UTM uses for its -tci platforms
    BACKEND_FLAGS="--enable-tcg-threaded-interpreter --extra-cflags=-Wno-unused-command-line-argument
        --extra-ldflags=-Wl,-no_deduplicate --extra-ldflags=-Wl,-random_uuid --extra-ldflags=-Wl,-no_compact_unwind"
    ;;
* ) die "backend must be tcg or tcti" ;;
esac
if [ -z "$DEBUG" ]; then DBG_FLAGS="--disable-debug-info"; else DBG_FLAGS="--enable-debug"; fi

# Only what the Android/ranchu board needs: no spice, usb, tpm, gl, audio
# backends, block network drivers, tools or firmware blobs.
CONFIG_FLAGS="--target-list=aarch64-softmmu --enable-shared-lib --disable-download
    --disable-docs --disable-werror --disable-tools --disable-guest-agent --disable-install-blobs
    --disable-cocoa --disable-sdl --disable-gtk --disable-vte --disable-curses --disable-opengl
    --disable-spice --disable-spice-protocol --disable-usb-redir --disable-libusb --disable-smartcard
    --disable-virglrenderer --disable-rutabaga-gfx --disable-tpm --disable-coreaudio
    --disable-hvf --disable-hvf-private --disable-plugins --disable-capstone
    --disable-gnutls --disable-nettle --disable-gcrypt --disable-curl --disable-libssh
    --disable-bzip2 --disable-lzfse --disable-lzo --disable-snappy --disable-png
    --disable-vnc-jpeg --disable-vnc-sasl --disable-dbus-display --disable-pvg
    --disable-slirp-smbd --enable-slirp --enable-zstd --enable-pixman --enable-fdt=internal
    --enable-ucontext --with-coroutine=libucontext"

# meson cannot tell iOS from macOS binaries (both system 'darwin') and tries
# to run its sanity checks; configure on branch `ios` (engine/qemu-ios) emits
# needs_exe_wrapper=true for TARGET_OS_IPHONE.  For trees without that fix,
# run a patched copy of configure with $0 pointing at the original.
run_configure () {
    if grep -q darwin_embedded "$QEMU_SRC/configure"; then
        "$QEMU_SRC/configure" "$@"
    else
        say "source lacks the iOS configure fix (qemu branch ios); patching it on the fly"
        /bin/sh -c "$(awk '{print} /^  echo "\[properties\]" >> \$cross$/ {print "  echo \"needs_exe_wrapper = true\" >> $cross"}' \
            "$QEMU_SRC/configure")" "$QEMU_SRC/configure" "$@"
    fi
}

if [ -n "$RECONF" ] || [ ! -f "$BUILD/build.ninja" ] || [ "$(cat "$Q/source" 2>/dev/null)" != "$QEMU_SRC" ]; then
    say "configuring QEMU ($BACKEND) from $QEMU_SRC"
    ( cd "$BUILD"
      run_configure --prefix="$INSTALL" --cross-prefix="" --cpu="$CPU" \
          --cc="$CC" --cxx="$CXX" --objcc="$OBJCC" --host-cc=/usr/bin/cc \
          --python="$(command -v python3)" \
          $CONFIG_FLAGS $BACKEND_FLAGS $DBG_FLAGS )
    echo "$QEMU_SRC" > "$Q/source"
fi

say "building QEMU ($BACKEND)"
ninja -C "$BUILD" -j "$NCPU"
ninja -C "$BUILD" install >/dev/null

LIB="$INSTALL/lib/libqemu-aarch64-softmmu.dylib"
[ -f "$LIB" ] || die "missing $LIB"
say "packaging qemu-aarch64-softmmu.framework"
make_framework "$LIB" "$QFW" "$FRAMEWORKS"

# Launcher: tiny executable that dlopens the framework and runs
# qemu_init / qemu_main_loop / qemu_cleanup on a pthread, exactly as the app
# will.  rpath covers the build tree; in the app both live in Frameworks/.
say "building va-qemu-launch"
$CC -isysroot "$SDKROOT" -O2 -Wall -o "$Q/bin/va-qemu-launch" "$SELF_DIR/tools/va_qemu_launch.c" \
    -framework CoreFoundation -Wl,-rpath,"$QFW" -Wl,-rpath,"$FRAMEWORKS" -Wl,-rpath,@executable_path/../Frameworks
codesign --force --sign - --timestamp=none "$Q/bin/va-qemu-launch" >/dev/null 2>&1
say "done: $QFW/qemu-aarch64-softmmu.framework"
