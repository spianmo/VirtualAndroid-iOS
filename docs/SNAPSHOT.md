# M4 快照秒开：设计与协议

## 目标（验收线）
| 场景 | 目标 |
|---|---|
| App 退到后台 → 挂起（保存完成） | < 2 s（iOS 后台时间有限） |
| App 被杀后再点开 → 可交互桌面 | macOS HVF < 3 s；iOS 模拟器 < 5 s |
| 后台未被杀、回到前台 | 立即（`cont`） |
| 首次启动 / 快照无效 | 冷启动（现状 70–190 s），开机完成后立刻建一次快照 |

## 实测起点（2026-11-04，macOS HVF，ranchu，进桌面后）
- 普通 `migrate file:`（mapped-ram）保存整机：19.8 s，写出 1.88 GB 非零页 → **太慢，不能用作后台挂起**。
- 没有任何设备阻止迁移（无 blocker）。
- `-incoming` 恢复时崩溃：`goldfish_address_space.c:607 get_state → host_block_new →
  memory_region_init_ram_ptr → ram_block_notify_add → bdrv_register_buf → assert(!qemu_in_coroutine())`
  （加载在迁移协程里跑，不能在其中新建 RAM 块）。
- **方案验证**：改用文件内存 + `cpr-reboot` + `x-ignore-shared` 后，挂起只用 **218 ms**（downtime 218 ms），
  `state.bin` 94 MB（仍有约 96 MB 内存被拷贝，多半是 address_space 的宿主内存块），`ram.img` 2 GB 不再拷贝。
- 图形 pipe 的 save/load 目前是 NULL：恢复后 SurfaceFlinger 的 GL 连接会断 → 必须做渲染器快照。

## 方案：内存放在文件里（CPR reboot 模式），只保存设备状态
客户机内存用共享的文件后端，内存本身就是文件，挂起时不用拷贝内存：
```
-object memory-backend-file,id=ram0,size=2G,mem-path=<snap>/ram.img,share=on -machine memory-backend=ram0 -m 2048
```
- **挂起**（QMP）：`stop` → `migrate-set-parameters {mode: cpr-reboot}` →
  `migrate-set-capabilities [{capability: x-ignore-shared, state: true}]` → `migrate {uri: file:<snap>/state.tmp}`
  → 等到 `postmigrate` → 改名为 `state.bin` → 写 `manifest.json`（`clean: true`）。
  内存页已在文件里（MAP_SHARED），由内核回写；`state.bin` 只有设备状态 + 渲染器状态（MB 级）。
- **恢复**：同样的 argv 加 `-incoming defer`，然后设置同样的 mode/capability → `migrate-incoming {uri: file:<snap>/state.bin}`
  → 迁移完成后 QEMU 自动继续运行。**在 `cont`/恢复运行之前**先把 manifest 改成 `clean: false`
  （运行中内存文件和磁盘都会变，快照随即失效）。
- **回到前台但进程还在**：直接 `cont`，同样先置 `clean: false`。
- **被杀时正在运行**（manifest 不是 clean）：丢弃快照，冷启动（相当于断电，ext4 日志会恢复）。
- **磁盘**：保持 raw；CPR reboot 要求挂起后到恢复前不改磁盘内容，满足。挂起前磁盘已 flush（`stop` 会 drain/flush）。
- **兼容性**：manifest 记录引擎/渲染器/镜像版本哈希和完整 argv 摘要；任一不同就作废，冷启动。

### 目录布局（`<snap>` = 运行目录下的 `snapshot/`）
| 文件 | 内容 |
|---|---|
| `ram.img` | 2 GB 稀疏文件，客户机内存本体 |
| `state.bin` | QEMU 迁移流：CPU、设备、pipe、`va-gfx` 段 |
| `gfx/` | 渲染器大块数据（color buffer/纹理），由 `va_gfx_snapshot_save` 写入 |
| `manifest.json` | `{version, engine, gfx, image, argv_hash, clean, saved_at}` |
| `last-frame.png` | 挂起时最后一帧，App 冷启动时先显示它（视觉上"秒开"） |

## 各部分要做的事
**引擎（hw/android，board）**
1. `goldfish_address_space` 加载不在协程里建 RAM：先读进缓冲，`post_load`/BH 里建 MR，或预分配。
2. 新增 `va-gfx` 迁移段（优先级高于 goldfish_pipe），save/load 时调用 `va_gfx_snapshot_save/load`，
   io 绑到 QEMUFile，aux_dir 来自机器属性 `snapshot-dir=`（gfx 子目录）。
3. 逐个验证 hw/android 与 services 的设备状态往返：pipe（含 qemud）、sync（时间线与未完成 fence 要和渲染器一致）、
   battery、events、address_space（只存已分配块）、va-vsock（恢复后 TRANSPORT_RESET，adbd 重连）。
4. 恢复后客户机墙上时间要校正（查官方模拟器 quickboot 怎么做）。
5. `tools/run-macos.sh` 增加 `--snapshot`（用文件内存 + 快照目录）、`tools/snapshot.py suspend|restore`。
6. macOS HVF 实测：挂起耗时、恢复到可交互耗时；恢复后 adb 可用、桌面立即重绘、打开应用、2 分钟无 watchdog；连续 3 轮。

**渲染器（gfx）**：实现 `va_gfx_snapshot_save/load`（`gfx/include/va_gfx.h`）——gfxstream
`RendererImpl::save/load` + aemu TextureSaver/TextureLoader，图形 pipe（opengles/GLProcessPipe/refcount）的
`AndroidPipeFuncs.save/load`，加载后重新 present 最后一帧；测试程序里跨进程 save→load 后继续渲染、像素一致。

**App**：生命周期——后台挂起（beginBackgroundTask）、前台 `cont`、冷启动时有效快照就 `-incoming`，否则冷启动；
首次开机完成后立即建快照；启动时先显示 `last-frame.png`；版本不符自动作废。模拟器实测启动到可交互耗时。
