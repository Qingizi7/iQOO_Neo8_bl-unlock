# iQOO Neo8 解锁原理详解

> 本文解释 `devinfo` 状态位方案为什么能让 ABL 返回 `unlocked: yes`，以及它为什么不是官方/硬件级解锁。  
> 适用机型、固件和操作步骤见 [`neo8-unlock-guide.md`](neo8-unlock-guide.md)。

## 1. 一句话结论

ABL 在启动时把 BL 锁状态存放在一个可写的 4KB `devinfo` 分区里，而不是只依赖一次性熔丝或厂商解锁令牌。临时 Root 提供对该分区的写权限后，把 `0x0D/0x0E` 两个标志从 `00 00` 改成 `01 01`，ABL 下次启动就会按“已解锁 + 已关键解锁”处理。

这不是破解 ABL 签名，也不是官方 `fastboot flashing unlock` 流程。

## 2. 启动链中的位置

```text
PBL → XBL → ABL（Android Bootloader）→ boot / vbmeta → Android
```

- `PBL`、`XBL` 是更早的 Qualcomm 启动阶段。
- `ABL` 负责 fastboot 命令、分区刷写策略、解锁状态判断和启动镜像校验。
- `boot` / `vbmeta` 是 Android 启动镜像和验证元数据。
- Android 里的 `ro.boot.flash.locked`、`ro.boot.vbmeta.device_state`、`ro.boot.verifiedbootstate` 是 ABL 传给 Android 的状态反映，不是独立证据。

## 3. devinfo 分区结构

参考机的 `devinfo` 固定为 4096 字节，起始布局如下：

| 偏移 | 长度 | 内容 | 说明 |
| --- | --- | --- | --- |
| `0x00–0x0C` | 13 | `ANDROID-BOOT!` | 13 字节 magic |
| `0x0D` | 1 | 解锁标志 | `00` = 锁定；非 `00` = 已解锁 |
| `0x0E` | 1 | 关键解锁标志 | `00` = 未关键解锁；非 `00` = 已关键解锁 |
| `0x0F` | 1 | 结构版本 | 参考机为 `1` |
| `0x90` | 1 | 初始化标记 | 参考机为 `1` |

参考机写入前是：

```text
ANDROID-BOOT! 00 00 01 ... 0x90=01
```

解锁候选只改两个位置：

```text
offset 0x0D: 00 → 01
offset 0x0E: 00 → 01
```

候选文件与原件逐字节比较，必须只有偏移 13（`0x0D`）和 14（`0x0E`）不同；`0x0F`、`0x90` 保持不变。

## 4. ABL 如何读取这些标志

参考机 `abl_a` 解出 EFI/PE 载荷后，静态分析可以看到这些行为：

| 参考地址 | 作用 |
| --- | --- |
| `0x4A074` | 校验 `devinfo` 前 13 字节是否为 `ANDROID-BOOT!` |
| `0x49618` | 读取 `devinfo[0x0D]` 并返回布尔值的函数入口 |
| `0x49660` | 读取 `devinfo[0x0E]` 并返回布尔值的函数入口 |
| `0x49A2C` / `0x49B04` | 写回 `0x0D` / `0x0E` 的路径 |
| `0x572C` | `0x0D` 非零时走 `Device is unlocked, Skipping boot verification` |
| `0x6C7FC` / `0x6D9F8` | fastboot 解锁路径同时检查两个标志 |
| `0x6E4C4` / `0x6E4E4` | 分别打印 `Device unlocked` / `Device critical unlocked` |

ABL 里还能看到这些字符串：

```text
ANDROID-BOOT!
Device Magic does not match
Unable to Write Device Info
VBRwDeviceState
Device unlocked
Device critical unlocked
Device is unlocked, Skipping boot verification
```

在部分提取结果里，函数入口和内部实际 `ldrb` 指令的地址会不同，例如 `0x49618` 是函数入口，内部 `ldrb [x8, #0xd]` 可能落在 `0x496DC` 附近；`0x49660` 与 `0x49724` 也是同样的关系。地址取决于 `abl_payload.bin` 的提取方式和固件版本，**不要把这些地址当作跨固件常量**。`scripts/` 下的脚本用于在自己的 payload 上复核，不是解锁流程的必需组件。

## 5. 为什么两个字节就能生效

ABL 的判断逻辑可以概括为：

```text
if devinfo[0x0D] != 0:
    device is unlocked
    skip boot verification
if devinfo[0x0E] != 0:
    device is critical unlocked
```

因此：

- `0x0D` 非零 → ABL 认为普通解锁已经完成，并跳过启动镜像验证。
- `0x0E` 非零 → ABL 认为关键分区也处于解锁状态。
- fastboot 随后返回 `unlocked: yes`。
- 启动时 `verifiedbootstate` 变成 `orange`，Android 属性变成 `unlocked`。

写入本身不是“只写两个字节”：`dd ... bs=4096 count=1 conv=notrunc` 物理上会重写整个 4096 字节分区；只是候选与原件的**逻辑差异**恰好只有两个字节。

## 6. 为什么 `secure: yes` 仍然存在

`fastboot getvar secure` 的 `secure: yes` 表示设备的 secure boot / 签名启动链仍然存在，不等于“BL 仍然锁定”。

本方案：

- 没有烧熔丝。
- 没有写厂商解锁令牌。
- 没有修改 `vbmeta`、`boot`、`abl`、`xbl`、`uefi`。
- 只改了 ABL 读取的 `devinfo` 状态源。

所以 `unlocked: yes` 和 `secure: yes` 可以同时出现，这不是失败。它说明解锁发生在“状态位”层面，而不是关闭整个安全启动体系。

## 7. Android 属性只是反映

首次开机后可能看到：

```text
ro.boot.flash.locked        = 0
vbmeta.device_state         = unlocked
ro.boot.verifiedbootstate   = orange
```

这些属性来自 ABL 传给 Android 的启动参数。它们可以和 fastboot 结果互相印证，但不能代替 `fastboot getvar unlocked` 的原始输出。工具因此坚持在 fastboot 阶段验证 `unlocked: yes`。

## 8. 为什么需要临时 Root

`/dev/block/by-name/devinfo` 是块设备，普通 `adb shell`（UID 2000）没有写权限；临时 Root 提供 `uid=0` 的 `dd` 写原语。

临时 Root 的来源不在本仓库内，本工具只负责“已经有临时 Root 之后”的备份、写入和验证。临时 Root 在重启或清空数据后消失，但 `devinfo` 的改动已经写入 flash，所以解锁状态会保留。

## 9. 为什么解锁后要清数据

锁状态从 `locked` 变成 `unlocked` 后，旧 userdata 的加密密钥通常不再可用：Android 的 KeyMint/TEE 会把设备锁状态作为密钥绑定条件之一。参考机因此在 vivo“系统受损 / 修复”界面选择“清除所有数据”后，原系统才正常启动。

这是解锁的**后果**，不是解锁的手段。工具不会自动擦除 userdata，具体清除操作由机主在手机端完成。不同机型/版本的修复界面和密钥行为可能不同，出现异常画面时应先排查，不要盲目清空或“修复系统”。

## 10. 这不是什么

- **不是官方解锁令牌流程**：没有走 `fastboot flashing unlock`，没有厂商解锁令牌。
- **不是熔丝级解锁**：从可写 `devinfo` 生效来看，这条路径没有依赖一次性熔丝；也没有证据表明烧了熔丝。
- **不是关闭 secure boot**：`secure: yes` 仍在。
- **只对匹配的固件布局可靠**：`devinfo` 结构、ABL 逻辑和分区尺寸随固件变化；工具会检查机型、内核、槽位、尺寸和 `devinfo` 结构，不匹配就拒绝。

## 11. 证据链

一次完整的手动解锁应保留这些证据：

1. 写入前 `devinfo` 为 `ANDROID-BOOT! 00 00 01`，`0x90=1`。
2. 候选与原件逐字节比较，只有偏移 13、14 不同。
3. 写入后回读 4096 字节，逐字节等于候选。
4. `fastboot getvar unlocked` 返回独立行 `unlocked: yes`；`secure: yes` 可同时存在。
5. 清数据后系统正常启动，Android 属性为 `0 / unlocked / orange`。
6. 仓库 README 记录了两台独立设备的成功报告；第二台未公开完整日志。

## 12. 复现分析（可选）

`scripts/` 里的三个静态脚本用于复核 ABL：

```text
python abl_flags.py <abl_payload.bin>
python abl_xref.py <abl_payload.bin>
python abl_crosscheck.py <abl_payload.bin>
```

它们需要：

- Python 3
- `capstone`
- 已经从自己的 `abl_a.img` 解出的 EFI/PE 载荷 `abl_payload.bin`（不是 `abl_a.img` 本身）

脚本输出的是本次 payload 的 PE 镜像地址，不同固件/提取方式可能不同。它们不参与解锁，也不需要安装到手机上。
