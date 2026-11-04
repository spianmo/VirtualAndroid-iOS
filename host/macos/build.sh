#!/bin/zsh
# Build the macOS development platform plugin and the guest probe.
#   host/macos/build.sh            -> $OUT/libva_host_macos.dylib
#   host/macos/build.sh guest      -> $OUT/va_pipe_probe (Android arm64, NDK)
# OUT defaults to engine/build-macos-services/host-macos.
set -e
HERE=${0:A:h}
ROOT=${HERE:h:h}
OUT=${OUT:-$ROOT/engine/build-macos-services/host-macos}
mkdir -p $OUT
if [[ $1 == guest ]]; then
  NDK=${ANDROID_NDK:-$(ls -d $HOME/Library/Android/sdk/ndk/* | sort -V | tail -1)}
  CC=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android33-clang
  $CC -O2 -Wall -Wextra -static -o $OUT/va_pipe_probe $HERE/guest/va_pipe_probe.c
  echo $OUT/va_pipe_probe
  exit 0
fi
cc -std=gnu11 -O2 -g -Wall -Wextra -Wno-unused-parameter -fvisibility=hidden \
   -dynamiclib -I$HERE/include -I$ROOT/host/include \
   -framework CoreFoundation -framework IOKit \
   -o $OUT/libva_host_macos.dylib $HERE/va_host_macos.c
echo $OUT/libva_host_macos.dylib
