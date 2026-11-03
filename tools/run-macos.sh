#!/bin/zsh
# Boot the Android 13 image in our QEMU on macOS (HVF) for development.
#
#   tools/run-macos.sh [--fresh] [--tcg] [--machine virt|ranchu] [--display] [--timeout SECS] [-- extra qemu args]
#
# Per-run state lives in engine/run/<name> (default "dev"): writable disks,
# serial.log (kernel console), logcat.log (androidboot.logcat on hvc1).
set -e
ROOT=${0:A:h:h}
IMG=$ROOT/images/android-33/arm64-v8a
QEMU=${QEMU:-$ROOT/engine/build-macos/qemu-system-aarch64}
QEMU_IMG=${QEMU_IMG:-$ROOT/engine/build-macos/qemu-img}
E2=$(brew --prefix e2fsprogs)/sbin
NAME=dev FRESH=0 ACCEL=hvf MACHINE=virt DISPLAY_OPT=(-display none) TIMEOUT=0
while (( $# )); do
  case $1 in
    --fresh) FRESH=1 ;;
    --tcg) ACCEL=tcg ;;
    --machine) MACHINE=$2; shift ;;
    --name) NAME=$2; shift ;;
    --display) DISPLAY_OPT=(-display cocoa) ;;
    --timeout) TIMEOUT=$2; shift ;;
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
[[ -f $RUN/initrd ]] || python3 -I $ROOT/tools/make_initrd.py $IMG/ramdisk.img $RUN/initrd
rm -f $RUN/serial.log $RUN/logcat.log $RUN/hvc0.log

if [[ $ACCEL == hvf ]]; then CPU=(-accel hvf -cpu host); else CPU=(-accel tcg,thread=multi,tb-size=1024 -cpu cortex-a76); fi

ARGS=(
  -M $MACHINE $CPU -smp 4 -m 2048 -nodefaults $DISPLAY_OPT
  -serial file:$RUN/serial.log -monitor unix:$RUN/monitor.sock,server,nowait
  -kernel $IMG/kernel-ranchu -initrd $RUN/initrd
  -append "8250.nr_uarts=1 no_timer_check console=ttyAMA0,38400 keep_bootcon earlyprintk=ttyAMA0 ndns=2 loop.max_part=7 printk.devkmsg=on bootconfig"
  # Order matters: it fixes the virtio-mmio addresses the image's fstab expects.
  -drive index=0,id=vendor,if=none,file=$IMG/vendor.img,read-only=on,format=raw -device virtio-blk-device,drive=vendor
  -drive index=1,id=encrypt,if=none,file=$RUN/encryptionkey.img,format=raw -device virtio-blk-device,drive=encrypt
  -drive index=2,id=userdata,if=none,file=$RUN/userdata.img,format=raw -device virtio-blk-device,drive=userdata
  -drive index=3,id=cache,if=none,file=$RUN/cache.img,format=raw -device virtio-blk-device,drive=cache
  -drive index=4,id=system,if=none,file=$IMG/system.img,read-only=on,format=raw -device virtio-blk-device,drive=system
  -netdev user,id=mynet,hostfwd=tcp:127.0.0.1:5555-:5555 -device virtio-net-device,netdev=mynet
  -device virtio-rng-device
  -chardev file,id=forhvc0,path=$RUN/hvc0.log -chardev file,id=forhvc1,path=$RUN/logcat.log
  -device virtio-serial-pci,ioeventfd=off -device virtconsole,chardev=forhvc0 -device virtconsole,chardev=forhvc1
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
