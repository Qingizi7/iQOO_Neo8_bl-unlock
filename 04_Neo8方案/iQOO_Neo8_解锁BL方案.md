# iQOO Neo8（V2301A / PD2301）临时 Root 解锁 BL 方案

本方案由 iQOO Neo7 竞速版的思路适配而来，但所有指纹、分区名和验证均以本机实测为准。本机已完成一次真实解锁。

## 0. 适用范围（不满足即停止）

| 项目 | 要求 |
| --- | --- |
| 型号 | `V2301A` |
| 设备代号 | `PD2301` |
| 固件 | `PD2301[_字母]_A_16.3.17.0.W10`（本机参考 `PD2301_A_16.3.17.0.W10`） |
| 内核 | `5.10.246-gki-g8c3d0d7851ff` |
| 平台 | `taro`（骁龙 8+ 降频版） |
| 分区布局 | A/B（`boot_a/b`、`abl_a/b`、`vbmeta_a/b`、`xbl_a/b`、`uefi_a/b`） |
| 初始锁定状态 | `ro.boot.flash.locked=1`、`vbmeta.device_state=locked`、`verifiedbootstate=green` |
| 前提 | 已取得临时 Root，且 Shell / UID 2000 可用 `su` |

**本机没有 `init_boot` 分区。** init ramdisk 位于 `boot_a`（boot 镜像 v4）。

> 固件名允许在 `PD2301` 后带一个字母，例如 `PD2301E_A_16.3.17.0.W10`。本方案只在本机 `PD2301_A_16.3.17.0.W10` 上实测；字母后缀变体只做了适配放行，未在第二台设备验证。

## 1. 原理

ABL 把 BL 锁状态存放在独立的 4KB `devinfo` 分区：

```text
偏移 0x00–0x0C   ANDROID-BOOT!  （13 字节 magic）
偏移 0x0D        解锁标志        （00 = 锁定，非 00 = 已解锁）
偏移 0x0E        关键解锁标志    （00 = 未关键解锁）
偏移 0x0F        结构版本 = 1
偏移 0x90        初始化标记 = 1
```

临时 Root 允许直接改写这个分区。把 `0x0D/0x0E` 从 `00 00` 改为 `01 01`，ABL 下次启动即按“已解锁 + 已关键解锁”处理。没有利用漏洞，改的是 bootloader 自己读取的状态字节。

## 2. 本机适配验证（不是照搬参考机）

1. 分区尺寸与参考机完全一致：devinfo 4096、boot 100663296、abl 16777216、vbmeta 65536、xbl 7340032、uefi 5242880。
2. 写入前 devinfo 为 `ANDROID-BOOT! 00 00 01`，且 `0x90=1`，与参考机写入前相同。
3. 从本机 `abl_a` 解出 EFI LZMA 载荷（10,309,192 字节）后反汇编确认：
   - `0x4a074`：用 `ANDROID-BOOT!` 校验 devinfo 前 13 字节（长度 `0xd`）。
   - `0x49618`：读取 devinfo `[0x0D]` 并返回布尔值。
   - `0x49660`：读取 devinfo `[0x0E]` 并返回布尔值。
   - `0x49a2c` / `0x49b04`：分别写回 `[0x0D]` / `[0x0E]`。
   - `0x6e4c4` / `0x6e4e4`：分别打印 `Device unlocked` / `Device critical unlocked`。
   - `0x572c`：`[0x0D]` 非零时走 `Device is unlocked, Skipping boot verification`。
   - `0x6c7fc` / `0x6d9f8`：fastboot 解锁路径同时检查 `0x0D` 与 `0x0E`。
4. 本机实际结果：写入后回读逐字节等于候选，fastboot 返回 `unlocked: yes`，清空数据后系统正常启动，属性变为 `0 / unlocked / orange`。

## 3. 前置准备

- 电脑：Windows + ADB/fastboot。避免 ADB `36.0.0` / `36.0.1`（Windows 上存在文件截断问题），本资料包内为 `37.0.1`。
- 手机：开启 USB 调试并授权电脑；只连接目标手机；已取得临时 Root。
- 空间：工作盘至少 512MB 空闲（boot 备份约 96MB）。
- **个人资料另行备份**：照片、聊天记录、账号恢复信息。解锁后大概率需要清空数据。
- 明确接受风险：可能无法启动、保修/OTA/Play Integrity 受影响。此方案只有本机一台成功案例。

## 4. 手动解锁流程（本机实际执行顺序）

### 4.1 只读检查

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

同时确认六个分区存在且尺寸正确：

```text
adb shell "su -c 'blockdev --getsize64 /dev/block/by-name/devinfo'"       # 4096
adb shell "su -c 'blockdev --getsize64 /dev/block/by-name/boot_a'"       # 100663296
adb shell "su -c 'blockdev --getsize64 /dev/block/by-name/abl_a'"        # 16777216
adb shell "su -c 'blockdev --getsize64 /dev/block/by-name/vbmeta_a'"     # 65536
adb shell "su -c 'blockdev --getsize64 /dev/block/by-name/xbl_a'"        # 7340032
adb shell "su -c 'blockdev --getsize64 /dev/block/by-name/uefi_a'"       # 5242880
```

`_b` 槽位把 `_a` 换成 `_b`；`devinfo` 不分槽。

### 4.2 完整备份并双向校验

对 `devinfo`、`boot_<slot>`、`abl_<slot>`、`vbmeta_<slot>`、`xbl_<slot>`、`uefi_<slot>`：

```text
adb shell "su -c 'dd if=/dev/block/by-name/<P> of=<REMOTE>/<P>.img bs=4096 && chmod 644 <REMOTE>/<P>.img'"
adb shell "su -c 'sha256sum <REMOTE>/<P>.img'"
adb pull <REMOTE>/<P>.img <CASE>/<P>.img
```

要求：分区尺寸与记录一致、电脑文件长度一致、电脑 SHA-256 等于手机端 SHA-256。任一不符即停止。

### 4.3 只在电脑生成候选

```python
assert len(original) == 4096
assert original[:13] == b"ANDROID-BOOT!"
assert original[0x0d] == 0 and original[0x0e] == 0
assert original[0x0f] == 1 and original[0x90] == 1
candidate = bytearray(original)
candidate[0x0d] = 1
candidate[0x0e] = 1
assert [i for i, (a, b) in enumerate(zip(original, candidate)) if a != b] == [13, 14]
```

保存为 `devinfo-unlocked-candidate.img`。本机原件 SHA-256 为 `6bb408ee37b93e9e0a197e40150a8e71d86c9bc8ac69d1767d180094fe680743`，候选为 `c0b62d6399056712790de4c609376beba6d3c3f5b787f464b1e0ec6784863fc6`。

### 4.4 写入前复核

- 序列号、机型、固件、内核、槽位、起始锁定属性未变。
- `boot_id` 与备份时相同（重启过就必须重新备份）。
- Root 仍有效。
- 手机当前 devinfo 哈希等于备份原件哈希。
- 候选与原件只有偏移 13、14 不同。

### 4.5 推送、写入、回读

```text
adb push <CASE>/devinfo-unlocked-candidate.img <REMOTE>/candidate.img
adb shell "su -c 'sha256sum <REMOTE>/candidate.img'"      # 必须等于候选哈希

adb shell "su -c 'dd if=<REMOTE>/candidate.img of=/dev/block/by-name/devinfo bs=4096 count=1 conv=notrunc && sync'"
adb shell "su -c 'dd if=/dev/block/by-name/devinfo of=<REMOTE>/readback.img bs=4096 && chmod 644 <REMOTE>/readback.img'"
adb pull <REMOTE>/readback.img <CASE>/devinfo-readback.img
```

验收：回读 4096 字节、逐字节等于候选、与原件差异恰好是偏移 13、14。

**写入开始后若超时、断线、报错或回读不一致：不重启、不重试、不还原、不清数据，保留连接与文件后排查。**

### 4.6 从 bootloader 验证

```text
adb reboot bootloader
fastboot devices
fastboot getvar unlocked      # 必须出现 unlocked: yes
fastboot getvar secure        # secure: yes 不否定解锁
fastboot getvar product       # taro
```

得到明确的 `unlocked: yes` 才算解锁成功。若仍 locked 或输出含糊，不要继续刷写。

### 4.7 返回系统

```text
fastboot reboot
```

按屏幕提示操作：英文解锁警告后，若进入 vivo“系统受损 / 修复”界面，选择 **“清除所有数据”**，不要选“修复系统”。清空会删除全部资料。出现其他报错时先停下排查。

首次开机后重新开启 USB 调试并授权电脑，复核：

```text
adb shell getprop sys.boot_completed          # 1
adb shell getprop ro.boot.flash.locked        # 0
adb shell getprop ro.boot.vbmeta.device_state # unlocked
adb shell getprop ro.boot.verifiedbootstate   # orange
```

## 5. 本机专用自动化工具（可选）

位置：`04_Neo8方案\工具\`

- `环境检测.bat`：只读检测电脑、驱动、连接、机型、Root。
- `启动工具.bat`：菜单 1 检查；2 只备份；3 备份并解锁；4 fastboot 验证/返回系统。
- 需要把 `platform-tools` 文件夹放在 BAT 旁边，或按提示输入路径。
- 写入前必须输入 `UNLOCK <设备序列号>`，无法通过参数跳过。

与参考工具的区别：

- 已锁定为 `V2301A / PD2301`、`PD2301[_字母]_A_16.3.17.0.W10`、`5.10.246-gki-g8c3d0d7851ff`。
- 自动识别 `_a/_b` 槽位，按槽位备份 `boot/abl/vbmeta/xbl/uefi`。
- 没有外部参考哈希可用，因此不比较其他设备的 abl/xbl/uefi 指纹；改为锁定机型/固件/内核/槽位/尺寸、devinfo 结构，并在本次备份内自校验。不要为了“通过”而删除这些检查。
- 候选生成函数已用本机原始 devinfo 做过离线校验（结果哈希与实机候选一致）；**完整自动写入流程没有在第二台锁定 Neo8 上实测**，本机解锁使用的是上文手动流程。

## 6. 后续 Root（Sakisu / SukiSU）

- 本机无 `init_boot`，补丁对象是 `boot_a`。
- 原厂 `boot_a` 为 v4 镜像，96MB，内核 52062452 字节，ramdisk 1983953 字节。
- 用管理器选择“boot 镜像”打补丁，生成 `kernelsu_patched_*.img`（本机 ramdisk 变为 2381715 字节）。
- 刷入：`fastboot flash boot_a <补丁镜像>`，刷后 `fastboot reboot`。
- 验证：`adb shell "su -c id"` 返回 `uid=0(root)`，上下文 `u:r:ksu:s0`。
- 系统 OTA 会覆盖 `boot_a`；升级后需重新提取并打补丁。

## 7. 风险与禁止事项

- 非官方解锁：可能无法启动、丢全部数据、影响保修/OTA/Play Integrity。
- 不要写入任何其他人的 devinfo 备份；只用本机原件加两个字节修改。
- 回读不一致时不要重启、不要重复写入、不要自行还原。
- 不要调用 `fastboot flashing unlock`、不要回锁、不要刷 devinfo 以外的分区。
- `secure: yes` 与 `unlocked: yes` 可以同时存在，不是失败。
- 重启或清空数据后临时 Root 消失属于正常现象。

## 8. 回退

- 原厂分区镜像在 `03_原厂分区备份`：`devinfo.img`、`boot_a.img`、`abl_a.img`、`vbmeta_a.img`、`xbl_a.img`、`uefi_a.img`。
- 恢复原厂 boot：`fastboot flash boot_a boot_a.img`。
- 不建议自行回写 `devinfo` 回锁；确有需要时只能用本机原件、先核对哈希，并自行承担风险。
- 本方案不提供救砖保证；救砖优先使用官方售后/9008 流程。
