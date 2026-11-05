# iQOO Neo8 Bootloader Unlock (V2301A / PD2301)

作者：酷安@TNTHe

![Platform](https://img.shields.io/badge/platform-Windows-0078D6)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE)
![Device](https://img.shields.io/badge/device-iQOO%20Neo8-00A98F)
![License](https://img.shields.io/badge/license-MIT-blue)

通过临时 Root 改写 `devinfo` 分区里的锁状态字节，让 ABL 在下次启动时按“已解锁”处理。

> **非官方解锁。可能导致全部数据被清空、无法开机，并影响保修、OTA、Play Integrity。**
> 仅支持本文列出的机型、固件范围和内核；不满足条件时工具会直接拒绝，请勿修改脚本绕过检查。

## Overview

这是一个面向 **iQOO Neo8（V2301A / PD2301）** 的 Windows 菜单式工具，适配自 iQOO Neo7 竞速版的 `devinfo` 解锁思路。

工具会：

- 检查机型、固件、内核、A/B 槽位、分区尺寸和 `devinfo` 结构。
- 自动备份 6 个分区：`devinfo`、`boot_<slot>`、`abl_<slot>`、`vbmeta_<slot>`、`xbl_<slot>`、`uefi_<slot>`。
- 只在电脑端生成“只差 2 字节”的 `devinfo` 候选，再推送到手机。
- 写入后立即回读 4096 字节，逐字节校验。
- 重启到 fastboot，用 `fastboot getvar unlocked` 验证，而不是只看 Android 属性。

工具不会：

- 提供临时 Root 提权链。
- 安装永久 Root。
- 刷 GSI / 第三方系统。
- 回锁，不保证救砖。

> 所谓“一键”是菜单式自动化：仍然需要手动输入 `UNLOCK <序列号>`，手机端还需要手动选择“清除所有数据”。

## Supported devices

| 项目 | 要求 |
| --- | --- |
| 机型 | `V2301A` |
| 设备代号 | `PD2301` |
| 固件 | `PD2301[_字母]_A_16.3.17.0.W10`（例如 `PD2301E_A_16.3.17.0.W10`）（其他版本理论也通用） |
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

> 固件名允许 `PD2301` 后带一个字母。其他版本号、其他机型、其他内核会直接拒绝。

## Repository layout

```text
.
├─ README.md
├─ LICENSE
├─ .gitignore
├─ docs/
│  ├─ neo8-unlock-guide.md      # 完整操作流程
│  ├─ principle.md              # devinfo / ABL / AVB 原理与证据
│  ├─ recovery.md               # 救砖与回退
│  └─ troubleshooting.md        # 常见报错
├─ neo8/
│  └─ tool/
│     ├─ start-tool.bat         # 主工具入口
│     ├─ env-check.bat          # 只读环境检测
│     ├─ Neo8BL.ps1             # 备份/写入/验证主逻辑
│     ├─ EnvCheck.ps1           # 只读检测脚本
│     └─ platform-tools/        # 自行下载
└─ scripts/
   ├─ abl_flags.py              # ABL 标志位分析（可选）
   ├─ abl_xref.py               # ABL 交叉引用（可选）
   └─ abl_crosscheck.py         # ABL 复核（可选）
```

`platform-tools` 是 Google 的 ADB/fastboot 二进制。为避免仓库体积和许可问题，建议从官方页面下载后放到 `neo8/tool/platform-tools/`。

## Quick start

```text
完整解压仓库
→ 进 neo8/tool
→ 双击 env-check.bat
→ 双击 start-tool.bat
→ 选 1 检查手机状态和 Root
→ 选 2 只备份（建议先做）
→ 选 3 备份并解锁
→ 输入 UNLOCK <你的序列号>
→ 等 fastboot 验证 unlocked: yes
→ 输入 SYSTEM 重启
→ 手机端清空数据
→ 首次开机后复核属性
```

详细步骤、手动命令和注意事项见 [`docs/neo8-unlock-guide.md`](docs/neo8-unlock-guide.md)。

首次开机后复核：

```text
adb shell getprop sys.boot_completed          # 1
adb shell getprop ro.boot.flash.locked        # 0
adb shell getprop ro.boot.vbmeta.device_state # unlocked
adb shell getprop ro.boot.verifiedbootstate   # orange
```

## Documentation

| 文档 | 内容 |
| --- | --- |
| [`docs/neo8-unlock-guide.md`](docs/neo8-unlock-guide.md) | 支持范围、手动流程、自动化菜单、永久 Root |
| [`docs/principle.md`](docs/principle.md) | 启动链、devinfo 结构、ABL 读取路径、`secure` 与 `unlocked` 的区别、数据清空原因 |
| [`docs/recovery.md`](docs/recovery.md) | fastboot / recovery / 9008 / 售后救砖与回退 |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | `adb pull` 路径错误、固件识别、Root、fastboot 等常见问题 |

### ABL analysis scripts

`scripts/` 里的三个脚本只做静态分析，不接触手机：

```text
python abl_flags.py <abl_payload.bin>
python abl_xref.py <abl_payload.bin>
python abl_crosscheck.py <abl_payload.bin>
```

它们需要 Python 3、`capstone`，以及已经从自己的 `abl_a.img` 解出的 `abl_payload.bin`（不是 `abl_a.img` 本身）。脚本不是解锁必需组件。

## Safety and limits

- 非官方解锁，可能无法启动、丢失全部数据。
- 已有 **两台独立设备** 的成功报告；第二台的完整日志/固件细节未公开，样本仍然有限。
- 自动流程仍是菜单式操作，写入前必须输入 `UNLOCK <序列号>`。
- 工具只写 `devinfo`，不写其他分区。不要额外调用 `fastboot flashing unlock`、回锁、格式化或 AVB 禁用命令作为“补充尝试”。
- `secure: yes` 与 `unlocked: yes` 可以同时存在，不是失败。
- 解锁状态是“状态位”层面的，不等于能刷 GSI/第三方系统。刷写能力需要另行验证。
- 非官方修改通常会影响保修、OTA、Play Integrity 和部分安全应用。

遇到问题先看 [`docs/troubleshooting.md`](docs/troubleshooting.md)。

## Privacy

不要提交以下内容：

```text
evidence/
root-patch/
stock-backups/
neo8/tool/backups/
neo8/tool/logs/
neo8/tool/env-report/
neo8/tool/platform-tools/
*.img
*.log
```

这些可能包含设备序列号、本机分区、个人路径或日志。发布前请脱敏。

## License

代码（`*.ps1`、`*.py`、`*.bat`）：MIT，见 [`LICENSE`](LICENSE)。  
文档：可沿用 MIT，或由维护者另行指定。

## Disclaimer

- 本项目与 vivo、iQOO、Qualcomm、Google 没有任何关联。
- 仅供学习、研究和在自己拥有的设备上使用；请遵守当地法律法规。
- 按“现状”提供，不提供任何明示或暗示担保。
- 使用本工具造成的设备损坏、数据丢失、保修失效、账号/支付/DRM 异常等后果，由使用者自行承担。
- 如果你不确定风险，请不要操作。
