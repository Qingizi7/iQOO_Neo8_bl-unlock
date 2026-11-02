# ABL 分析脚本（可选）

这三个脚本只做静态分析，不接触手机、不修改分区。它们用于复核 `devinfo` 状态位在 ABL 中的读取逻辑，不是解锁工具的必需组件。

## 依赖

```text
python3 -m pip install -r requirements.txt
```

需要 Python 3 和 `capstone`。如果要从 `abl_a.img` 提取 payload，可另装 `uefi_firmware`（提供 `uefi-firmware-parser` 命令）；不是运行脚本的必需依赖。

## 准备 payload

脚本接收的是**已经解出的 ABL EFI/PE 载荷**（`abl_payload.bin`），不是手机分区 `abl_a.img` 本身，也不是整个固件包。

可以从自己的 `abl_a.img` 备份中提取 EFI 载荷，例如：

```text
uefi-firmware-parser -b -e -O abl_a.img
```

不同固件/不同提取方式得到的 payload 可能不同。脚本会自动在文件前 0x2000 字节内寻找第一个有效 PE 头，并读取 `.text` 段，因此既支持 PE 位于偏移 `0x00`，也支持 PE 位于 `0xB8` 等小偏移的封装。

## 用法

```text
python3 abl_flags.py abl_payload.bin
python3 abl_xref.py abl_payload.bin
python3 abl_crosscheck.py abl_payload.bin
```

不传路径时默认读取当前目录的 `abl_payload.bin`。

- `abl_flags.py`：搜索关键字符串，并列出 `devinfo[0x0D/0x0E]` 附近的 `ldrb/ldur` 指令，尝试识别 devinfo 结构基址。
- `abl_xref.py`：动态定位关键字符串的 VA，列出代码中对它们的交叉引用；重点打印 `ANDROID-BOOT!` 附近的上下文。
- `abl_crosscheck.py`：扫描所有包含 `unlocked`、`verifiedboot`、`device_state` 等关键词的字符串，并列出引用上下文。

## 注意

- 输出地址是相对于**本次 payload** 的 PE 镜像地址，不是手机运行时的物理地址。
- 不同固件、不同提取方式可能得到不同地址；不要拿方案文档里的地址直接套到另一份 payload 上。
- 如果脚本报 `no valid PE header found`，说明传入的是 `abl_a.img` 原始分区或 payload 提取不完整，不是脚本语法错误。
