# iQOO Neo8 解锁操作指南

> 适用：iQOO Neo8 `V2301A / PD2301`，固件 `PD2301[_字母]_A_16.3.17.0.W10`，内核 `5.10.246-gki-g8c3d0d7851ff`，A/B 分区。  
> 原理和证据见 [`principle.md`](principle.md)；验证记录见 [`verification.md`](verification.md)；救砖见 [`recovery.md`](recovery.md)。

## 1. 适用范围

| 项目 | 要求 |
| --- | --- |
| 机型 | `V2301A` |
| 设备代号 | `PD2301` |
| 固件 | `PD2301[_字母]_A_16.3.17.0.W10`（例如 `PD2301E_A_16.3.17.0.W10`） |
| 内核 | `5.10.246-gki-g8c3d0d7851ff` |
| 平台 | `taro`（骁龙 8+ 降频版） |
| 分区布局 | A/B（`_a` / `_b`） |
| 特殊点 | 没有 `init_boot`，init ramdisk 在 `boot_<slot>` |
| 起始状态 | `ro.boot.flash.locked=1`、`device_state=locked`、`verifiedbootstate=green` |
| 前提 | 已取得临时 Root，Shell / UID 2000 可用 `su` |

固件名允许 `PD2301` 后带一个字母；工具不接受其他版本号、其他机型和内核。不要为了“通过”修改检查逻辑。

> 目前已有两台独立设备的成功报告，但第二台的完整日志/固件细节未公开。样本仍然有限，不能保证所有批次和变体成功。

## 2. 前置准备

- Windows 10/11，PowerShell 5.1。
- `adb` / `fastboot`（建议使用 Platform-Tools 37.x；避开 Windows 上已知有文件截断问题的 36.0.0 / 36.0.1）。
- 只有目标手机通过 USB 连接；不要使用无线 ADB 或模拟器。
- 工具目录至少 512MB 空闲，并且路径尽量短、纯英文，例如 `D:\Neo8BL`。
- 手机已开启 USB 调试并授权电脑。
- 手机已取得临时 Root，Root 管理器已授权 Shell / UID 2000。
- 照片、聊天记录、账号恢复信息已另行备份。解锁大概率需要清空数据。

## 3. 只读检查

先确认环境和状态：

```text
adb shell getprop ro.product.model                 # V2301A
adb shell getprop ro.product.device                # PD2301
adb shell getprop ro.build.display.id              # PD2301[_字母]_A_16.3.17.0.W10
adb shell uname -r                                 # 5.10.246-gki-g8c3d0d7851ff
adb shell getprop ro.boot.slot_suffix              # _a 或 _b
adb shell getprop ro.boot.flash.locked             # 1
adb shell getprop ro.boot.vbmeta.device_state      # locked
adb shell getprop ro.boot.verifiedbootstate        # green
adb shell cat /proc/sys/kernel/random/boot_id
adb shell "su -c id"                               # 必须 uid=0
adb shell "su -c getenforce"
```

确认六个分区存在且尺寸正确：

```text
adb shell "su -c 'blockdev --getsize64 /dev/block/by-name/devinfo'"       # 4096
adb shell "su -c 'blockdev --getsize64 /dev/block/by-name/boot_a'"       # 100663296
adb shell "su -c 'blockdev --getsize64 /dev/block/by-name/abl_a'"        # 16777216
adb shell "su -c 'blockdev --getsize64 /dev/block/by-name/vbmeta_a'"     # 65536
adb shell "su -c 'blockdev --getsize64 /dev/block/by-name/xbl_a'"        # 7340032
adb shell "su -c 'blockdev --getsize64 /dev/block/by-name/uefi_a'"       # 5242880
```

`_b` 槽位把 `_a` 换成 `_b`；`devinfo` 不分槽。

## 4. 手动流程

### 4.1 备份六个分区

对 `devinfo`、`boot_<slot>`、`abl_<slot>`、`vbmeta_<slot>`、`xbl_<slot>`、`uefi_<slot>`：

```text
adb shell "su -c 'dd if=/dev/block/by-name/<P> of=<REMOTE>/<P>.img bs=4096 && chmod 644 <REMOTE>/<P>.img'"
adb shell "su -c 'sha256sum <REMOTE>/<P>.img'"
adb pull <REMOTE>/<P>.img <CASE>/<P>.img
```

要求：

- 手机端分区尺寸与记录一致。
- 电脑文件长度与手机端一致。
- 电脑 SHA-256 与手机端 SHA-256 一致。
- 任一不符即停止，不要换用别人的镜像补齐。

### 4.2 只在电脑生成候选

读取本次的 `devinfo.img`，确认：

```python
assert len(original) == 4096
assert original[:13] == b"ANDROID-BOOT!"
assert original[0x0D] == 0 and original[0x0E] == 0
assert original[0x0F] == 1 and original[0x90] == 1
```

然后只改两个字节：

```python
candidate = bytearray(original)
candidate[0x0D] = 1
candidate[0x0E] = 1
assert [i for i, (a, b) in enumerate(zip(original, candidate)) if a != b] == [13, 14]
```

保存为 `devinfo-unlocked-candidate.img`，保留原件，并记录候选哈希。

### 4.3 写入前复核

写入前再次确认：

- 序列号、机型、固件、内核、槽位和起始锁定属性未变。
- `boot_id` 与备份时相同；如果重启过，必须重新检查和备份。
- Root 仍有效。
- 手机当前 `devinfo` 哈希等于本次备份原件哈希。
- 候选与原件只有偏移 13、14 不同。

### 4.4 推送、写入、回读

```text
adb push <CASE>/devinfo-unlocked-candidate.img <REMOTE>/candidate.img
adb shell "su -c 'sha256sum <REMOTE>/candidate.img'"      # 必须等于候选哈希

adb shell "su -c 'dd if=<REMOTE>/candidate.img of=/dev/block/by-name/devinfo bs=4096 count=1 conv=notrunc && sync'"
adb shell "su -c 'dd if=/dev/block/by-name/devinfo of=<REMOTE>/readback.img bs=4096 && chmod 644 <REMOTE>/readback.img'"
adb pull <REMOTE>/readback.img <CASE>/devinfo-readback.img
```

验收：

- 回读 4096 字节。
- 逐字节等于候选。
- 与原件相比只有偏移 13、14 不同。

写入开始后如果超时、断线、报错或回读不一致：**不要重启、不要重试、不要自行还原、不要清数据**。保留连接、备份和日志，先排查。

### 4.5 从 bootloader 验证

```text
adb reboot bootloader
fastboot devices
fastboot getvar unlocked      # 必须出现 unlocked: yes
fastboot getvar secure        # secure: yes 不否定解锁
fastboot getvar product       # taro
```

得到明确的 `unlocked: yes` 才算解锁成功。若仍 locked 或输出含糊，不要继续刷写。

### 4.6 返回系统与清数据

```text
fastboot reboot
```

按屏幕提示操作：

1. 可能出现英文解锁警告。
2. 若进入 vivo“系统受损 / 修复”界面，参考流程选择 **“清除所有数据”**，不要选“修复系统”。
3. 清空会删除全部资料。出现其他报错时先停下排查。

### 4.7 首次开机复核

```text
adb shell getprop sys.boot_completed          # 1
adb shell getprop ro.boot.flash.locked        # 0
adb shell getprop ro.boot.vbmeta.device_state # unlocked
adb shell getprop ro.boot.verifiedbootstate   # orange
```

临时 Root 在重启/清数据后消失是正常的。解锁 BL 不等于永久 Root。

## 5. 自动化工具

目录：`neo8/tool/`

- `env-check.bat`：只读检测电脑、驱动、连接、机型、Root。
- `start-tool.bat`：菜单 1 检查；2 只备份；3 备份并解锁；4 fastboot 验证/返回系统。

使用步骤：

1. 把 `platform-tools` 完整解压到 `neo8/tool/platform-tools/`，或按提示输入路径。
2. 双击 `env-check.bat`，处理未通过项。
3. 双击 `start-tool.bat`，先选 `1` 检查，再选 `2` 只备份。
4. 备份成功后选 `3`，输入：

```text
UNLOCK <你的设备序列号>
```

5. 工具会写入 `devinfo`、回读校验、重启到 fastboot，并等待同一序列号。
6. 确认 `unlocked: yes` 后输入 `SYSTEM` 返回系统；手机端按提示清空数据。

工具会把备份放在 `neo8/tool/backups/<serial>/<time>/`，日志放在 `neo8/tool/logs/`，环境检测报告放在 `neo8/tool/env-report/`。

> 如果 `adb pull` 报 `cannot create file/directory`，先把工具移到短英文路径（如 `D:\Neo8BL`），并检查磁盘空间/云盘/杀毒软件。详见 [`troubleshooting.md`](troubleshooting.md)。

## 6. 后续永久 Root（可选）

本机没有 `init_boot`，ramdisk 在 `boot_<slot>`。

1. 从自己的手机/当前固件提取 `boot_<slot>`（工具备份里有）。
2. 用 KernelSU / SukiSU 管理器选择 boot 镜像打补丁。
3. 刷入你自己的补丁：

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

- OTA 会覆盖 `boot_<slot>`，升级后需要重新打补丁。
- 不要分发或刷入别人做好的 patched boot 镜像。
- 如果 AVB/verity 仍强制校验，补丁后可能无法开机；这属于额外风险。

## 7. 风险

- 非官方解锁，可能无法启动、丢失全部数据。
- 影响保修、OTA、Play Integrity 和部分安全应用。
- 现有成功报告仍有限；不同批次、固件变体不保证成功。
- 工具只验证 BL 状态位，不验证是否能刷 GSI/第三方系统。
- 写入后回读不一致时不要重启、不要重复写入。

## 8. 相关文档

- [`principle.md`](principle.md)：devinfo/ABL/AVB 原理与证据。
- [`verification.md`](verification.md)：两台设备的验证状态。
- [`recovery.md`](recovery.md)：救砖与回退。
- [`troubleshooting.md`](troubleshooting.md)：常见报错。
