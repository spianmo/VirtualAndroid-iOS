"""Build the initrd QEMU boots: the image's ramdisk with an Android bootconfig appended.

usage: python3 -I tools/make_initrd.py <ramdisk.img> <out-initrd> [key=value ...]

Extra key=value pairs override/add androidboot.* parameters. The trailer
format (params, NUL, size, checksum, "#BOOTCONFIG\\n") is what the kernel's
bootconfig parser expects.
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
    "androidboot.qemu.camera_protocol_ver": "1",
    "androidboot.qemu.avd_name": "virtualandroid",
    # Values from the image's VerifiedBootParams.textproto.
    "androidboot.vbmeta.size": "6208",
    "androidboot.vbmeta.hash_alg": "sha256",
    "androidboot.vbmeta.digest": "0aa6a7fa9cc8ff3e3ee12c25c0c91e7dbf3627f0d45dc44a48cbd8d88eb72f59",
    "androidboot.veritymode": "enforcing",
}


def main():
    ramdisk, out = sys.argv[1], sys.argv[2]
    params = dict(DEFAULTS)
    for kv in sys.argv[3:]:
        k, v = kv.split("=", 1)
        params[k] = v
    with open(ramdisk, "rb") as f:
        data = f.read()
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
