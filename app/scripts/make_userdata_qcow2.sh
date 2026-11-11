#!/bin/zsh
# Builds the writable disks the iOS app needs (iOS has no mke2fs):
#   userdata.qcow2   freshly formatted ext4, label "data"  (default 6G)
#   cache.qcow2      freshly formatted ext4, label "cache" (64M)
# and, with --pack, a complete image pack folder for the app.
#
#   app/scripts/make_userdata_qcow2.sh [-o OUTDIR] [--size 6G] [--pack [IMAGE_DIR]]
#                                      [--from-run RUN_DIR [--userdata-kind KIND]]
#
#   -o OUTDIR      output folder (default: <repo>/app/build/ImagePack)
#   --size SIZE    userdata size for mkfile (default 6g)
#   --pack [DIR]   also add kernel-ranchu, ramdisk.img, system.img, vendor.img
#                  (APFS clones via cp -c, no extra disk space on the same
#                  volume) and encryptionkey.qcow2 from the Android image
#                  (default: <repo>/images/android-33/arm64-v8a), plus manifest.json
#                  and ~/.android/adbkey.pub (dev; VA_NO_ADBKEY=1 omits it)
#   --from-run DIR a powered-off tools/run-macos.sh run (engine/run/<name>) whose
#                  userdata.img, encryptionkey.img and cache.img become the pack's
#                  qcow2s instead of empty disks (implies --pack; the three belong
#                  together: userdata is encrypted with the metadata key in
#                  encryptionkey). Used by tools/prebake_userdata.sh.
#   --userdata-kind KIND  manifest "userdata" value for --from-run (default
#                  prebaked-speed); the app takes a "prebaked*" pack's disks with the
#                  prebaked initrd profile (BootConfig.prebakedDebugProps).
#
# Tools: engine/build-macos/qemu-img (QEMU_IMG overrides) and e2fsprogs
# (brew install e2fsprogs). Inode tables and journal are zeroed on the host
# (lazy init off) so the guest does not rewrite them on first boot and the
# qcow2 stays small (zero clusters are not stored). qcow2s are uncompressed.
set -euo pipefail
ROOT=${0:A:h:h:h}
OUT=$ROOT/app/build/ImagePack
SIZE=6g
PACK=0
FROM_RUN=
KIND=prebaked-speed
IMG=$ROOT/images/android-33/arm64-v8a
QEMU_IMG=${QEMU_IMG:-$ROOT/engine/build-macos/qemu-img}
E2=$(brew --prefix e2fsprogs)/sbin

while (( $# )); do
  case $1 in
    -o) OUT=${2:A}; shift ;;
    --size) SIZE=$2; shift ;;
    --pack) PACK=1; if [[ $# -gt 1 && $2 != -* ]]; then IMG=$2; shift; fi ;;
    --from-run) FROM_RUN=${2:A}; PACK=1; shift ;;
    --userdata-kind) KIND=$2; shift ;;
    -h|--help) sed -n '2,29p' $0; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

[[ -x $QEMU_IMG ]] || { echo "qemu-img not found at $QEMU_IMG (set QEMU_IMG)" >&2; exit 1; }
[[ -x $E2/mke2fs ]] || { echo "mke2fs not found; brew install e2fsprogs" >&2; exit 1; }
if [[ -n $FROM_RUN ]]; then
  for f in userdata.img encryptionkey.img cache.img; do
    [[ -f $FROM_RUN/$f ]] || { echo "missing $FROM_RUN/$f" >&2; exit 1; }
  done
  # The disks must not be in use (a running QEMU holds them open).
  if lsof $FROM_RUN/userdata.img >/dev/null 2>&1; then
    echo "$FROM_RUN/userdata.img is in use (VM still running?)" >&2; exit 1
  fi
fi
mkdir -p $OUT
TMP=$(mktemp -d $OUT/.mkdisk.XXXXXX)
trap 'rm -rf $TMP' EXIT

report() {  # qcow2
  echo "$1: $($QEMU_IMG info --output=json $1 | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d["virtual-size"]//2**20, "MiB virtual,", d["actual-size"]//2**10, "KiB on disk")')"
}

to_qcow2() {  # raw-image name
  rm -f $OUT/$2.qcow2
  $QEMU_IMG convert -q -f raw -O qcow2 -o cluster_size=65536 $1 $TMP/$2.qcow2
  mv $TMP/$2.qcow2 $OUT/$2.qcow2
  report $OUT/$2.qcow2
}

make_ext4() {  # name label size
  local raw=$TMP/$1.raw
  mkfile -n $3 $raw
  $E2/mke2fs -q -F -t ext4 -b 4096 -L $2 -E lazy_itable_init=0,lazy_journal_init=0 $raw
  $E2/e2fsck -fn $raw >/dev/null
  to_qcow2 $raw $1
  rm -f $raw
}

if [[ -n $FROM_RUN ]]; then
  # userdata is encrypted (metadata encryption), so the host cannot fsck it; cache is plain.
  $E2/e2fsck -fn $FROM_RUN/cache.img >/dev/null 2>&1 || echo "warning: $FROM_RUN/cache.img is not clean" >&2
  SIZE=$(( $(stat -f %z $FROM_RUN/userdata.img) >> 30 ))g
  to_qcow2 $FROM_RUN/userdata.img userdata
  to_qcow2 $FROM_RUN/cache.img cache
else
  make_ext4 userdata data $SIZE
  make_ext4 cache cache 64m
fi

if (( PACK )); then
  for f in kernel-ranchu ramdisk.img system.img vendor.img; do
    [[ -f $IMG/$f ]] || { echo "missing $IMG/$f" >&2; exit 1; }
    rm -f $OUT/$f
    cp -c $IMG/$f $OUT/$f 2>/dev/null || cp $IMG/$f $OUT/$f
  done
  for f in VerifiedBootParams.textproto build.prop; do
    [[ -f $IMG/$f ]] && cp $IMG/$f $OUT/$f
  done
  # Dev builds: this Mac's adb key, so the guest's adbd trusts it without a
  # prompt (androidboot.qemu.adb.pubkey). Do not ship it in a release pack.
  if [[ -f ~/.android/adbkey.pub && ${VA_NO_ADBKEY:-0} != 1 ]]; then
    cp ~/.android/adbkey.pub $OUT/adbkey.pub
  else
    rm -f $OUT/adbkey.pub
  fi
  # Metadata partition as qcow2 too: every writable disk must support savevm.
  if [[ -n $FROM_RUN ]]; then
    to_qcow2 $FROM_RUN/encryptionkey.img encryptionkey
  else
    $QEMU_IMG convert -q -f raw -O qcow2 $IMG/encryptionkey.img $OUT/encryptionkey.qcow2
  fi
  rm -f $OUT/encryptionkey.img
  REV=$(sed -n 's/^Pkg.Revision=//p' $IMG/source.properties 2>/dev/null || true)
  USERDATA_LINE=
  [[ -n $FROM_RUN ]] && USERDATA_LINE="
  \"userdata\": \"$KIND\","
  cat > $OUT/manifest.json <<JSON
{
  "name": "Android 13 (AOSP)",
  "api": 33,
  "abi": "arm64-v8a",
  "revision": "${REV:-unknown}",${USERDATA_LINE}
  "userdata_size": "$SIZE",
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
  python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' $OUT/manifest.json
  echo "image pack ready: $OUT"
  ls -lh $OUT
fi
