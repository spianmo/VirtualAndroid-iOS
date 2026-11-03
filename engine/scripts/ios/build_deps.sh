#!/bin/bash
# Cross-compile the minimal QEMU dependency set for iOS / iOS Simulator.
#
#   engine/scripts/ios/build_deps.sh [-p ios|ios_simulator] [-a arm64] [-c] [-x] [--only PKG]
#
#   -p   platform (default ios_simulator)
#   -a   architecture (default arm64)
#   -c   clean: drop this platform's src/sysroot/Frameworks/stamps first
#   -x   debug build
#   --only PKG   rebuild only one package (removes its stamp)
#
# Packages (in order): libucontext libffi libiconv gettext(libintl only)
# glib pixman zstd libslirp.  Sources come from third_party/dl, patches from
# third_party/UTM/patches (recipe follows UTM scripts/build_dependencies.sh,
# minus spice/gstreamer/usb/tpm/gpu).  Each step is stamped, so re-running
# only builds what is missing.  Output: engine/build-ios/<platform>-<arch>/
# {sysroot,Frameworks}.
set -e
PLATFORM=ios_simulator
ARCH=arm64
CLEAN=
ONLY=
while [ $# -gt 0 ]; do
    case "$1" in
    -p ) PLATFORM="$2"; shift ;;
    -a ) ARCH="$2"; shift ;;
    -c ) CLEAN=y ;;
    -x ) DEBUG=1 ;;
    --only ) ONLY="$2"; shift ;;
    -h | --help ) sed -n 2,17p "$0"; exit 0 ;;
    * ) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
export PLATFORM ARCH DEBUG
if [ -n "$CLEAN" ]; then
    _out="$(cd "$(dirname "$0")/../../.." && pwd)/engine/build-ios/$PLATFORM-$ARCH"
    rm -rf "$_out/src" "$_out/sysroot" "$_out/Frameworks" "$_out/stamps"
fi
. "$(dirname "$0")/common.sh"

[ -n "$ONLY" ] && rm -f "$STAMPS/$ONLY.done"

# unpack <tarball> <dirname>: fresh copy in $SRCROOT, UTM patch applied
unpack () {
    tarball="$1"; name="$2"
    rm -rf "$SRCROOT/$name"
    say "unpacking $name"
    tar -xf "$DL/$tarball" -C "$SRCROOT"
    if [ -f "$UTM_PATCHES/$name.patch" ]; then
        say "patching $name"
        patch -d "$SRCROOT/$name" -p1 < "$UTM_PATCHES/$name.patch" >/dev/null
    fi
}

autotools_build () {
    dir="$1"; shift
    ( cd "$dir"
      ./configure --prefix="$PREFIX" --host="$CHOST" "$@"
      make -j"$NCPU"
      make install )
}

meson_cross_build () {
    system="$1"; srcdir="$2"; shift 2
    cross="$PLAT_DIR/meson-$system.cross"
    generate_meson_cross "$cross" "$system"
    ( cd "$srcdir"
      rm -rf va_build
      meson setup va_build --prefix="$PREFIX" --libdir=lib --buildtype="$MESON_BUILDTYPE" \
          --cross-file "$cross" "$@"
      meson compile -C va_build -j "$NCPU"
      meson install -C va_build )
}

step () {
    name="$1"; shift
    if stamp_done "$name"; then
        say "$name: already built"
        return
    fi
    [ -z "$ONLY" ] || [ "$ONLY" = "$name" ] || { say "$name: skipped (--only $ONLY)"; return; }
    say "$name: building"
    "$@"
    stamp_set "$name"
}

build_libucontext () {
    rm -rf "$SRCROOT/libucontext"
    rsync -a --exclude .git "$DL/libucontext/" "$SRCROOT/libucontext/"
    meson_cross_build ios "$SRCROOT/libucontext" -Ddefault_library=static -Dfreestanding=true
}

build_libffi () {
    unpack libffi-3.5.0.tar.gz libffi-3.5.0
    autotools_build "$SRCROOT/libffi-3.5.0" --disable-docs --disable-multi-os-directory
}

build_libiconv () {
    unpack libiconv-1.16.tar.gz libiconv-1.16
    autotools_build "$SRCROOT/libiconv-1.16" --disable-static
}

# Only gettext-runtime: libintl is all glib needs.  The UTM gettext patch
# touches libtextstyle/gettext-tools, which we do not build.
build_gettext () {
    rm -rf "$SRCROOT/gettext-0.22.5"
    say "unpacking gettext-0.22.5"
    tar -xf "$DL/gettext-0.22.5.tar.gz" -C "$SRCROOT"
    gl_cv_onwards_func_strchrnul=future \
    autotools_build "$SRCROOT/gettext-0.22.5/gettext-runtime" \
        --disable-java --disable-csharp --disable-libasprintf --disable-static \
        --disable-openmp --disable-curses --with-included-gettext \
        --with-libiconv-prefix="$PREFIX" --without-emacs --disable-c++
}

build_glib () {
    unpack glib-2.83.0.tar.xz glib-2.83.0
    # pcre2 comes from glib's wrap (downloaded by meson into the glib tree)
    meson_cross_build ios "$SRCROOT/glib-2.83.0" -Dtests=false -Ddtrace=disabled \
        -Dsystemtap=disabled -Dsysprof=disabled -Dman-pages=disabled -Ddocumentation=false \
        -Dintrospection=disabled -Dlibmount=disabled -Dselinux=disabled -Dxattr=false \
        -Dnls=enabled -Dglib_debug=disabled -Dinstalled_tests=false
}

build_pixman () {
    unpack pixman-0.38.0.tar.gz pixman-0.38.0
    autotools_build "$SRCROOT/pixman-0.38.0" --disable-static --disable-gtk --disable-libpng
}

build_zstd () {
    unpack zstd-1.5.2.tar.gz zstd-1.5.2
    meson_cross_build ios "$SRCROOT/zstd-1.5.2/build/meson" -Dbin_programs=false \
        -Dbin_contrib=false -Dbin_tests=false -Dzlib=disabled -Dlzma=disabled -Dlz4=disabled -Ddefault_library=shared
}

build_libslirp () {
    unpack libslirp-v4.9.1.tar.gz libslirp-v4.9.1
    meson_cross_build darwin "$SRCROOT/libslirp-v4.9.1" -Ddefault_library=shared
}

# Wrap every real dylib of the sysroot into Frameworks/<name>.framework
package_frameworks () {
    rm -rf "$FRAMEWORKS"; mkdir -p "$FRAMEWORKS"
    # first pass creates every framework so that cross references resolve
    # girepository is built by glib unconditionally but nothing here needs it
    for f in $(find "$PREFIX/lib" -maxdepth 1 -type f -name '*.dylib' ! -name 'libgirepository*' | sort); do
        make_framework "$f" "$FRAMEWORKS"
    done
    for f in "$FRAMEWORKS"/*.framework; do
        n="$(basename "$f" .framework)"
        fixup_imports "$f/$n" "$FRAMEWORKS"
        codesign --force --sign - --timestamp=none "$f/$n" >/dev/null 2>&1
    done
    say "frameworks:"; ls "$FRAMEWORKS"
}

write_pkg_config_wrapper
say "SDK $SDK $SDKVERSION, target $CFLAGS_TARGET, prefix $PREFIX, jobs $NCPU"
step libucontext build_libucontext
step libffi build_libffi
step libiconv build_libiconv
step gettext build_gettext
step glib build_glib
step pixman build_pixman
step zstd build_zstd
step libslirp build_libslirp
package_frameworks
say "done"
