"""Build the initrd QEMU boots: the image's ramdisk with an Android bootconfig appended.

usage: python3 -I tools/make_initrd.py <ramdisk.img> <out-initrd> [key=value ...]

Extra key=value pairs override/add androidboot.* parameters. The trailer
format (params, NUL, size, checksum, "#BOOTCONFIG\\n") is what the kernel's
bootconfig parser expects.

Between the ramdisk and the trailer we append a small cpio fragment with
/force_debuggable and /adb_debug.prop (DEBUG_PROPS). First-stage init copies
adb_debug.prop to /debug_ramdisk and second-stage init loads it last, which is
the only host-side way to set ro.* properties such as ro.hw_timeout_multiplier
(bootconfig only yields ro.boot.*). Second-stage init honours it only on an
unlocked device, hence androidboot.verifiedbootstate=orange.
Keep app/VirtualAndroid/VM/BootConfig.swift byte-identical to this file.
"""
import struct
import sys

DEFAULTS = {
    "androidboot.hardware": "ranchu",
    "androidboot.boot_devices": "a003600.virtio_mmio",
    "androidboot.serialno": "VIRTUALANDROID01",
    "androidboot.qemu": "1",
    "androidboot.hardware.gltransport": "pipe",
    "androidboot.qemu.gltransport.name": "pipe",
    "androidboot.qemu.gltransport.drawFlushInterval": "800",
    "androidboot.hardware.vulkan": "ranchu",
    # Must match what the host renderer (libva_gfx) supports: ANGLE Metal on
    # Apple = GLES 3.0 = (3 << 16) | 0. The engine logs the value it needs at
    # startup ("ranchu: guest needs androidboot.opengles.version=..."); the
    # official emulator (swangle) used 196609 (3.1).
    "androidboot.opengles.version": "196608",
    "androidboot.debug.hwui.renderer": "skiagl",
    "androidboot.dalvik.vm.heapsize": "512m",
    "androidboot.logcat": "*:V",
    "androidboot.qemu.skin": "1080x2340",
    "androidboot.qemu.vsync": "60",
    "androidboot.qemu.settings.system.screen_off_timeout": "2147483647",
    # The services' qemud camera speaks protocol v0 only (v1 needs a
    # goldfish address-space camera sub-device).
    "androidboot.qemu.camera_protocol_ver": "0",
    # Wi-Fi like the emulator: init.ranchu-net.sh creates the mac80211_hwsim
    # radio wlan0, whose frames go to the engine's va-wifi-pci access point.
    "androidboot.qemu.virtiowifi": "1",
    "androidboot.qemu.avd_name": "virtualandroid",
    # Values from the image's VerifiedBootParams.textproto.
    "androidboot.vbmeta.size": "6208",
    "androidboot.vbmeta.hash_alg": "sha256",
    "androidboot.vbmeta.digest": "0aa6a7fa9cc8ff3e3ee12c25c0c91e7dbf3627f0d45dc44a48cbd8d88eb72f59",
    "androidboot.veritymode": "enforcing",
    # Lets second-stage init load /debug_ramdisk/adb_debug.prop (see above).
    "androidboot.verifiedbootstate": "orange",
}

# Loaded last by init. Under emulation (TCTI on iOS is several times slower
# than a phone) system_server's watchdog (60 s) and ActivityManager timeouts
# fire during normal startup; they all scale with ro.hw_timeout_multiplier.
DEBUG_PROPS = {
    "ro.hw_timeout_multiplier": "5",
}


def cpio_newc(files):
    """newc cpio archive of regular files (name, data) plus the trailer."""
    out = bytearray()
    for ino, (name, data) in enumerate(list(files) + [("TRAILER!!!", None)], 300001):
        mode = 0o100644 if data is not None else 0
        data = data or b""
        nb = name.encode() + b"\0"
        fields = (ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nb), 0)
        out += ("070701" + "".join(f"{v:08x}" for v in fields)).encode() + nb
        out += b"\0" * (-(110 + len(nb)) % 4)
        out += data + b"\0" * (-len(data) % 4)
    return bytes(out)


def lz4_legacy(data):
    """LZ4 legacy frame (what the ramdisk uses) holding `data` as literal-only
    blocks; the kernel decodes concatenated legacy frames as one stream."""
    out = bytearray(struct.pack("<I", 0x184C2102))
    for off in range(0, len(data), 8 << 20):
        chunk = data[off:off + (8 << 20)]
        n = len(chunk)
        blk = bytearray([min(n, 15) << 4])
        if n >= 15:
            r = n - 15
            while r >= 255:
                blk.append(255)
                r -= 255
            blk.append(r)
        blk += chunk
        out += struct.pack("<I", len(blk)) + blk
    return bytes(out)


def debug_fragment(props):
    prop = "".join(f"{k}={v}\n" for k, v in sorted(props.items())).encode()
    return lz4_legacy(cpio_newc([("force_debuggable", b""), ("adb_debug.prop", prop)]))


def main():
    ramdisk, out = sys.argv[1], sys.argv[2]
    params = dict(DEFAULTS)
    for kv in sys.argv[3:]:
        k, v = kv.split("=", 1)
        params[k] = v
    with open(ramdisk, "rb") as f:
        data = f.read()
    data += debug_fragment(DEBUG_PROPS)
    text = "".join(f'{k}="{v}"\n' for k, v in sorted(params.items())).encode()
    text += b"\0"
    # Like the emulator: pad with '+' so the size field starts 4-byte aligned.
    text += b"+" * (-(len(data) + len(text)) % 4)
    checksum = sum(text) & 0xFFFFFFFF
    trailer = text + struct.pack("<II", len(text), checksum) + b"#BOOTCONFIG\n"
    with open(out, "wb") as f:
        f.write(data)
        f.write(trailer)


if __name__ == "__main__":
    main()
