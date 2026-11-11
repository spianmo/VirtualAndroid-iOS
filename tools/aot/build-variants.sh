#!/bin/zsh
# Builds the macOS JIT and TCTI variants of the AOT engine tree (docs/AOT.md):
# engine/build-macos-aot-{jit,tcti} from engine/qemu-aot (or $SRC).
set -e
ROOT=${0:A:h:h:h}
SRC=${SRC:-$ROOT/engine/qemu-aot}
COMMON=(--target-list=aarch64-softmmu --enable-slirp --disable-docs --disable-werror --enable-fdt=internal --disable-spice --disable-gtk --disable-sdl --disable-hvf --disable-cocoa)
mkdir -p $ROOT/engine/build-macos-aot-jit $ROOT/engine/build-macos-aot-tcti
cd $ROOT/engine/build-macos-aot-jit
[[ -f build.ninja ]] || $SRC/configure $COMMON
ninja -j6 qemu-system-aarch64
cd $ROOT/engine/build-macos-aot-tcti
[[ -f build.ninja ]] || $SRC/configure $COMMON --enable-tcg-threaded-interpreter
ninja -j6 qemu-system-aarch64
echo BUILD-DONE
