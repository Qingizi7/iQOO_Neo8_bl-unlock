# 救砖与回退

> 本方案不提供救砖保证。优先保留证据，再按“先软后硬、先小后大”的顺序处理。

## 1. 先判断砖的层级

1. 还能进 fastboot？`fastboot devices` 能看到设备？
2. 还能进 recovery？屏幕有没有 vivo 修复界面？
3. 电脑设备管理器是否出现 `Qualcomm HS-USB QDLoader 9008`？
4. 什么都没有：优先官方售后/授权维修点。

## 2. 工具生成的备份

自动备份位于：

```text
neo8/tool/backups/<serial>/<time>/
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

这些备份只覆盖引导链，不是整机备份。没有 `super`、`system`、`vendor`、`userdata`、`persist`、`modem`。

## 3. 还能进 fastboot

按“影响最小”的顺序回刷，刷一个、重启测一次：

```text
fastboot flash devinfo devinfo.img
fastboot flash boot_a boot_a.img
fastboot flash vbmeta_a vbmeta_a.img
```

注意：

- 实际分区名以你的槽位为准（`_a` 或 `_b`），不要猜。
- `abl` / `xbl` / `uefi` 是 bootloader 链，非必要不要写；写坏会把软砖变硬砖。
- 每次刷前校验 SHA-256，镜像必须来自本机备份或同版本官方固件。
- 不要 `erase all`、不要格式化 `userdata`、不要刷别人的 `devinfo` / `persist` / `modem`。

## 4. 进不了 fastboot 但能进 recovery

可以尝试原厂“修复系统 / 清除数据”：

- 清除数据会丢失资料。
- “修复系统”不一定能修复 bootloader 或 boot 分区。
- 不同版本界面不同，出现异常报错先停下。

## 5. 只能进 9008

Qualcomm EDL 恢复需要：

- 对应机型的 firehose programmer。
- 完整固件包和 `rawprogram` / `patch` XML。
- QFIL / QPST 或等效工具。

vivo/Qualcomm 新机可能要求签名或授权 firehose；公开工具未必能进。没有匹配的 programmer 时，优先官方售后。

不要使用来源不明的“一键救砖”工具；错误的 programmer/固件可能把硬砖变成永久砖。

## 6. 刷坏 system / GSI 的情况

六个分区的备份不够。需要：

- 原厂 `super` 镜像或完整固件包；
- fastbootd / EDL 写入；
- 可能需要重新格式化 `userdata`。

本仓库不包含 `super` 或完整固件，也不保证任意 GSI 可启动。

## 7. 不要做的事

- 不要用另一台手机的 `devinfo`、`persist`、`modem`、`userdata`。
- 不要为了“试试”反复写 `devinfo`。
- 写入开始后回读不一致时，不要重启、不要重试、不要自行还原。
- 不要把资料包里的原厂镜像直接刷到另一台设备；那些是作者本机资料。

## 8. 相关文档

- [`neo8-unlock-guide.md`](neo8-unlock-guide.md)：解锁流程。
- [`principle.md`](principle.md)：原理与证据。
- [`troubleshooting.md`](troubleshooting.md)：常见报错。
