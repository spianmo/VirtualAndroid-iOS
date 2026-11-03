#!/bin/zsh
# Boot the Android 13 image headless inside the iOS Simulator, without the app:
# va-qemu-launch (simulator executable) dlopens qemu-aarch64-softmmu.framework
# and is started with `xcrun simctl spawn`.  Same machine/disk arguments as
# tools/run-macos.sh (with -accel tcg).
#
#   engine/scripts/ios/run_sim.sh [-b tcg|tcti] [--timeout SECS] [--fresh] [--name RUN]
#                                 [--device UDID] [--machine virt|ranchu] [--until MILESTONE]
#                                 [--adb-port PORT] [--gfx-lib PATH|none] [--screenshot-dir DIR]
#                                 [--keep] [-- extra qemu args]
#
# --until stops QEMU (monitor "quit") once a milestone is seen, e.g.
#   --until zygote   (default: run until sys.boot_completed=1 or the timeout)
# --keep    leave the VM running after the milestone (stop it with
#           `print quit | nc -U <run>/monitor.sock`)
# ranchu (default machine) mirrors tools/run-macos.sh --machine ranchu: va-vsock-pci
# with the adb bridge on 127.0.0.1:PORT (the simulator shares the Mac's network
# stack, so `adb connect 127.0.0.1:PORT` works from macOS), pipe-port 5000, the
# host adb key in bootconfig, and libva_gfx from gfx/build-ios-sim/dist
# (va_gfx.framework + GLESv2/MoltenVK next to it). --screenshot-dir sets
# VA_DUMP_FRAMES (frame-N.png / latest.png).
#
# Run state: engine/build-ios/run/<name>/ (serial.log, logcat.log, qemu.out,
# milestones.txt with host wall-clock seconds since spawn).
set -e
zmodload zsh/datetime
ROOT=${0:A:h:h:h:h}
OUT=$ROOT/engine/build-ios
IMG=$ROOT/images/android-33/arm64-v8a
E2=$(brew --prefix e2fsprogs)/sbin
BACKEND=tcg TIMEOUT=900 FRESH=0 NAME= UDID= MACHINE=ranchu ADB_PORT=5590 UNTIL=sys.boot_completed=1
GFX_LIB=auto SHOT_DIR= KEEP=0
while (( $# )); do
  case $1 in
    -b) BACKEND=$2; shift ;;
    --timeout) TIMEOUT=$2; shift ;;
    --fresh) FRESH=1 ;;
    --name) NAME=$2; shift ;;
    --device) UDID=$2; shift ;;
    --machine) MACHINE=$2; shift ;;
    --adb-port) ADB_PORT=$2; shift ;;
    --until) UNTIL=$2; shift ;;
    --gfx-lib) GFX_LIB=$2; shift ;;
    --screenshot-dir) SHOT_DIR=${2:A}; shift ;;
    --keep) KEEP=1 ;;
    --) shift; break ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
NAME=${NAME:-sim-$BACKEND}
Q=$OUT/ios_simulator-arm64/qemu-$BACKEND
LAUNCH=$Q/bin/va-qemu-launch
[[ -x $LAUNCH ]] || { echo "missing $LAUNCH: run build_qemu.sh -p ios_simulator -b $BACKEND" >&2; exit 1; }

# simulator device: ours (engine/build-ios/sim-udid) or a new one
if [[ -z $UDID ]]; then
  [[ -f $OUT/sim-udid ]] && UDID=$(<$OUT/sim-udid)
  if [[ -z $UDID ]] || ! xcrun simctl list devices | grep -q $UDID; then
    UDID=$(xcrun simctl create VA-ios-build "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-26-1)
    echo $UDID > $OUT/sim-udid
  fi
fi
if ! xcrun simctl list devices booted | grep -q $UDID; then
  xcrun simctl boot $UDID
  xcrun simctl bootstatus $UDID -b >/dev/null
fi

RUN=$OUT/run/$NAME
mkdir -p $RUN
if (( FRESH )) || [[ ! -f $RUN/userdata.img ]]; then
  rm -f $RUN/userdata.img $RUN/encryptionkey.img $RUN/cache.img
  cp $IMG/encryptionkey.img $RUN/
  mkfile -n 6g $RUN/userdata.img && $E2/mke2fs -q -F -t ext4 -b 4096 -L data $RUN/userdata.img
  mkfile -n 64m $RUN/cache.img && $E2/mke2fs -q -F -t ext4 -b 4096 -L cache $RUN/cache.img
fi
# Bootconfig overrides (as tools/run-macos.sh): the host adb key lets adbd accept
# this machine without a prompt.
INITRD_ARGS=()
[[ -f ~/.android/adbkey.pub ]] && INITRD_ARGS+=("androidboot.qemu.adb.pubkey=$(tr -d '\n' < ~/.android/adbkey.pub)")
INITRD_STAMP="$(shasum $ROOT/tools/make_initrd.py $IMG/ramdisk.img | awk '{print $1}' | tr -d '\n') ${(j: :)INITRD_ARGS}"
if [[ ! -f $RUN/initrd || "$(cat $RUN/initrd.params 2>/dev/null)" != "$INITRD_STAMP" ]]; then
  python3 -I $ROOT/tools/make_initrd.py $IMG/ramdisk.img $RUN/initrd $INITRD_ARGS
  print -r -- "$INITRD_STAMP" > $RUN/initrd.params
fi
rm -f $RUN/serial.log $RUN/logcat.log $RUN/hvc0.log $RUN/monitor.sock $RUN/milestones.txt

NET_FWD=",hostfwd=tcp:127.0.0.1:$ADB_PORT-:5555" EXTRA_DEV=() TRACE_OPT=() SPAWN_ENV=()
if [[ $MACHINE == ranchu* ]]; then
  # log every goldfish pipe service the guest opens; adb goes over vsock
  TRACE_OPT=(-trace enable=android_pipe_connect)
  EXTRA_DEV=(-device va-vsock-pci,guest-cid=77,adb-port=$ADB_PORT,pipe-port=5000)
  NET_FWD=""
  [[ $GFX_LIB == auto ]] && GFX_LIB=$ROOT/gfx/build-ios-sim/dist/va_gfx.framework/va_gfx
  if [[ $GFX_LIB != none && ! -f $GFX_LIB ]]; then
    echo "warning: no libva_gfx at $GFX_LIB, booting without graphics" >&2; GFX_LIB=none
  fi
  if [[ $GFX_LIB == none ]]; then MACHINE=$MACHINE,gfx=off; else MACHINE=$MACHINE,gfx-lib=$GFX_LIB; fi
fi
# environment for the simulator process (simctl passes SIMCTL_CHILD_*)
if [[ -n $SHOT_DIR ]]; then
  mkdir -p $SHOT_DIR; rm -f $SHOT_DIR/*.png(N)
  export SIMCTL_CHILD_VA_DUMP_FRAMES=$SHOT_DIR
fi

ARGS=(
  -M $MACHINE -accel tcg,thread=multi,tb-size=1024 -cpu cortex-a76 -smp 4 -m 2048 -nodefaults -display none
  -serial file:$RUN/serial.log -monitor unix:$RUN/monitor.sock,server,nowait
  -kernel $IMG/kernel-ranchu -initrd $RUN/initrd
  -append "8250.nr_uarts=1 no_timer_check console=ttyAMA0,38400 keep_bootcon earlyprintk=ttyAMA0 ndns=2 loop.max_part=7 printk.devkmsg=on bootconfig"
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
echo "device $UDID, run dir $RUN, backend $BACKEND, timeout ${TIMEOUT}s"
START=$EPOCHREALTIME
xcrun simctl spawn $UDID $LAUNCH -- $ARGS > $RUN/qemu.out 2>&1 &
SPID=$!

MILESTONES=("Run /init" "init second stage started" "starting service 'zygote'" "starting service 'surfaceflinger'" "starting service 'bootanim'" "Service 'bootanim'" "sys.boot_completed=1")
typeset -A SEEN
printf '%9s %10s  %s\n' host_s guest_s milestone | tee $RUN/milestones.txt
STOP=0
while kill -0 $SPID 2>/dev/null; do
  T=$(( EPOCHREALTIME - START ))
  for m in $MILESTONES; do
    if [[ -z ${SEEN[$m]} ]]; then
      line=$(grep -haF -m1 -- "$m" $RUN/serial.log $RUN/logcat.log 2>/dev/null | head -1)
      if [[ -n $line ]]; then
        SEEN[$m]=$T
        g='?'; [[ $line == \[* ]] && { g=${${line#\[}%%\]*}; g=${g// /}; }
        printf '%8.1fs %9ss  %s\n' $T "${g:-?}" "$m" | tee -a $RUN/milestones.txt
        [[ $m == *$UNTIL* ]] && STOP=1
      fi
    fi
  done
  (( STOP )) && break
  (( T > TIMEOUT )) && break
  sleep 1
done
if (( KEEP )) && kill -0 $SPID 2>/dev/null; then
  printf 'left running (spawn pid %d); stop: print quit | nc -U %s\n' $SPID $RUN/monitor.sock
  exit 0
fi
if kill -0 $SPID 2>/dev/null; then
  # quit QEMU through the monitor (exercises qemu_main_loop -> qemu_cleanup)
  print quit | nc -U -w 2 $RUN/monitor.sock >/dev/null 2>&1 || true
  sleep 3
  kill $SPID 2>/dev/null || true
  # simctl spawn may leave the simulator-side process running
  pkill -f "$LAUNCH" 2>/dev/null || true
fi
wait $SPID 2>/dev/null || true
printf 'total %.1fs\n' $(( EPOCHREALTIME - START )) | tee -a $RUN/milestones.txt
tail -3 $RUN/qemu.out
