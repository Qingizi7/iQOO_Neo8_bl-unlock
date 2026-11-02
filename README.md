# iQOO Neo8 BL 解锁工具（V2301A / PD2301）

![Platform](https://img.shields.io/badge/platform-Windows-0078D6)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE)
![Device](https://img.shields.io/badge/device-iQOO%20Neo8-00A98F)
![Status](https://img.shields.io/badge/status-single--device%20tested-orange)

通过临时 Root 改写 `devinfo` 分区里的锁状态字节，让 ABL 在下次启动时按“已解锁”处理。

> **非官方方案。可能导致全部数据被清空、无法开机，并影响保修、OTA、Play Integrity。**
> 仅支持本文列出的机型、固件和内核；不满足条件时工具会直接拒绝，请勿修改脚本绕过检查。

---

## 目录

- [项目简介](#项目简介)
- [支持范围](#支持范围)
- [原理（简版）](#原理简版)
- [目录结构](#目录结构)
- [快速开始](#快速开始)
- [菜单说明](#菜单说明)
- [使用前检查清单](#使用前检查清单)
- [重要风险与限制](#重要风险与限制)
- [解锁后的永久 Root（可选）](#解锁后的永久-root可选)
- [救砖与回退](#救砖与回退)
- [隐私：不要提交的文件](#隐私不要提交的文件)
- [常见问题](#常见问题)
- [验证状态](#验证状态)
- [贡献](#贡献)
- [License](#license)
- [免责声明](#免责声明)

---

## 项目简介

这是一个面向 **iQOO Neo8（V2301A / PD2301）** 的 Windows 菜单式工具，适配自 iQOO Neo7 竞速版的 devinfo 解锁思路。

它能做：

- 检查机型、固件、内核、A/B 槽位、分区尺寸和 `devinfo` 结构。
- 自动备份 6 个分区：`devinfo`、`boot_<slot>`、`abl_<slot>`、`vbmeta_<slot>`、`xbl_<slot>`、`uefi_<slot>`。
- 只在电脑端生成“只差 2 字节”的 `devinfo` 候选，再推送到手机。
- 写入后立即回读 4096 字节，逐字节校验。
- 重启到 fastboot，用 `fastboot getvar unlocked` 验证，而不是只看 Android 属性。
- 提供环境检测、只备份、备份并解锁、fastboot 验证/返回系统等菜单。

它不能做：

- 不提供临时 Root 提权链。
- 不安装永久 Root。
- 不刷 GSI / 第三方系统。
- 不回锁，不保证救砖。

> 所谓“一键”是菜单式自动化：仍然需要手动输入 `UNLOCK <序列号>`，手机端还需要手动选择“清除所有数据”。

---

## 支持范围

| 项目 | 要求 |
| --- | --- |
| 机型 | `V2301A` |
| 设备代号 | `PD2301` |
| 固件 | `PD2301_A_16.3.17.0.W10` |
| 内核 | `5.10.246-gki-g8c3d0d7851ff` |
| 平台 | `taro`（骁龙 8+ 降频版） |
| Android | 16 / OriginOS 6 |
| 分区布局 | A/B（`_a` / `_b` 自动识别） |
| 特殊点 | 没有 `init_boot`，init ramdisk 位于 `boot_<slot>`（boot 镜像 v4） |
| 起始状态 | `ro.boot.flash.locked=1`、`vbmeta.device_state=locked`、`verifiedbootstate=green` |
| 前提 | 已取得临时 Root，Shell / UID 2000 可用 `su` |
| 电脑 | Windows 10/11 + PowerShell 5.1 + USB 数据线 |
| 空间 | 工具目录至少 512MB 空闲 |

分区尺寸（工具会逐项检查）：

| 分区 | 大小（字节） |
| --- | --- |
| `devinfo` | 4096 |
| `boot_<slot>` | 100663296 |
| `abl_<slot>` | 16777216 |
| `vbmeta_<slot>` | 65536 |
| `xbl_<slot>` | 7340032 |
| `uefi_<slot>` | 5242880 |

> 其他机型、固件、内核或槽位会直接拒绝。**不要为了“通过”修改 `Neo8BL.ps1` 里的 Profile 或删除检查。**

---

## 原理（简版）

ABL 把 BL 锁状态存放在独立的 4KB `devinfo` 分区：

| 偏移 | 内容 |
| --- | --- |
| `0x00–0x0C` | `ANDROID-BOOT!`（13 字节 magic） |
| `0x0D` | 解锁标志（`00` = 锁定，非 `00` = 已解锁） |
| `0x0E` | 关键解锁标志（`00` = 未关键解锁） |
| `0x0F` | 结构版本 = 1 |
| `0x90` | 初始化标记 = 1 |

工具只把 `0x0D`、`0x0E` 从 `00 00` 改成 `01 01`，其他字节不动。ABL 下次启动读取这两个字节后，按“已解锁 + 已关键解锁”处理，fastboot 返回 `unlocked: yes`。

本机 `abl_a` 解出 EFI LZMA 后反汇编确认：

- `0x49618` / `0x49660`：分别读取 `devinfo[0x0D]` / `devinfo[0x0E]`。
- `0x49A2C` / `0x49B04`：分别写回这两个标志。
- `0x572C`：`0x0D` 非零时走 `Device is unlocked, Skipping boot verification`。
- `0x6C7FC` / `0x6D9F8`：fastboot 解锁路径同时检查两个标志。
- `0x6E4C4` / `0x6E4E4`：分别打印 `Device unlocked` / `Device critical unlocked`。

这不是破解 ABL 签名，也不是官方解锁令牌流程：

- 没有烧熔丝、没有厂商解锁令牌。
- `secure: yes` 和 `unlocked: yes` 可以同时存在。
- 工具不写 `boot`、`vbmeta`、`abl`、`xbl`、`uefi`，只写 `devinfo`。
- 它只证明 BL 状态位变成“已解锁”，**没有验证能否刷入未签名/第三方镜像**。

更完整的适配记录见 [`04_Neo8方案/iQOO_Neo8_解锁BL方案.md`](04_Neo8方案/iQOO_Neo8_解锁BL方案.md)。

---

## 目录结构

```text
.
├─ README.md
├─ 04_Neo8方案/
│  ├─ iQOO_Neo8_解锁BL方案.md
│  └─ 工具/
│     ├─ 环境检测.bat          # 只读环境检测
│     ├─ 启动工具.bat          # 主工具入口
│     ├─ EnvCheck.ps1          # 只读检测脚本
│     ├─ Neo8BL.ps1            # 备份/写入/验证主逻辑
│     └─ platform-tools/       # 建议作为 Release 附件，不建议直接入库
├─ 05_工具与脚本/
│  ├─ abl_flags.py             # ABL 标志位分析（可选）
│  ├─ abl_xref.py              # ABL 交叉引用（可选）
│  └─ abl_crosscheck.py        # ABL 复核（可选）
└─ LICENSE
```

`platform-tools` 是 Google 的 ADB/fastboot 二进制。为避免仓库体积和许可问题，建议通过 GitHub Release 附件分发，或让使用者从官方页面下载后放到 `04_Neo8方案/工具/platform-tools/`。

---

## 快速开始

```text
完整解压仓库
→ 进 04_Neo8方案/工具
→ 双击 环境检测.bat
→ 双击 启动工具.bat
→ 选 1 检查手机状态和 Root
→ 选 3 备份并解锁
→ 输入 UNLOCK <你的序列号>
→ 等 fastboot 验证 unlocked: yes
→ 输入 SYSTEM 重启
→ 手机端清空数据
→ 首次开机后复核属性
```

### 1. 准备电脑

- Windows 10/11，PowerShell 5.1。
- 建议使用仓库/Release 提供的 ADB 37.x；避免 ADB `36.0.0` / `36.0.1` 的 Windows 文件截断问题。
- 只有一台目标手机通过 USB 连接；不要使用无线 ADB、模拟器或多台设备。
- 工具目录所在磁盘至少 512MB 空闲。

### 2. 准备手机

- 开启 USB 调试，并在手机上允许这台电脑。
- 先取得**临时 Root**；本工具不提供提权链。
- 在 Root 管理器中给 **Shell / `com.android.shell` / UID 2000** 授权。
- 用 `adb shell "su -c id"` 确认返回 `uid=0`。
- 另行备份照片、聊天记录、账号恢复信息。工具的分区备份**不是**个人资料备份。

### 3. 运行环境检测

双击 `环境检测.bat`。它只读，不重启、不写分区。检查项包括：

- PowerShell、ADB/fastboot 是否可运行。
- 磁盘空间是否足够。
- Windows USB 驱动线索。
- 手机是否已授权、是否离线。
- 机型、固件、内核、槽位。
- Shell Root 是否可用。

报告保存在 `04_Neo8方案/工具/环境检测报告/`。显示“fastboot 驱动尚未实测”是正常的：手机还在正常系统，无法同时验证 fastboot 模式。

### 4. 启动工具

双击 `启动工具.bat`，选择：

1. `1` 检查手机状态和 Root（不改分区）
2. `2` 完整备份分区（不解锁）
3. `3` 备份并解锁 BL（会写分区）
4. `4` fastboot 验证解锁状态 / 返回系统
5. `5` 查看流程与风险
6. `0` 退出

建议先选 `1`，确认通过后再选 `3`。也可以先用 `2` 单独做一次备份。

### 5. 执行解锁（菜单 3）

工具会：

1. 再次校验机型、固件、内核、槽位、起始 `1/locked/green`。
2. 自动备份 6 个分区到 `备份/<序列号>/<时间>/`。
3. 生成本次专用的 `devinfo-unlocked-candidate.img`，确保只改 `0x0D/0x0E`。
4. 要求输入：

```text
UNLOCK <你的设备序列号>
```

直接回车会取消。这个确认不能通过参数跳过。

5. 推送候选、手机端 `sha256sum` 校验、`dd` 写入 `devinfo`、立即回读 4096 字节逐字节比对。
6. 校验通过后 `adb reboot bootloader`，等待同一序列号进入 fastboot（最多 60 秒）。
7. 执行：

```text
fastboot getvar unlocked
fastboot getvar secure
fastboot getvar product
```

必须出现独立的 `unlocked: yes`。`secure: yes` 同时出现是正常的，不是失败。

> 写入开始后如果超时、断线、报错或回读不一致：**不要重启、不要重试、不要自行还原、不要清数据**。保留连接、日志和备份，先排查。

### 6. 返回系统与清数据

验证通过后，按提示输入 `SYSTEM` 回车重启。手机可能：

1. 显示英文解锁警告。
2. 进入 vivo“系统受损 / 修复”界面。

参考流程是在该界面选择 **“清除所有数据”**，不要选“修复系统”。清空会删除全部资料。出现不同画面或错误时先停下排查，不要盲目清空或修复。

### 7. 首次开机复核

首次开机后重新开启 USB 调试并授权电脑，然后检查：

```text
adb shell getprop sys.boot_completed          # 1
adb shell getprop ro.boot.flash.locked        # 0
adb shell getprop ro.boot.vbmeta.device_state # unlocked
adb shell getprop ro.boot.verifiedbootstate   # orange
```

临时 Root 在重启/清数据后消失属于正常现象。解锁 BL 不等于永久 Root。

---

## 菜单说明

| 菜单 | 作用 | 是否写分区 |
| --- | --- | --- |
| `1` | 检查手机状态和 Root | 否 |
| `2` | 完整备份 6 个分区 | 否 |
| `3` | 备份并解锁 BL | 是，仅写 `devinfo` |
| `4` | fastboot 验证解锁状态 / 返回系统 | 否（`SYSTEM` 会重启） |
| `5` | 查看流程与风险 | 否 |
| `0` | 退出 | 否 |

菜单 `4` 适用于手机已经手动进入 fastboot 的情况：先 `fastboot devices` 确认连接，再运行 `启动工具.bat` 选 `4`。

---

## 使用前检查清单

- [ ] 机型是 `V2301A / PD2301`。
- [ ] 固件是 `PD2301_A_16.3.17.0.W10`。
- [ ] 内核是 `5.10.246-gki-g8c3d0d7851ff`。
- [ ] 手机是 A/B 布局，`ro.boot.slot_suffix` 为 `_a` 或 `_b`。
- [ ] 初始状态是 `1 / locked / green`。
- [ ] 已取得临时 Root，`su -c id` 返回 `uid=0`。
- [ ] Root 管理器已授权 Shell / UID 2000。
- [ ] 只连接目标手机，USB 调试已授权。
- [ ] 工具目录至少 512MB 空闲。
- [ ] 照片、聊天记录、账号恢复信息已另行备份。
- [ ] 已理解可能清空数据、无法开机、影响保修/OTA/Play Integrity。
- [ ] 没有使用别人的 `devinfo`、`persist`、`modem` 或整机备份。

---

## 重要风险与限制

- 这是**非官方解锁**，可能无法启动、丢失全部数据。
- 目前只有**一台 V2301A 的真实手动成功案例**；完整自动写入流程**没有在第二台锁定 Neo8 上实测**，不能保证成功。
- 该版本没有外部参考哈希，只校验机型/固件/内核/槽位/分区尺寸/`devinfo` 结构，并做本次备份自校验。它不能发现“同尺寸但被篡改”的 boot/abl；不要删除检查或强行绕过。
- 工具只写 `devinfo`，不写其他分区。不要额外调用 `fastboot flashing unlock`、回锁、格式化或 AVB 禁用命令作为“补充尝试”。
- `secure: yes` 与 `unlocked: yes` 可以同时存在，不是失败。
- 解锁状态是“状态位”层面的，不等于能刷 GSI/第三方系统。刷写能力需要另行验证。
- 非官方修改通常会影响保修、OTA、Play Integrity 和部分安全应用。

---

## 解锁后的永久 Root（可选）

本机没有 `init_boot`，ramdisk 在 `boot_<slot>`。参考流程：

1. 从**你自己的手机/当前固件**提取 `boot_<slot>`（工具备份里有）。
2. 用 KernelSU / SukiSU 管理器选择 boot 镜像打补丁。
3. 刷入你自己的补丁镜像：

```text
fastboot flash boot_a <你自己的补丁镜像>
fastboot reboot
```

4. 验证：

```text
adb shell "su -c id"
# uid=0(root)，上下文 u:r:ksu:s0
```

注意：

- 系统 OTA 会覆盖 `boot_<slot>`，升级后需要重新提取、重新打补丁。
- **不要分发或刷入别人做好的 patched boot 镜像**；每台设备/每个固件都应使用自己的原厂 boot 制作补丁。
- 如果 AVB/verity 仍强制校验，打补丁后可能无法开机；这属于额外风险，不在本工具范围内。

---

## 救砖与回退

工具生成的备份位于：

```text
04_Neo8方案/工具/备份/<序列号>/<时间>/
```

包含：

```text
devinfo.img
boot_<slot>.img
abl_<slot>.img
vbmeta_<slot>.img
xbl_<slot>.img
uefi_<slot>.img
操作状态.json
```

### 还能进 fastboot

按“影响最小”的顺序回刷，刷一个、重启测一次：

```text
fastboot flash devinfo devinfo.img
fastboot flash boot_a boot_a.img
fastboot flash vbmeta_a vbmeta_a.img
```

> 实际分区名以你的槽位为准（`_a` 或 `_b`）；不要猜分区名。
> `abl/xbl/uefi` 是 bootloader 链，非必要不要写；写坏会把软砖变硬砖。

### 进不了 fastboot

- 尝试原厂 recovery 的“修复系统/清除数据”；清除数据会丢失资料。
- 只能进 Qualcomm 9008 时，需要匹配的 firehose programmer + 完整固件 `rawprogram/patch XML`，用 QFIL/QPST 或等效工具恢复。
- vivo/Qualcomm 新机可能要求签名或授权 firehose；公开工具未必能进。
- 没有 fastboot、没有 9008 时，优先官方售后/授权维修点。

**不要**把本仓库或资料包里的 `03_原厂分区备份` 直接刷到另一台手机；那些是作者本机的镜像，`devinfo` 更是每机不同。救砖优先使用你自己的备份或官方同版本固件。

---

## 隐私：不要提交的文件

上传 GitHub 前，确认仓库里**没有**以下内容：

```text
01_解锁证据/                 # 含设备序列号、本机 devinfo、state.json、Windows 路径
02_Root补丁/                 # 含作者本机的 patched boot
03_原厂分区备份/             # 含作者本机的 boot/abl/vbmeta/xbl/uefi/devinfo
04_Neo8方案/工具/备份/       # 运行后生成，含序列号与本机分区
04_Neo8方案/工具/运行记录/   # 日志，含序列号、命令输出
04_Neo8方案/工具/环境检测报告/
04_Neo8方案/工具/platform-tools/  # 二进制，建议 Release 附件
SHA256SUMS.txt               # 若对应作者本机资料，发布前删除或重新生成
```

建议的 `.gitignore`：

```gitignore
01_解锁证据/
02_Root补丁/
03_原厂分区备份/
04_Neo8方案/工具/备份/
04_Neo8方案/工具/运行记录/
04_Neo8方案/工具/环境检测报告/
04_Neo8方案/工具/platform-tools/
*.img
*.log
```

> 如果确实要公开证据，请先去掉序列号、Windows 用户名/路径、设备备份和个人日志。只发布工具、文档和脱敏后的适配记录。

---

## 常见问题

| 情况 | 处理 |
| --- | --- |
| 找不到 adb/fastboot | 把完整 `platform-tools` 放到 `04_Neo8方案/工具/`，或按提示输入路径 |
| 手机未授权 | 解锁屏幕，在 USB 调试提示中允许这台电脑 |
| 手机离线 | 检查数据线、USB 调试、驱动和当前模式 |
| 正常系统能连，fastboot 连不上 | 检查 fastboot 驱动；不要重新执行解锁；可手动进 fastboot 后用菜单 4 |
| Shell 没有 Root | 检查临时 Root 是否仍有效，并在管理器中授权 Shell / UID 2000 |
| 提示系统不适配 | 停止操作；不要修改脚本强行继续 |
| 提示已解锁 | 不要重复解锁；用菜单 4 只读验证 |
| 写入后报错/验证失败 | 不要重启、不要重复写入；保留连接、日志和备份后排查 |
| `secure: yes` | 正常，不否定 `unlocked: yes` |
| 清数据后临时 Root 消失 | 正常；解锁 BL 不等于永久 Root |
| 想刷 GSI | 本工具不包含 GSI 刷写，也不验证刷写能力；不要把它当后续步骤 |

---

## 验证状态

- 手动流程在一台 `V2301A / PD2301`、`PD2301_A_16.3.17.0.W10`、`5.10.246-gki-g8c3d0d7851ff` 上成功。
- 结果：`devinfo` 回读逐字节等于候选；fastboot `unlocked: yes`；`secure: yes`；`product: taro`；清数据后系统正常启动，Android 属性为 `0 / unlocked / orange`。
- 自动写入流程只做过离线校验，**没有在第二台锁定 Neo8 上完整实测**。
- 只有这一台设备的成功案例；不保证其他设备、其他固件或批次成功。

---

## 贡献

- 欢迎提交不包含个人信息、设备备份、序列号、日志的 PR。
- 新机型/新固件适配请提供完整的机型、固件、内核、槽位、分区尺寸和 `devinfo` 结构；不要直接改 Profile 绕过检查。
- 不接受“帮我解锁某台设备”的请求；本项目只提供工具和文档。

---

## License

建议：

- 代码（`*.ps1`、`*.py`、`*.bat`）：MIT
- 文档与教程：CC BY-NC-SA 4.0

如不需要限制商用，可统一改为 MIT。请在仓库根目录补充对应的 `LICENSE` 文件。

---

## 免责声明

- 本项目与 vivo、iQOO、Qualcomm、Google 没有任何关联。
- 仅供学习、研究和在自己拥有的设备上使用；请遵守当地法律法规。
- 按“现状”提供，不提供任何明示或暗示担保。
- 使用本工具造成的设备损坏、数据丢失、保修失效、账号/支付/DRM 异常等后果，由使用者自行承担。
- 如果你不确定风险，请不要操作。
