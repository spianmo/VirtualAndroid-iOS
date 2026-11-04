#!/bin/zsh
# Boot the Android 13 image in our QEMU on macOS (HVF) for development.
#
#   tools/run-macos.sh [--fresh] [--tcg] [--machine virt|ranchu] [--display] [--timeout SECS]
#                      [--name RUN] [--adb-port PORT] [--trace PATTERN]... [--console]
#                      [--gfx-lib PATH|none] [--screenshot-dir DIR] [--snapshot]
#                      [-- extra qemu args]
#
# --machine ranchu (the Android emulator board: virt + goldfish pipe/sync/battery/events,
# virtio multitouch + "qwerty2" keyboard) also enables the android_pipe_connect trace, so
# every pipe service the guest opens is logged to qemu.out. --trace adds more QEMU trace
# event patterns (e.g. --trace 'goldfish_*'). --console makes the kernel console (where
# the image runs a root-capable 'console' shell) a unix socket, $RUN/console.sock, still
# logged to serial.log; talk to it with e.g. `nc -U engine/run/<name>/console.sock` (the
# engine then leaves the console alone: no guest clock sync after a restore).
# ranchu loads the host renderer from --gfx-lib (default gfx/build-macos/dist/libva_gfx.dylib
# if built; "none" = no graphics). --screenshot-dir DIR writes guest frames to DIR/latest.png
# (+ the first few as frame-N.png; VA_DUMP_EVERY=N sets the interval, default 30 frames).
# ranchu also adds services' va-vsock-pci (adb on 127.0.0.1:PORT via vsock, pipe-port 5000);
# va-wifi-pci, the access point "AndroidWifi" the guest's wlan0 joins (own slirp net),
# va-bluetooth, the Bluetooth controller on the virtio-serial port "bluetooth", and
# virtio-sound-pci on the "va" audio backend (the platform's speaker and microphone).
# boot check: adb -s 127.0.0.1:PORT shell getprop sys.boot_completed
# VA_HOST_PLATFORM=<libva_host_macos.dylib> (host/macos/build.sh) loads the test platform.
# QMP is always on $RUN/qmp.sock.
# --snapshot (ranchu, docs/SNAPSHOT.md): guest RAM lives in $RUN/snapshot/ram.img
# (memory-backend-file, share=on) and the machine gets snapshot-dir=$RUN/snapshot. If that
# directory holds a clean snapshot matching this launch, QEMU starts with -incoming defer and
# tools/snapshot.py restore loads it (log: $RUN/restore.log); otherwise the snapshot is
# discarded and the guest cold-boots. Save with: tools/snapshot.py suspend --run $RUN [--quit]
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
TRACES=() CONSOLE=0 GFX_LIB=auto SHOT_DIR= SNAPSHOT=0
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
    --snapshot) SNAPSHOT=1 ;;
    --) shift; break ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
RUN=$ROOT/engine/run/$NAME
SNAP=$RUN/snapshot
mkdir -p $RUN
SNAPPY=(python3 -I $ROOT/tools/snapshot.py)
if (( FRESH )) || [[ ! -f $RUN/userdata.img ]]; then
  # New disks invalidate any snapshot.
  [[ -d $SNAP ]] && $SNAPPY discard --run $RUN
  rm -f $RUN/userdata.img $RUN/encryptionkey.img $RUN/cache.img
  cp $IMG/encryptionkey.img $RUN/
  mkfile -n 6g $RUN/userdata.img && $E2/mke2fs -q -F -t ext4 -b 4096 -L data $RUN/userdata.img
  mkfile -n 64m $RUN/cache.img && $E2/mke2fs -q -F -t ext4 -b 4096 -L cache $RUN/cache.img
fi
# Bootconfig overrides. The host adb key lets adbd accept this machine without a prompt.
INITRD_ARGS=()
[[ -f ~/.android/adbkey.pub ]] && INITRD_ARGS+=("androidboot.qemu.adb.pubkey=$(tr -d '\n' < ~/.android/adbkey.pub)")
# Rebuild when the bootconfig defaults or overrides change.
INITRD_STAMP="$(shasum $ROOT/tools/make_initrd.py $IMG/ramdisk.img | awk '{print $1}' | tr -d '\n') ${(j: :)INITRD_ARGS}"
if [[ ! -f $RUN/initrd || "$(cat $RUN/initrd.params 2>/dev/null)" != "$INITRD_STAMP" ]]; then
  python3 -I $ROOT/tools/make_initrd.py $IMG/ramdisk.img $RUN/initrd $INITRD_ARGS
  print -r -- "$INITRD_STAMP" > $RUN/initrd.params
fi
rm -f $RUN/serial.log $RUN/logcat.log $RUN/hvc0.log $RUN/console.sock
# Engine-owned console (ringbuf): the engine may type on it (guest clock sync after a
# snapshot restore, hw/android/guest_time.c); everything is still logged to serial.log.
SERIAL_OPT=(-chardev ringbuf,id=vaconsole,size=65536,logfile=$RUN/serial.log -serial chardev:vaconsole)
if (( CONSOLE )); then
  SERIAL_OPT=(-chardev socket,id=ser0,path=$RUN/console.sock,server=on,wait=off,logfile=$RUN/serial.log
              -serial chardev:ser0)
fi

NET_FWD=",hostfwd=tcp:127.0.0.1:$ADB_PORT-:5555" EXTRA_DEV=()
if [[ $MACHINE == ranchu* ]]; then
  TRACES=(android_pipe_connect $TRACES)
  # adbd (and clipboard etc. over pipe-port 5000) talk vsock: services' user-space vsock
  # device bridges adb to 127.0.0.1:$ADB_PORT, so slirp doesn't forward it.
  EXTRA_DEV=(-device va-vsock-pci,guest-cid=77,adb-port=$ADB_PORT,pipe-port=5000)
  # Wi-Fi: the guest's mac80211_hwsim radio talks to the engine's access point
  # ("AndroidWifi"), bridged to its own slirp network (as the emulator does).
  EXTRA_DEV+=(-netdev user,id=wifi0,dhcpstart=10.0.2.16 -device va-wifi-pci,netdev=wifi0)
  # Bluetooth: the engine's HCI controller on the virtio-serial port "bluetooth"
  # (the guest's bt_vhci_forwarder bridges it to /dev/vhci).
  EXTRA_DEV+=(-device va-bluetooth)
  # Audio: virtio-sound (the image's goldfish audio HAL plays/records on card 0) on the
  # engine's "va" backend, i.e. the platform's speaker/mic callbacks (VA_HOST_PLATFORM).
  EXTRA_DEV+=(-audiodev va,id=snd0,out.frequency=48000,in.frequency=48000,in.channels=1
              -device virtio-sound-pci,audiodev=snd0)
  NET_FWD=""
  [[ $GFX_LIB == auto ]] && GFX_LIB=$ROOT/gfx/build-macos/dist/libva_gfx.dylib
  [[ $GFX_LIB == auto || ! -f $GFX_LIB ]] && [[ $GFX_LIB != none ]] && {
    echo "warning: no libva_gfx at $GFX_LIB, booting without graphics" >&2; GFX_LIB=none; }
  if [[ $GFX_LIB == none ]]; then MACHINE=$MACHINE,gfx=off; else MACHINE=$MACHINE,gfx-lib=$GFX_LIB; fi
fi
[[ -n $SHOT_DIR ]] && export VA_DUMP_FRAMES=$SHOT_DIR
MEM_OPT=(-m 2048)
if (( SNAPSHOT )); then
  [[ $MACHINE == ranchu* ]] || { echo "--snapshot needs --machine ranchu" >&2; exit 2; }
  mkdir -p $SNAP
  MACHINE=$MACHINE,snapshot-dir=$SNAP
  MEM_OPT=(-m 2048 -object memory-backend-file,id=ram0,size=2G,mem-path=$SNAP/ram.img,share=on
           -machine memory-backend=ram0)
fi
TRACE_OPT=()
for t in $TRACES; do TRACE_OPT+=(-trace "enable=$t"); done

if [[ $ACCEL == hvf ]]; then CPU=(-accel hvf -cpu host); else CPU=(-accel tcg,thread=multi,tb-size=1024 -cpu cortex-a76); fi

ARGS=(
  -M $MACHINE $CPU -smp 4 $MEM_OPT -nodefaults $DISPLAY_OPT
  $SERIAL_OPT -monitor unix:$RUN/monitor.sock,server,nowait -qmp unix:$RUN/qmp.sock,server=on,wait=off
  -kernel $IMG/kernel-ranchu -initrd $RUN/initrd
  -append "8250.nr_uarts=1 no_timer_check console=ttyAMA0,38400 keep_bootcon earlyprintk=ttyAMA0 ndns=2 loop.max_part=7 loop.max_loop=64 printk.devkmsg=on bootconfig mac80211_hwsim.radios=0"
  # Order matters: it fixes the virtio-mmio addresses the image's fstab expects.
  -drive index=0,id=vendor,if=none,file=$IMG/vendor.img,read-only=on,format=raw -device virtio-blk-device,drive=vendor
  -drive index=1,id=encrypt,if=none,file=$RUN/encryptionkey.img,format=raw -device virtio-blk-device,drive=encrypt
  -drive index=2,id=userdata,if=none,file=$RUN/userdata.img,format=raw -device virtio-blk-device,drive=userdata
  -drive index=3,id=cache,if=none,file=$RUN/cache.img,format=raw -device virtio-blk-device,drive=cache
  -drive index=4,id=system,if=none,file=$IMG/system.img,read-only=on,format=raw -device virtio-blk-device,drive=system
  -netdev user,id=mynet$NET_FWD -device virtio-net-device,netdev=mynet
  -device virtio-rng-device
  -chardev file,id=forhvc0,path=$RUN/hvc0.log -chardev file,id=forhvc1,path=$RUN/logcat.log
  -device virtio-serial-pci,ioeventfd=off -device virtconsole,chardev=forhvc0 -device virtconsole,chardev=forhvc1
  $EXTRA_DEV
  $TRACE_OPT
  "$@"
)
echo "run dir: $RUN"
RESTORE=0
if (( SNAPSHOT )); then
  # What a snapshot must match: engine, renderer, image files, cold-boot argv.
  $SNAPPY launch --run $RUN --qemu $QEMU --gfx "$GFX_LIB" \
    --images $IMG/kernel-ranchu $RUN/initrd $IMG/vendor.img $IMG/system.img $IMG/ramdisk.img -- $ARGS
  if $SNAPPY check --run $RUN; then
    RESTORE=1
    echo "restoring snapshot from $SNAP"
  else
    $SNAPPY discard --run $RUN
  fi
fi
rm -f $RUN/qmp.sock
zmodload zsh/datetime
T0=$EPOCHREALTIME
if (( RESTORE )); then
  ARGS+=(-incoming defer)
  RESTORE_OPT=(--run $RUN --t0 $T0 --adb-port $ADB_PORT)
  [[ -n $SHOT_DIR ]] && RESTORE_OPT+=(--frame-dir $SHOT_DIR)
  ( $SNAPPY restore $RESTORE_OPT > $RUN/restore.log 2>&1 ||
      echo "restore failed, see $RUN/restore.log" >&2 ) &
fi
if (( TIMEOUT > 0 )); then
  $QEMU $ARGS > $RUN/qemu.out 2>&1 &
  QPID=$!
  ( sleep $TIMEOUT; kill $QPID 2>/dev/null ) &
  wait $QPID || true
elif (( RESTORE )); then
  $QEMU $ARGS
else
  exec $QEMU $ARGS
fi
