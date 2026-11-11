"""Build the initrd QEMU boots: the image's ramdisk with an Android bootconfig appended.

usage: python3 -I tools/make_initrd.py <ramdisk.img> <out-initrd> [--prebaked] [key=value ...]

Extra key=value pairs override/add androidboot.* parameters. The trailer
format (params, NUL, size, checksum, "#BOOTCONFIG\\n") is what the kernel's
bootconfig parser expects.

Between the ramdisk and the trailer we append a small cpio fragment with
/force_debuggable and /adb_debug.prop (DEBUG_PROPS). First-stage init copies
adb_debug.prop to /debug_ramdisk and second-stage init loads it last, which is
the only host-side way to set ro.* properties such as ro.hw_timeout_multiplier
(bootconfig only yields ro.boot.*). Second-stage init honours it only on an
unlocked device, hence androidboot.verifiedbootstate=orange.
--prebaked adds PREBAKED_PROPS (a userdata whose apps were compiled ahead of
time on the Mac; currently none). Off by default.
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
    # Info and up: keeps ActivityManager, Choreographer "Skipped N frames" and
    # OpenGLRenderer "Davey!"; verbose/debug lines cost guest CPU under TCTI.
    "androidboot.logcat": "*:I",
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
#
# Bluetooth (com.android.btservices does not use the multiplier): the adapter
# gets 4 s for each step of turning on and off. Only the BLE steps have
# properties; the BR/EDR step (starting the profile services) is fixed at 4 s,
# and every timeout makes BluetoothManagerService restart the Bluetooth
# process, endlessly once BLE comes up. Under TCTI the BLE step takes up to
# ~8 s at boot and the profiles ~3 s on a quiet guest (~9 s on a busy one), so:
#  - the BLE steps get 5 x 4 s;
#  - the profiles that only serve a remote peer through OBEX, content
#    providers or tethering (OPP, PBAP and MAP servers, PAN) are off: the
#    engine's controller has no radio, so no peer can connect, and they were
#    the slow part (OPP alone flips seven components through PackageManager on
#    every start and stop). A2DP, AVRCP, HFP, HID, MCP and GATT stay;
#  - BluetoothManagerService does not turn Bluetooth on at boot (no persisted
#    state): the engine does, once the booted guest is quiet, if the setting it
#    still records (bluetooth_on) is not 0 (guest_time.c).
#
# Not settable here: installd kills dex2oat after 570 s (kLongTimeoutMs, not
# scaled by ro.hw_timeout_multiplier; dex2oat's own watchdog has the same 9.5
# minutes). Under TCTI a big app's install-time dexopt can outlast it, and the
# app is then left run-from-apk (docs/AOT.md, "Third-party apps").
DEBUG_PROPS = {
    "ro.hw_timeout_multiplier": "5",
    "ro.bluetooth.ble_start_timeout_delay": "20000",
    "ro.bluetooth.ble_stop_timeout_delay": "20000",
    "bluetooth.profile.opp.enabled": "false",
    "bluetooth.profile.pbap.server.enabled": "false",
    "bluetooth.profile.map.server.enabled": "false",
    "bluetooth.profile.pan.nap.enabled": "false",
    "bluetooth.profile.pan.panu.enabled": "false",
    "bluetooth.framework.support_persisted_state": "false",
}

# Opt-in "prebaked" profile (--prebaked): userdata where first boot, odrefresh
# and `pm compile -m speed -f -a` already ran on the Mac. It used to turn the
# JIT off and compile installs with "speed"; both hurt apps installed later:
# without the JIT their code is interpreted until the next background dexopt,
# and a "speed" install of a big app takes most of an hour under TCTI (the
# install waits for it). The JIT only compiles code that has no AOT code, so it
# costs nothing for the prebaked apps. Nothing left to change; kept so that
# callers and the userdata kind stay as they are.
PREBAKED_PROPS = {}


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


def debug_props(prebaked=False):
    return {**DEBUG_PROPS, **(PREBAKED_PROPS if prebaked else {})}


def debug_fragment(props):
    prop = "".join(f"{k}={v}\n" for k, v in sorted(props.items())).encode()
    return lz4_legacy(cpio_newc([("force_debuggable", b""), ("adb_debug.prop", prop)]))


def main():
    argv = sys.argv[1:]
    prebaked = "--prebaked" in argv
    argv = [a for a in argv if a != "--prebaked"]
    ramdisk, out = argv[0], argv[1]
    params = dict(DEFAULTS)
    for kv in argv[2:]:
        k, v = kv.split("=", 1)
        params[k] = v
    with open(ramdisk, "rb") as f:
        data = f.read()
    data += debug_fragment(debug_props(prebaked))
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
