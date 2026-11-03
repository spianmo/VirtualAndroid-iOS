#!/bin/zsh
set -e
SRC=/Users/finger/Projects/TeamhelperProjects/VirtualAndroid/engine/qemu-aot
COMMON=(--target-list=aarch64-softmmu --enable-slirp --disable-docs --disable-werror --enable-fdt=internal --disable-spice --disable-gtk --disable-sdl --disable-hvf --disable-cocoa)
cd /Users/finger/Projects/TeamhelperProjects/VirtualAndroid/engine/build-macos-aot-jit
[[ -f build.ninja ]] || $SRC/configure $COMMON
ninja -j6 qemu-system-aarch64
cd /Users/finger/Projects/TeamhelperProjects/VirtualAndroid/engine/build-macos-aot-tcti
[[ -f build.ninja ]] || $SRC/configure $COMMON --enable-tcg-threaded-interpreter
ninja -j6 qemu-system-aarch64
echo BUILD-DONE
