# Goldfish pipe services the API 33 guest requests

Measured on our QEMU `-M ranchu` (engine/qemu master d7dacc99a, HVF, 2026-11-04) with **no
services registered**, so every connect failed and each client gave up or retried:

```
tools/run-macos.sh --fresh --machine ranchu --name board --adb-port 5601 --timeout 90
grep android_pipe_connect engine/run/board/qemu.out | sort | uniq -c
```

The trace event `android_pipe_connect service=<name> args=<args> found=<0|1>` prints every
connection attempt (`run-macos.sh --machine ranchu` enables it; otherwise
`-trace enable=android_pipe_connect`). Connector semantics: the guest writes
`pipe:<service>[:<args>]\0`; the service name ends at the first `:`, so `pipe:qemud:sensors`
opens service **`qemud`** with args `sensors`.

## Observed during boot (first 90 s, nothing registered)

| first seen | pipe string | service / args | client process | attempts |
|---|---|---|---|---|
| +6 s  | `pipe:qemud:boot-properties` | `qemud` / `boot-properties` | `/vendor/bin/qemu-props` (retries 1 s, 5x, then gives up) | 5 |
| +12 s | `pipe:qemud:sensors` | `qemud` / `sensors` | `android.hardware.sensors@2.1-service.multihal` (crash loop) | 16 |
| +12 s | `pipe:opengles` | `opengles` / – | `android.hardware.graphics.allocator@3.0-service` (gralloc) | 1 |
| +12 s | `pipe:opengles` | `opengles` / – | `android.hardware.graphics.composer@2.4-service` (RanchuHwc, crash loop) | 16 |
| +12 s | `pipe:opengles` | `opengles` / – | `android.hardware.camera.provider@2.4-service_64` (crash loop) | 17 |
| +12 s | `pipe:qemud:fingerprintlisten` | `qemud` / `fingerprintlisten` | `android.hardware.biometrics.fingerprint@2.1-service` | 1 |
| +37 s | `pipe:opengles` | `opengles` / – | `surfaceflinger` (crash loop) | 8 |

Totals in that run: `opengles` 42, `qemud:sensors` 16, `qemud:boot-properties` 5,
`qemud:fingerprintlisten` 1. All 42 `HostConnection: Failed to connect to host (QemuPipeStream)`
logcat lines correspond to failed `opengles` connects (the service does not exist yet, so
that error is expected until gfx registers it).

## Requested only after an earlier connect succeeds

These clients stop at the first failure, so the list above is incomplete. From the strings of
the vendor binaries (and the emulator's behaviour) the next requests are:

| pipe string | client | when |
|---|---|---|
| `pipe:GLProcessPipe` | libOpenglSystemCommon (every GL/Vulkan process: surfaceflinger, hwcomposer, gralloc, camera, apps) | right after `opengles` handshake succeeds (HostConnection, per process; gives the renderer a per-process id) |
| `pipe:refcount` | gralloc allocator / mapper (libOpenglSystemCommon) | per allocated color buffer, keeps host color buffers alive |
| `pipe:opengles` (more) | HostConnection per thread | one per GL thread |
| `pipe:QemuMiscPipe` | `/vendor/bin/qemu-props` | after boot-properties; sends `heartbeat`/`bootcomplete` (sets `vendor.qemu.dev.bootcomplete`) |
| `pipe:qemud:gps` | `android.hardware.gnss@2.0-service.ranchu` | when the GNSS HAL starts (not seen in 90 s of a renderer-less boot) |
| `pipe:qemud:camera` | `camera.ranchu.so` (EmulatedCamera_QemuDevice) | camera provider enumerating host webcams, after its `opengles`/gralloc init succeeds |
| `pipe:qemud:hw-control` | (lights / power HAL on older images) | not referenced by API 33 vendor binaries; harmless to keep |
| `pipe:clipboard` | not in vendor; clipboard in this image uses **vsock port 5000** (see services' va-vsock) | — |

Transport note: every client first tries **vsock** (`vsock_ping`, `/dev/vsock`), then falls back
to `/dev/goldfish_pipe` ("both vsock and goldfish_pipe paths failed" when neither works). On
ranchu there is no virtio-vsock unless services' `va-vsock-pci` is added, so the goldfish pipe is
used. If a vsock device is present, the same `pipe:<service>` strings arrive over vsock.

## Who implements what

| service name (registry key) | owner |
|---|---|
| `opengles`, `GLProcessPipe`, `refcount` | gfx (libva_gfx via `VaGfxEngineOps.pipe_add_type`) |
| `qemud` (args `boot-properties`, `sensors`, `fingerprintlisten`, `gps`, `camera`, `hw-control`), `QemuMiscPipe`, `clipboard` | services (branch `services`) |
| `zero`, `pingpong` | board (built-in test services in android_pipe.c) |

## With services + renderer (master 281ac47f2, 300 s run: sys.boot_completed=1 at guest 13.9 s, then system_server watchdog restarts caused by the render stall)

| count | request |
|---|---|
| 56 | `service=refcount args= found=1` |
| 21 | `service=opengles args= found=1` |
| 8 | `service=GLProcessPipe args= found=1` |
| 2 | `service=qemud args=gps found=1` |
| 1 | `service=qemud args=sensors found=1` |
| 1 | `service=qemud args=fingerprintlisten found=1` |
| 1 | `service=qemud args=camera found=1` |
| 1 | `service=qemud args=boot-properties found=1` |
| 1 | `service=clipboard args= found=1` |
| 1 | `service=QemuMiscPipe args= found=1` |

Seen for the first time once earlier connects succeed: `GLProcessPipe`, `refcount` (one per
gralloc buffer), `qemud:gps`, `qemud:camera`, `QemuMiscPipe`, `clipboard` (over vsock port 5000
via services' va-vsock pipe-port, so it also goes through the same registry).
