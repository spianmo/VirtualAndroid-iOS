#!/bin/zsh
# Compiles the platform-independent app sources with swiftc on macOS and runs
# app/Tests/PureLogicTests.swift: bootconfig byte-identical to
# tools/make_initrd.py, display rotation/touch mapping, QEMU argv, keymap.
set -euo pipefail
ROOT=${0:A:h:h:h}
APP=$ROOT/app/VirtualAndroid
IMG=${IMG:-$ROOT/images/android-33/arm64-v8a}
TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT
# Minimal stand-ins for the C types the pure files reference.
cat > $TMP/Shims.swift <<'SWIFT'
enum EngineError: Error { case imageMissing(String), startFailed(String) }
SWIFT
cp $ROOT/app/Tests/PureLogicTests.swift $TMP/main.swift   # top-level code must live in main.swift
swiftc -O -o $TMP/pure $TMP/main.swift $TMP/Shims.swift \
  $APP/VM/BootConfig.swift $APP/VM/QemuArguments.swift $APP/Display/DisplayGeometry.swift $APP/Input/LinuxKeymap.swift
python3 -I $ROOT/tools/make_initrd.py $IMG/ramdisk.img $TMP/initrd.py androidboot.qemu.skin=1080x2340
$TMP/pure $IMG/ramdisk.img $TMP/initrd.py
