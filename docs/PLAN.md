# VirtualAndroid — 在 iPhone 上运行完整 Android 13

## 目标
iOS App：点开即进入完整的 Android 13（AOSP，arm64）桌面。整机虚拟（自带 Linux 内核），
用 AOT 预编译保证性能，Android 硬件 API（传感器/定位/相机/音频/电池/剪贴板/触控……）桥接到 iOS 框架。

## 硬约束与对应决策
| 约束 | 决策 |
|---|---|
| 第三方 iOS App 无 Hypervisor.framework | 全系统模拟（QEMU softmmu）。越狱/TrollStore 设备可选 UTM 的 `hvf-private` 作为真硬件虚拟化 |
| XNU 不能跑 Linux 二进制 | twoyi 式容器、Mac.apk 式兼容层在 iOS 都不可行 → 带 Linux 内核整机模拟 |
| 普通 iOS App 无 JIT | 设备端用 UTM 的 TCTI（预编译 gadget 串接，免 JIT）+ 我们的 **AOT 翻译缓存**；模拟器和 StikDebug 设备用 TCG JIT |
| API 33 镜像无客户机软件渲染 | 宿主必须跑 **gfxstream** 渲染器；iOS 上 GLES 走 ANGLE(Metal)，Vulkan 走 MoltenVK |
| 内存 | 客户机 2 GB；需要 increased-memory-limit 和 extended-virtual-addressing 权限 |

## 已实测的事实（2026-11-04）
- 镜像：`system-images;android-33;default;arm64-v8a` r02，内核 5.15.41-android13，动态分区（system.img = GPT{vbmeta,super}）。
- 官方模拟器（37.2.3）跑 API 33 用的就是 **QEMU 标准 `-M virt`**，加 6 个 goldfish 设备：
  pipe@a060000、sync@a070000、events@a050000、audio@a030000、battery@a040000、fb@a020000，
  再加 `/firmware/android{compatible="android,firmware"; hardware="ranchu"}`。完整 DTS 见 `docs/ranchu-api33.dts`。
- 磁盘顺序决定 virtio-mmio 地址：vendor→a003e00、encrypt(metadata)→a003c00、userdata→a003a00、cache→a003800、system→a003600。
- bootconfig 附加在 initrd 尾部（`#BOOTCONFIG` 尾标），参数见 `reference/emulator_dumpdtb.log`。
- **GL 走 goldfish pipe（`gltransport=pipe`），gralloc 是 goldfish（mapper@3.0-ranchu），不涉及 minigbm/virtio-gpu。**
- `/data` 要宿主预先建好空 ext4（mke2fs），客户机不会自己格式化。
- 我们自编的 QEMU 10.0.12-utm 用原版 `virt`+HVF，已跑到 zygote/surfaceflinger；卡在
  `HostConnection: Failed to connect to host (QemuPipeStream)`：hwcomposer、gralloc、sensors、camera 全依赖 goldfish pipe。
- 基准：官方模拟器 HVF 冷启动到 `sys.boot_completed=1` 用时 26 s。
- **`-M ranchu`（engine/qemu master，hw/android）在 macOS HVF 上到 `sys.boot_completed=1`，客户机时间 13.9 s**
  （services + libva_gfx 渲染器 + va-vsock；开机动画画面见 `docs/first-frame.png`）。之后 system_server 因渲染器卡死
  （ANGLE `setAttachment` 持 FrameBuffer 锁）被 watchdog 反复重启，归 gfx 处理。
- 客户机必需的设备：goldfish pipe(v2，客户机驱动版本 4)、sync、battery（`healthd: battery l=100 ... chg=a`），
  以及 **PCI `goldfish_address_space`**（00:0b.0，[607d:f153] rev 1，BAR0 4 KiB 寄存器 + BAR1 8 GiB 区域）。
  没有它 gralloc/hwcomposer 直接 abort（`GoldfishAddressSpaceHostMemoryAllocator failed to open`）。
  只实现子设备 HostMemoryAllocator(5) 即可；BAR1 只占客户机物理地址，宿主内存按块 mmap 并映射进去，块要按宿主页 16 KiB 对齐，否则 HVF 不能当 RAM 映射。
- API 33 GKI 内核**没有 goldfish-events 驱动**（设备树节点有，但不会 probe）。按键和触屏要走 virtio-input，
  设备名必须是 `virtio_input_multi_touch_1`（触屏）和 `qwerty2`（键盘），这样才能对上 /vendor/usr/idc。
  qwerty.kl 里 HOME 是 102，没有 172。
- 管道服务连接串：`pipe:<服务>[:<参数>]\0`，服务名在第一个 `:` 处结束（`pipe:qemud:sensors` 打开的是服务 `qemud`，参数 `sensors`）。
  所有客户端先试 vsock，失败再回落到 /dev/goldfish_pipe。adbd 只监听 vsock:5555。剪贴板只走 vsock 端口 5000。
  开机请求的服务清单见 `docs/pipe-services-requested.md`。
- 渲染器 ANGLE Metal 上报 GLES 3.0，所以 bootconfig 要设 `androidboot.opengles.version=196608`（官方 swangle 是 196609）。
  以 bootconfig 为准，qemud boot-properties 不再发这个属性。
- HVF 下 ranchu 整机快照（`migrate` 存到文件再 `-incoming` 恢复）可用：打开着的 pingpong 管道及其中未读数据恢复后都还在。
  注意不要在 VM 暂停时往串口灌输入。

## 架构
```
┌──────────── iOS App (SwiftUI) ───────────────────────────────────┐
│ VMController ── Metal 显示层(CAMetalLayer) ── 触控/键盘 → virtio-input │
│ HostBridges(Swift): CoreMotion CoreLocation AVFoundation AudioUnit │
│                     UIDevice电池 UIPasteboard CoreHaptics           │
├──────────── va_host.h（C 接口，平台无关）────────────────────────────┤
│ libqemu-aarch64 (UTM fork 10.0.12, 以库形式在线程中运行)              │
│  machine "ranchu" = virt + goldfish{pipe,sync,events,battery}        │
│  virtio: blk×5 net rng serial(console/logcat) multitouch kbd snd     │
│  pipe core (AndroidPipe ABI) ─ services: qemud:{boot-properties,     │
│     sensors,gps,hw-control,fingerprintlisten,camera…} opengles       │
│     GLProcessPipe refcount QemuMiscPipe                              │
│  CPU: TCG-JIT(模拟器) / TCTI + AOT 缓存(真机)                          │
├──────────── va_gfx.h ────────────────────────────────────────────────┤
│ libva_gfx: gfxstream host renderer → ANGLE(Metal) / MoltenVK → IOSurface│
└──────────────────────────────────────────────────────────────────────┘
客户机：官方 AOSP Android 13 镜像原样使用（不改 system/vendor）
```

## 目录与归属（并行开发时只改自己的目录）
| 路径 | 内容 | 负责 |
|---|---|---|
| `engine/qemu/` | QEMU 10.0.12-utm（独立 git 仓库，基线提交 bb1d584） | board / services / aot（分文件） |
| `engine/qemu/hw/android/` | ranchu 主板、goldfish 设备、pipe 核心 | board |
| `engine/qemu/hw/android/services/` | qemud 及各 pipe 服务 | services |
| `engine/qemu/include/hw/android/android_pipe.h` | **契约**：pipe 服务 ABI | 主控（改动需协调） |
| `host/include/va_host.h` | **契约**：引擎 ↔ 平台桥接 | 主控 |
| `host/macos/` | macOS 上的桩实现/测试桥接 | services |
| `gfx/` | gfxstream/ANGLE/MoltenVK 构建与 `libva_gfx` | gfx |
| `gfx/include/va_gfx.h` | **契约**：渲染库接口 | 主控 |
| `tools/` | 镜像准备、启动脚本、AOT 编译器 | board(启动) / aot |
| `engine/scripts/ios/` | iOS/模拟器交叉编译依赖与 QEMU framework | ios-build |
| `app/` | iOS App 工程 | app |

## 里程碑
- **M0 环境** ✅ 磁盘、iOS 26.1 模拟器运行时、镜像、QEMU 基线、macOS HVF 构建。
- **M1 macOS 上开机**：ranchu 主板 + goldfish pipe + qemud 服务 + gfxstream(macOS)，
  在我们的 QEMU 里 `sys.boot_completed=1` 且能看到桌面（Cocoa 窗口或截图）。
- **M2 iOS 模拟器里开机**：QEMU 以 framework 形式跑在 App 进程内（TCG JIT），Metal 显示，触控可用。
- **M3 硬件桥接**：传感器、定位、电池、音频输出/麦克风、剪贴板、网络、相机。
- **M4 秒开**：首启建盘、整机快照保存/恢复，冷启动之后再开 App 几秒进桌面。
- **M5 真机无 JIT 性能**：TCTI 构建 + AOT 翻译缓存（离线录制热点 TB → 编译成签名代码 → 运行时按内容哈希命中）。
- **M6 真机**：签名、权限、内存权限、iPhone 实测（需要 Apple 开发者账号）。

## AOT 设计要点（M5）
- ARM 目标开启 CF_PCREL，TB 只与 物理页内偏移+flags+cs_base+cflags 有关 → key = hash(客户机指令字节, 页内偏移, flags, cs_base, cflags)。
- 离线：macOS 上用 QEMU 插件 API 录制开机和常用操作中执行的 TB 及热度；用 TCG→C（参考 S2E `tcg-llvm.cpp`）
  把热点 TB 翻译成 C 函数，clang -O2 编进 App（签名代码）。
- 运行时：TCTI 后端在 `tb_gen_code` 后查 AOT 表，命中就把 TB 的执行入口换成预编译函数；未命中照常走 TCTI gadget。
- 客户机侧同时让 ART 全量 AOT（dex2oat speed），减少客户机内 JIT 生成的、无法离线缓存的代码。
- 验收：同一快照下，TCTI vs TCTI+AOT 的开机时间和 UI 帧率对比。

## 风险
- gfxstream 移植到 iOS（GLES 翻译层依赖宿主 EGL/GLES → ANGLE）是最大技术风险；
  兜底：只编 Vulkan 路径，客户机用 `androidboot.hardwareegl=angle` 把 GLES 转成 Vulkan。
- 真机无 JIT 时即使有 AOT，性能也会远低于原生。目标是"可用"，不是"流畅"。
- App Store 不允许这类 App；按开发者签名或侧载分发。
