# 常见问题与排错

## 1. `adb pull` 报 `cannot create file/directory`

典型报错：

```text
adb: error: cannot create file/directory '...\boot.img': No such file or directory
```

这是电脑端创建本地文件失败，不是手机分区读取失败。常见原因：

- 工具路径含中文、全角括号、全角逗号、空格，或层级太深。
- 磁盘空间/配额不足；`boot` 约 96MB，而 `devinfo` 只有 4KB，所以小文件能过、大文件失败。
- 目标盘是云盘、网络盘、映射盘或同步文件夹。
- 杀毒软件/Windows Defender 的受控文件夹访问拦截。

处理：

1. 把整个工具移到短纯英文路径，例如 `D:\Neo8BL` 或 `C:\Neo8BL`。
2. 确认是本地 NTFS 盘，至少 1GB 空闲。
3. 删除 `neo8/tool/backups/` 下失败的半成品。
4. 重新跑 `env-check.bat`，再跑 `start-tool.bat`，先选 `2` 只备份。
5. 如果仍失败，用日志里的 `REMOTE_DIR` 手动测试：

```text
adb -s <序列号> pull <REMOTE_DIR>/boot.img D:\test\boot.img
```

## 2. 环境检测提示“不支持的 Firmware”

工具接受：

```text
PD2301[_字母]_A_16.3.17.0.W10
```

例如 `PD2301E_A_16.3.17.0.W10` 可以通过。以下仍会拒绝：

- `PD2301EE_A_...`
- `PD2301E_A_16.3.18.0.W10`
- 其他机型、其他内核

不要修改脚本绕过检查。其他固件的 `devinfo` 布局或 ABL 行为可能不同。

## 3. Shell 没有 Root

- 确认临时 Root 仍有效；重启后临时 Root 会消失。
- 在 Root 管理器里授权 **Shell / `com.android.shell` / UID 2000**。
- 用 `adb shell "su -c id"` 确认返回 `uid=0`。
- 不要用管理器界面“已安装”代替实际检查。

## 4. 正常系统能连，fastboot 连不上

- 检查 fastboot 模式驱动；正常系统和 fastboot 模式可能需要不同驱动。
- 手动进入 bootloader 后，用 `start-tool.bat` 菜单 `4` 只读验证。
- 不要因为 fastboot 连不上就重新执行解锁。

## 5. 提示“系统报告已解锁”

- 不要重复解锁。
- 用菜单 `4` 或手动 `fastboot getvar unlocked` 验证。
- 只有 `unlocked: yes` 才是 fastboot 层证据；Android 属性不能代替。

## 6. 写入后报错或回读不一致

- 不要重启。
- 不要重复写入。
- 不要自行还原 `devinfo`。
- 不要清数据。
- 保留连接、`neo8/tool/backups/`、`neo8/tool/logs/`，先排查。

## 7. `secure: yes` 是不是失败

不是。`secure: yes` 表示 secure boot/签名链仍在；`unlocked: yes` 和它可以同时存在。

## 8. 清数据后临时 Root 消失

正常。解锁 BL 不等于永久 Root；永久 Root 需要另行为 `boot` / `init_boot` 打补丁。

## 9. 文件放在哪里

```text
neo8/tool/backups/<serial>/<time>/    # 分区备份
neo8/tool/logs/                       # 运行日志
neo8/tool/env-report/                 # 环境检测报告
```

这些目录可能包含设备序列号和本机分区，分享前先脱敏，不要直接公开整个目录。

## 10. 推送候选时报 `remote couldn't create file: Permission denied`

典型报错：

```text
adb: error: failed to copy '.../devinfo-unlocked-candidate.img'
to '/data/local/tmp/neo8bl-.../candidate.img': remote couldn't create file: Permission denied
```

原因不是手机 Root 没给，而是旧版工具用 `su -c` 创建 `/data/local/tmp/neo8bl-...` 并设置 `755`，目录归 root 所有；`adb push` 是**以 shell 用户运行**的，不经过 `su`，所以 shell 没有写权限。

v1.2 已改为用 `adb shell mkdir` 创建临时目录，让目录归 shell 所有；root 的 `dd` 仍能写入，后续 `adb push` 也能写。请替换 `neo8/tool/Neo8BL.ps1` 后重新跑菜单 `3`。

这次失败发生在备份完成、写入 `devinfo` 之前；手机没有被写入，备份仍然有效。重新执行会创建新备份，不需要手动还原。
