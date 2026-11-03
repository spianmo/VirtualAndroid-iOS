#!/bin/zsh
# Boot the Android 13 image in our QEMU on macOS (HVF) for development.
#
#   tools/run-macos.sh [--fresh] [--tcg] [--machine virt|ranchu] [--display] [--timeout SECS]
#                      [--name RUN] [--adb-port PORT] [--trace PATTERN]... [--console]
#                      [--gfx-lib PATH|none] [--screenshot-dir DIR] [-- extra qemu args]
#
# --machine ranchu (the Android emulator board: virt + goldfish pipe/sync/battery/events,
# virtio multitouch + "qwerty2" keyboard) also enables the android_pipe_connect trace, so
# every pipe service the guest opens is logged to qemu.out. --trace adds more QEMU trace
# event patterns (e.g. --trace 'goldfish_*'). --console makes the kernel console (where
# the image runs a root-capable 'console' shell) a unix socket, $RUN/console.sock, still
# logged to serial.log; talk to it with e.g. `nc -U engine/run/<name>/console.sock`.
# ranchu loads the host renderer from --gfx-lib (default gfx/build-macos/dist/libva_gfx.dylib
# if built; "none" = no graphics). --screenshot-dir DIR writes guest frames to DIR/latest.png
# (+ the first few as frame-N.png; VA_DUMP_EVERY=N sets the interval, default 30 frames).
#   QEMU=/path/to/qemu-system-aarch64 overrides the binary (each agent uses its own build dir).
#
# Per-run state lives in engine/run/<name> (default "dev"): writable disks,
# serial.log (kernel console), logcat.log (androidboot.logcat on hvc1).
set -e
ROOT=${0:A:h:h}
IMG=$ROOT/images/android-33/arm64-v8a
QEMU=${QEMU:-$ROOT/engine/build-macos/qemu-system-aarch64}
QEMU_IMG=${QEMU_IMG:-$ROOT/engine/build-macos/qemu-img}
E2=$(brew --prefix e2fsprogs)/sbin
NAME=dev FRESH=0 ACCEL=hvf MACHINE=virt DISPLAY_OPT=(-display none) TIMEOUT=0 ADB_PORT=5555
TRACES=() CONSOLE=0 GFX_LIB=auto SHOT_DIR=
while (( $# )); do
  case $1 in
    --fresh) FRESH=1 ;;
    --tcg) ACCEL=tcg ;;
    --machine) MACHINE=$2; shift ;;
    --name) NAME=$2; shift ;;
    --display) DISPLAY_OPT=(-display cocoa) ;;
    --timeout) TIMEOUT=$2; shift ;;
    --adb-port) ADB_PORT=$2; shift ;;
    --trace) TRACES+=($2); shift ;;
    --console) CONSOLE=1 ;;
    --gfx-lib) GFX_LIB=$2; shift ;;
    --screenshot-dir) SHOT_DIR=${2:A}; shift ;;
    --) shift; break ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
RUN=$ROOT/engine/run/$NAME
mkdir -p $RUN
if (( FRESH )) || [[ ! -f $RUN/userdata.img ]]; then
  rm -f $RUN/userdata.img $RUN/encryptionkey.img $RUN/cache.img
  cp $IMG/encryptionkey.img $RUN/
  mkfile -n 6g $RUN/userdata.img && $E2/mke2fs -q -F -t ext4 -b 4096 -L data $RUN/userdata.img
  mkfile -n 64m $RUN/cache.img && $E2/mke2fs -q -F -t ext4 -b 4096 -L cache $RUN/cache.img
fi
# Rebuild when the bootconfig defaults change.
if [[ ! -f $RUN/initrd || $ROOT/tools/make_initrd.py -nt $RUN/initrd ]]; then
  python3 -I $ROOT/tools/make_initrd.py $IMG/ramdisk.img $RUN/initrd
fi
rm -f $RUN/serial.log $RUN/logcat.log $RUN/hvc0.log $RUN/console.sock
SERIAL_OPT=(-serial file:$RUN/serial.log)
if (( CONSOLE )); then
  SERIAL_OPT=(-chardev socket,id=ser0,path=$RUN/console.sock,server=on,wait=off,logfile=$RUN/serial.log
              -serial chardev:ser0)
fi

if [[ $MACHINE == ranchu* ]]; then
  TRACES=(android_pipe_connect $TRACES)
  [[ $GFX_LIB == auto ]] && GFX_LIB=$ROOT/gfx/build-macos/dist/libva_gfx.dylib
  [[ $GFX_LIB == auto || ! -f $GFX_LIB ]] && [[ $GFX_LIB != none ]] && {
    echo "warning: no libva_gfx at $GFX_LIB, booting without graphics" >&2; GFX_LIB=none; }
  if [[ $GFX_LIB == none ]]; then MACHINE=$MACHINE,gfx=off; else MACHINE=$MACHINE,gfx-lib=$GFX_LIB; fi
fi
[[ -n $SHOT_DIR ]] && export VA_DUMP_FRAMES=$SHOT_DIR
TRACE_OPT=()
for t in $TRACES; do TRACE_OPT+=(-trace "enable=$t"); done

if [[ $ACCEL == hvf ]]; then CPU=(-accel hvf -cpu host); else CPU=(-accel tcg,thread=multi,tb-size=1024 -cpu cortex-a76); fi

ARGS=(
  -M $MACHINE $CPU -smp 4 -m 2048 -nodefaults $DISPLAY_OPT
  $SERIAL_OPT -monitor unix:$RUN/monitor.sock,server,nowait
  -kernel $IMG/kernel-ranchu -initrd $RUN/initrd
  -append "8250.nr_uarts=1 no_timer_check console=ttyAMA0,38400 keep_bootcon earlyprintk=ttyAMA0 ndns=2 loop.max_part=7 printk.devkmsg=on bootconfig"
  # Order matters: it fixes the virtio-mmio addresses the image's fstab expects.
  -drive index=0,id=vendor,if=none,file=$IMG/vendor.img,read-only=on,format=raw -device virtio-blk-device,drive=vendor
  -drive index=1,id=encrypt,if=none,file=$RUN/encryptionkey.img,format=raw -device virtio-blk-device,drive=encrypt
  -drive index=2,id=userdata,if=none,file=$RUN/userdata.img,format=raw -device virtio-blk-device,drive=userdata
  -drive index=3,id=cache,if=none,file=$RUN/cache.img,format=raw -device virtio-blk-device,drive=cache
  -drive index=4,id=system,if=none,file=$IMG/system.img,read-only=on,format=raw -device virtio-blk-device,drive=system
  -netdev user,id=mynet,hostfwd=tcp:127.0.0.1:$ADB_PORT-:5555 -device virtio-net-device,netdev=mynet
  -device virtio-rng-device
  -chardev file,id=forhvc0,path=$RUN/hvc0.log -chardev file,id=forhvc1,path=$RUN/logcat.log
  -device virtio-serial-pci,ioeventfd=off -device virtconsole,chardev=forhvc0 -device virtconsole,chardev=forhvc1
  $TRACE_OPT
  "$@"
)
echo "run dir: $RUN"
if (( TIMEOUT > 0 )); then
  $QEMU $ARGS > $RUN/qemu.out 2>&1 &
  QPID=$!
  ( sleep $TIMEOUT; kill $QPID 2>/dev/null ) &
  wait $QPID || true
else
  exec $QEMU $ARGS
fi
