# Requires Windows PowerShell 5.1. Save as UTF-8 with BOM.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ToolRoot = $PSScriptRoot
$script:LogPath = $null
$script:Adb = $null
$script:Fastboot = $null
$script:WriteUnverified = $false
$script:LastCase = $null
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Profile = @{
    Model = 'V2301A'; Device = 'PD2301'
    Firmware = 'PD2301_A_16.3.17.0.W10'
    Kernel = '5.10.246-gki-g8c3d0d7851ff'
    # Neo8 本机没有可用的外部参考哈希：机型/固件/内核/槽位/尺寸与 devinfo 结构作为前置条件，
    # 各分区哈希只做“本次备份与实际分区一致”的自校验，不套用其他设备的镜像指纹。
    Partitions = [ordered]@{
        devinfo = @{ Size = 4096; Hash = $null }
        boot = @{ Size = 100663296; Hash = $null }
        abl = @{ Size = 16777216; Hash = $null }
        vbmeta = @{ Size = 65536; Hash = $null }
        xbl = @{ Size = 7340032; Hash = $null }
        uefi = @{ Size = 5242880; Hash = $null }
    }
}

function Write-Log([string]$Message) {
    if ($script:LogPath) {
        [IO.File]::AppendAllText($script:LogPath, ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) + "`r`n", $script:Utf8)
    }
}

function Say([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray) {
    Write-Host $Message -ForegroundColor $Color
    Write-Log $Message
}

function Quote-WindowsArgument([string]$Value) {
    # Win32 argument quoting, not cmd.exe / PowerShell code interpolation.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-External([string]$Exe, [string[]]$Arguments, [int]$Timeout = 30) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    $info.Arguments = (($Arguments | ForEach-Object { Quote-WindowsArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.StandardOutputEncoding = $script:Utf8
    $info.StandardErrorEncoding = $script:Utf8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        Write-Log ('RUN {0} {1}' -f $Exe, $info.Arguments)
        if (-not $process.Start()) { throw '无法启动外部工具' }
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($Timeout * 1000)) {
            try { $process.Kill() } catch { }
            throw "命令等待超过 $Timeout 秒；状态未确认，不会自动重试写入。"
        }
        $process.WaitForExit()
        $out = $stdout.GetAwaiter().GetResult()
        $err = $stderr.GetAwaiter().GetResult()
        $combined = ($out + "`n" + $err).Trim()
        Write-Log ('EXIT {0}: {1}' -f $process.ExitCode, $combined)
        return [pscustomobject]@{ Code = $process.ExitCode; Text = $combined; Out = $out.Trim() }
    } finally { $process.Dispose() }
}

function Invoke-Adb([string]$Serial, [string[]]$AdbArgs, [int]$Timeout = 30) {
    return Invoke-External $script:Adb (@('-s', $Serial) + $AdbArgs) $Timeout
}

function Invoke-Root([string]$Serial, [string]$Command, [int]$Timeout = 30) {
    # Every shell command is generated internally from fixed names and validated identifiers.
    if ($Command.Contains("'")) { throw '内部命令包含不允许的引号' }
    $result = Invoke-Adb $Serial @('shell', "su -c '$Command'") $Timeout
    if ($result.Code -ne 0) { throw ('手机 Root 命令失败：' + $result.Text) }
    return $result.Out
}

function Require-OK($Result, [string]$Message) {
    if ($Result.Code -ne 0) { throw ($Message + '：' + $Result.Text) }
}

function Find-Tools {
    $candidates = @((Join-Path $script:ToolRoot 'platform-tools'))
    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates += Split-Path -Parent $command.Source }
    foreach ($directory in $candidates) {
        $adbPath = Join-Path $directory 'adb.exe'
        $fastbootPath = Join-Path $directory 'fastboot.exe'
        if ((Test-Path -LiteralPath $adbPath -PathType Leaf) -and (Test-Path -LiteralPath $fastbootPath -PathType Leaf)) {
            $script:Adb = $adbPath; $script:Fastboot = $fastbootPath
            return
        }
    }
    $directory = (Read-Host '请输入含 adb.exe 和 fastboot.exe 的 platform-tools 文件夹完整路径').Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($directory)) { throw '尚未设置 Platform-Tools 文件夹，请准备电脑工具后重试。' }
    $adbPath = Join-Path $directory 'adb.exe'
    $fastbootPath = Join-Path $directory 'fastboot.exe'
    if (-not ((Test-Path -LiteralPath $adbPath -PathType Leaf) -and (Test-Path -LiteralPath $fastbootPath -PathType Leaf))) {
        throw '未找到配套的 adb.exe 和 fastboot.exe；请参阅使用说明。'
    }
    $script:Adb = (Resolve-Path -LiteralPath $adbPath).Path
    $script:Fastboot = (Resolve-Path -LiteralPath $fastbootPath).Path
}

function Read-DeviceList([string]$Text, [switch]$FastbootMode) {
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^([A-Za-z0-9_-]+)\s+(device|fastboot)\b') {
            $serial = $Matches[1]; $state = $Matches[2]
            if ($serial.StartsWith('emulator-')) { continue }
            if (($FastbootMode -and $state -eq 'fastboot') -or (-not $FastbootMode -and $state -eq 'device')) {
                $serial
            }
        }
    }
}

function Select-Device([switch]$FastbootMode) {
    $exe = $script:Adb; $arguments = @('devices', '-l')
    if ($FastbootMode) { $exe = $script:Fastboot; $arguments = @('devices') }
    $result = Invoke-External $exe $arguments 15
    Require-OK $result '读取设备列表失败'
    $devices = @(Read-DeviceList $result.Out -FastbootMode:$FastbootMode)
    if ($devices.Count -eq 0) {
        Say $result.Text
        throw '未发现可用的 USB 手机。请检查连接、驱动和 USB 调试授权；本工具不使用无线设备或模拟器。'
    }
    if ($devices.Count -eq 1) { return $devices[0] }
    for ($i = 0; $i -lt $devices.Count; $i++) { Say ('{0}. {1}' -f ($i + 1), $devices[$i]) }
    $answer = Read-Host '请选择手机编号；建议只连接目标手机'
    $number = 0
    if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $devices.Count) { throw '选择已取消或无效' }
    return $devices[$number - 1]
}

function Get-Identity([string]$Serial) {
    $identity = [ordered]@{ Serial = $Serial }
    $properties = [ordered]@{
        Model = 'ro.product.model'; Device = 'ro.product.device'; Firmware = 'ro.build.display.id'
        Slot = 'ro.boot.slot_suffix'
        Locked = 'ro.boot.flash.locked'; State = 'ro.boot.vbmeta.device_state'; Verified = 'ro.boot.verifiedbootstate'
    }
    foreach ($key in $properties.Keys) {
        $result = Invoke-Adb $Serial @('shell', 'getprop', $properties[$key])
        Require-OK $result '读取系统属性失败'
        $identity[$key] = $result.Out.Trim()
    }
    $result = Invoke-Adb $Serial @('shell', 'uname', '-r')
    Require-OK $result '读取内核失败'
    $identity.Kernel = $result.Out.Trim()
    $result = Invoke-Adb $Serial @('shell', 'cat', '/proc/sys/kernel/random/boot_id')
    Require-OK $result '读取本次开机标识失败'
    $identity.BootId = $result.Out.Trim()
    if ($identity.BootId -notmatch '^[0-9a-f-]{36}$') { throw '开机标识异常' }
    return [pscustomobject]$identity
}

function Assert-Profile($Identity, [switch]$ForUnlock) {
    foreach ($key in @('Model', 'Device', 'Firmware', 'Kernel')) {
        if ($Identity.$key -cne $script:Profile[$key]) { throw "不支持的 $key：$($Identity.$key)。仅支持本机实测的 Neo8 固件与内核。" }
    }
    if ($Identity.Slot -notin @('_a', '_b')) { throw "分区槽位异常：$($Identity.Slot)。必须为 _a 或 _b。" }
    if ($ForUnlock) {
        if ($Identity.Locked -eq '0' -or $Identity.State -eq 'unlocked' -or $Identity.Verified -eq 'orange') {
            throw '系统报告已解锁。拒绝重复修改；如需核实，请使用 fastboot 验证菜单。'
        }
        if ($Identity.Locked -cne '1' -or $Identity.State -cne 'locked' -or $Identity.Verified -cne 'green') {
            throw '起始解锁状态不符合本次实测条件，停止写入。'
        }
    }
}

function Assert-Root([string]$Serial) {
    Say '正在检查 Shell 的 Root 授权；手机出现提示时，请确认是你自己的 ADB Shell。'
    $output = Invoke-Root $Serial 'id' 25
    if ($output -notmatch '(^|\s)uid=0\b') { throw '未取得 Root。请在管理器里授权 Shell / UID 2000，并确认临时 Root 仍有效。' }
    Write-Log ('ROOT ' + $output)
}

function Show-Identity($Identity) {
    Say ('设备：{0} / {1} / {2}' -f $Identity.Serial, $Identity.Model, $Identity.Device)
    Say ('槽位：' + $Identity.Slot)
    Say ('固件：' + $Identity.Firmware)
    Say ('内核：' + $Identity.Kernel)
    Say ('系统报告的状态：{1}（locked 为未解锁，unlocked 为已解锁；以 fastboot 验证为准）' -f $Identity.Locked, $Identity.State, $Identity.Verified)
}

function Hash-Bytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-FileDigest([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Get-RemoteDigest([string]$Serial, [string]$Path) {
    $text = Invoke-Root $Serial "sha256sum $Path" 90
    if ($text -notmatch '^([0-9a-fA-F]{64})\s') { throw '手机未返回有效 SHA-256；不能跳过校验。' }
    return $Matches[1].ToLowerInvariant()
}

function New-UnlockBytes([byte[]]$Original) {
    if ($Original.Length -ne 4096) { throw 'devinfo 必须是 4096 字节' }
    if ([Text.Encoding]::ASCII.GetString($Original, 0, 13) -cne 'ANDROID-BOOT!') { throw 'devinfo 头部不匹配' }
    if ($Original[13] -ne 0 -or $Original[14] -ne 0) { throw 'devinfo 标志已解锁或状态异常，拒绝再次修改' }
    if ($Original[15] -ne 1) { throw 'devinfo 其他标志与实测状态不同，停止修改' }
    if ($Original[144] -ne 1) { throw 'devinfo 0x90 初始化标记异常，停止修改' }
    $candidate = [byte[]]$Original.Clone()
    $candidate[13] = 1; $candidate[14] = 1
    return ,$candidate
}

function Assert-Candidate([byte[]]$Original, [byte[]]$Candidate) {
    $expected = New-UnlockBytes $Original
    if ((Hash-Bytes $expected) -cne (Hash-Bytes $Candidate)) { throw '解锁文件检查未通过，已停止操作。' }
}

function Save-Case($Case, [string]$State) {
    $Case.State = $State
    $Case.Updated = Get-Date -Format o
    $path = Join-Path $Case.Directory '操作状态.json'
    $json = $Case | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($path + '.tmp', $json, $script:Utf8)
    Move-Item -LiteralPath ($path + '.tmp') -Destination $path -Force
    Write-Log ('CASE ' + $State + ': ' + $Case.Directory)
}

function New-Backup($Identity) {
    $id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $directory = Join-Path (Join-Path (Join-Path $script:ToolRoot '备份') $Identity.Serial) $id
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($script:ToolRoot))
    if ($drive.AvailableFreeSpace -lt 512MB) { throw '工具所在磁盘可用空间不足 512MB，请先腾出空间。' }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $case = [pscustomobject]@{
        ToolVersion = '1.0-neo8'; Identity = $Identity; Directory = $directory
        Remote = '/data/local/tmp/neo8bl-' + [Guid]::NewGuid().ToString('N')
        State = 'created'; Updated = ''; Partitions = [ordered]@{}
    }
    $script:LastCase = $case
    Save-Case $case 'backing_up'
    $null = Invoke-Root $Identity.Serial "mkdir -p $($case.Remote) && chmod 755 $($case.Remote)"
    foreach ($partition in $script:Profile.Partitions.Keys) {
        Say ('备份 ' + $partition + ' ……')
        $source = if ($partition -ceq 'devinfo') { '/dev/block/by-name/devinfo' } else { '/dev/block/by-name/' + $partition + $Identity.Slot }
        $remotePath = $case.Remote + '/' + $partition + '.img'
        $localPath = Join-Path $directory ($partition + '.img')
        $size = Invoke-Root $Identity.Serial "test -b $source && blockdev --getsize64 $source"
        $expected = $script:Profile.Partitions[$partition]
        if ($size.Trim() -cne [string]$expected.Size) { throw "分区 $partition 大小异常：$size" }
        $null = Invoke-Root $Identity.Serial "dd if=$source of=$remotePath bs=4096 && chmod 644 $remotePath" 180
        $remoteHash = Get-RemoteDigest $Identity.Serial $remotePath
        $pulled = Invoke-Adb $Identity.Serial @('pull', $remotePath, $localPath) 180
        Require-OK $pulled ('下载备份失败：' + $partition)
        if ((Get-Item -LiteralPath $localPath).Length -ne $expected.Size) { throw "电脑上的 $partition 备份长度不正确" }
        $localHash = Get-FileDigest $localPath
        if ($localHash -cne $remoteHash) { throw "备份传输校验失败：$partition" }
        $case.Partitions[$partition] = @{ Size = $expected.Size; Hash = $localHash }
        Save-Case $case 'backing_up'
    }
    Save-Case $case 'backup_complete'
    Say ('完整备份已保存在：' + $directory) Green
    return $case
}

function Assert-BackupProfile($Case) {
    foreach ($partition in $script:Profile.Partitions.Keys) {
        if (-not $Case.Partitions.Contains($partition)) { throw "备份不完整：缺少 $partition" }
        $path = Join-Path $Case.Directory ($partition + '.img')
        $expected = $script:Profile.Partitions[$partition]
        if ((Get-Item -LiteralPath $path).Length -ne $expected.Size) { throw "备份长度被改变：$partition" }
        $actual = Get-FileDigest $path
        if ($actual -cne $Case.Partitions[$partition].Hash) { throw "备份内容被改变：$partition" }
        if ($expected.Hash -and $actual -cne $expected.Hash) { throw "$partition 指纹与实测固件不同。备份已保留，拒绝解锁；不要强行绕过。" }
    }
}

function Confirm-Unlock([string]$Serial) {
    Say ''
    Say '========== 写入前的风险提示 ==========' Yellow
    Say '1. 这是非官方解锁。操作失败可能无法启动，备份不保证一定能救回。' Yellow
    Say '2. 参考实测案例清空了全部用户数据。请先另行备份照片、聊天和账号恢复信息。' Yellow
    Say '3. 仅支持 V2301A / PD2301 的 PD2301_A_16.3.17.0.W10；其他固件会直接拒绝执行。' Yellow
    Say '4. 写入内容仅为 devinfo 的 0x0D/0x0E 两个字节，不改动其他分区。' Yellow
    Say '5. 写入期间不要拔线、关闭窗口或重启。工具不提供回锁，也不会刷其他人的镜像。' Yellow
    Say ('目标手机序列号：' + $Serial) Cyan
    $expected = 'UNLOCK ' + $Serial
    $answer = Read-Host ("确认接受上述风险，并已备份个人资料后，输入 $expected；直接回车取消")
    return $answer -ceq $expected
}

function Write-Unlock($Case) {
    # No command-line switch can skip this confirmation.
    Assert-BackupProfile $Case
    $originalPath = Join-Path $Case.Directory 'devinfo.img'
    $original = [IO.File]::ReadAllBytes($originalPath)
    $candidate = New-UnlockBytes $original
    $candidatePath = Join-Path $Case.Directory 'devinfo-unlocked-candidate.img'
    [IO.File]::WriteAllBytes($candidatePath, $candidate)
    Assert-Candidate $original ([IO.File]::ReadAllBytes($candidatePath))
    Save-Case $Case 'candidate_ready'
    if (-not (Confirm-Unlock $Case.Identity.Serial)) {
        Save-Case $Case 'cancelled_before_write'
        Say '已取消，没有写入手机分区；备份保留。'
        return $false
    }
    # Recheck after the person reads the prompt; never reuse an earlier Root grant or boot state.
    $identity = Get-Identity $Case.Identity.Serial
    Assert-Profile $identity -ForUnlock
    if ($identity.BootId -cne $Case.Identity.BootId) { throw '备份后手机重启过；临时 Root 和现场已变化，请重新检查、备份。' }
    Assert-Root $identity.Serial
    $freshOriginal = [IO.File]::ReadAllBytes($originalPath)
    if ((Hash-Bytes $freshOriginal) -cne $Case.Partitions['devinfo'].Hash) { throw '原始 devinfo 备份被改变' }
    $freshCandidate = [IO.File]::ReadAllBytes($candidatePath)
    Assert-Candidate $freshOriginal $freshCandidate
    $expectedHash = Hash-Bytes $freshCandidate
    if ((Get-RemoteDigest $identity.Serial '/dev/block/by-name/devinfo') -cne (Hash-Bytes $freshOriginal)) { throw '当前手机 devinfo 与这次备份不同，拒绝写入' }
    $remoteCandidate = $Case.Remote + '/candidate.img'
    $pushed = Invoke-Adb $identity.Serial @('push', $candidatePath, $remoteCandidate) 30
    Require-OK $pushed '传输候选镜像失败'
    if ((Get-RemoteDigest $identity.Serial $remoteCandidate) -cne $expectedHash) { throw '手机上的候选镜像传输校验失败' }
    Save-Case $Case 'write_started_do_not_reboot_if_unverified'
    $script:WriteUnverified = $true
    Say '正在执行解锁并检查结果，请保持连接。' Yellow
    $null = Invoke-Root $identity.Serial "dd if=$remoteCandidate of=/dev/block/by-name/devinfo bs=4096 count=1 conv=notrunc && sync" 30
    $remoteReadback = $Case.Remote + '/readback.img'
    $null = Invoke-Root $identity.Serial "dd if=/dev/block/by-name/devinfo of=$remoteReadback bs=4096 && chmod 644 $remoteReadback" 30
    $readbackPath = Join-Path $Case.Directory 'devinfo-readback.img'
    $pulled = Invoke-Adb $identity.Serial @('pull', $remoteReadback, $readbackPath) 30
    Require-OK $pulled '回读文件下载失败'
    $readback = [IO.File]::ReadAllBytes($readbackPath)
    Assert-Candidate $freshOriginal $readback
    if ((Hash-Bytes $readback) -cne $expectedHash) { throw '回读与候选镜像不一致' }
    Save-Case $Case 'devinfo_write_verified'
    $script:WriteUnverified = $false
    Say '解锁修改检查通过。' Green
    return $true
}

function Test-UnlockedOutput($Result) {
    return ($Result.Code -eq 0 -and $Result.Text -notmatch '(?i)FAILED|error:' -and
        $Result.Text -match '(?im)^\s*(?:\(bootloader\)\s*)?unlocked\s*:\s*yes\s*$')
}

function Verify-Fastboot([string]$Serial, $Case = $null) {
    $result = Invoke-External $script:Fastboot @('-s', $Serial, 'getvar', 'unlocked') 15
    Say $result.Text
    if (-not (Test-UnlockedOutput $result)) { throw '未得到明确的 unlocked: yes；不能宣布解锁成功，也不要继续刷启动镜像。' }
    if ($Case) { Save-Case $Case 'bootloader_unlocked_verified' }
    Say 'Bootloader 已明确返回 unlocked: yes。' Green
    $secure = Invoke-External $script:Fastboot @('-s', $Serial, 'getvar', 'secure') 15
    Say $secure.Text
    Say 'secure: yes 和 unlocked: yes 可以同时存在。'
    Say '手机接下来可能先显示解锁警告，再进入 vivo 修复界面。'
    Say '参考设备在修复界面选择“清除所有数据”后正常启动；此操作会清空用户资料，参考案例没有选择“修复系统”。' Yellow
    Say '仅在屏幕与实测情况一致时参考该步骤；其他报错应先排查。'
    if ((Read-Host '输入 SYSTEM 返回系统；直接回车停留在 bootloader') -ceq 'SYSTEM') {
        $result = Invoke-External $script:Fastboot @('-s', $Serial, 'reboot') 15
        Require-OK $result '重启指令失败'
        if ($result.Text -match '(?i)FAILED|error:') { throw ('重启失败：' + $result.Text) }
        Say '已发送重启指令。清空数据和首次开机设置需要在手机上手动完成。'
    }
}

function Reboot-AndVerify($Case) {
    $result = Invoke-Adb $Case.Identity.Serial @('reboot', 'bootloader') 15
    Require-OK $result '进入 bootloader 失败'
    Say '正在等待同一序列号的手机进入 fastboot，最多 60 秒……'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 60) {
        $result = Invoke-External $script:Fastboot @('devices') 8
        $devices = @(Read-DeviceList $result.Out -FastbootMode)
        if ($devices -ccontains $Case.Identity.Serial) {
            Verify-Fastboot $Case.Identity.Serial $Case
            return
        }
        Start-Sleep -Seconds 1
    }
    Say '等待结束，修改已检查通过，但 BL 状态尚未确认。请检查驱动或使用菜单 4。' Yellow
    Say '若 fastboot 下序列号发生变化，工具不会猜测切换到另一台设备；可手动选择后只读验证。'
}

function Show-Risks {
    Say '流程：取得临时 Root → 授权 Shell → 检测环境 → 自动备份 → 确认风险 → 解锁与验证 → 按手机提示完成后续设置。'
    Say '支持：V2301A / PD2301，PD2301_A_16.3.17.0.W10，5.10.246-gki-g8c3d0d7851ff（A/B，自动识别槽位）。'
    Say '工具锁定机型、固件、内核、槽位和分区尺寸；本机无外部参考哈希，不套用其他设备的镜像指纹。'
    Say '风险：清空数据、账号需重新登录、启动失败；备份不是一定可用的救砖保证。' Yellow
    Say '已解锁设备禁止重复解锁。本工具不负责临时提权，不自动清除数据，不自动安装永久 Root。'
    Say '永久 Root 请按对应项目的官方说明另行安装，使用目标设备当前固件的原始启动镜像制作补丁。'
    Say '备份在本目录的“备份/序列号/时间”下；日志在“运行记录”。含设备信息，请勿直接公开整个目录。'
}

function Start-Neo8Tool {
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    $logs = Join-Path $script:ToolRoot '运行记录'
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    $script:LogPath = Join-Path $logs ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
    Say 'iQOO Neo8 BL 工具（V2301A / PD2301）v1.0'
    Say '请先取得临时 Root 后再使用；解锁有清空数据及无法启动风险，请先阅读使用说明。' Yellow
    Find-Tools
    while ($true) {
        Say ''
        Say '1  检查手机状态和 Root（不改分区）'
        Say '2  完整备份分区（不解锁）'
        Say '3  备份并解锁 BL（会写分区，有清空数据及无法启动风险）'
        Say '4  fastboot 验证解锁状态 / 返回系统'
        Say '5  查看流程与风险'
        Say '0  退出'
        $choice = Read-Host '请选择'
        if ($choice -ceq '0') { return }
        $script:LastCase = $null
        try {
            switch ($choice) {
                '1' {
                    $serial = Select-Device
                    $identity = Get-Identity $serial
                    Show-Identity $identity
                    Assert-Profile $identity
                    Say '机型、固件、内核、槽位与实测配置一致；分区尺寸和 devinfo 结构会在备份时进一步确认。'
                    Assert-Root $serial
                    Say 'Shell 已取得 Root。' Green
                }
                '2' {
                    $serial = Select-Device
                    $identity = Get-Identity $serial
                    Show-Identity $identity
                    Assert-Profile $identity
                    Assert-Root $serial
                    $case = New-Backup $identity
                    Say '备份完成，没有修改手机分区。备份可能包含当前的 Root 镜像，不一定是原厂镜像。'
                }
                '3' {
                    $serial = Select-Device
                    $identity = Get-Identity $serial
                    Show-Identity $identity
                    Assert-Profile $identity -ForUnlock
                    Assert-Root $serial
                    $case = New-Backup $identity
                    if (Write-Unlock $case) { Reboot-AndVerify $case }
                }
                '4' { $serial = Select-Device -FastbootMode; Verify-Fastboot $serial }
                '5' { Show-Risks }
                default { Say '请选择 0 至 5。' }
            }
        } catch {
            Say ('操作停止：' + $_.Exception.Message) Red
            if ($script:WriteUnverified) {
                Say '警告：写入已开始，但尚未确认完整回读。不要重启、不要重复解锁，保留连接和备份进行排查。' Red
                Say ('日志：' + $script:LogPath) Yellow
                if ($script:LastCase) { Say ('备份与操作状态：' + $script:LastCase.Directory) Yellow }
                return
            }
            if ($script:LastCase) { Say ('本次操作材料：' + $script:LastCase.Directory) }
            Say '工具不会自动重试解锁或清空数据。'
        }
    }
}

# Dot-sourcing exposes pure functions for offline tests without starting ADB or the UI.
if ($MyInvocation.InvocationName -ne '.') {
    $guard = New-Object Threading.Mutex($false, 'Local\IQOONeo8BLTool-v1')
    $acquired = $false
    try {
        try { $acquired = $guard.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw '另一个解锁工具窗口已经在运行，请使用已有窗口。' }
        Start-Neo8Tool
    } catch {
        Write-Host ('工具停止：' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    } finally {
        if ($acquired) { $guard.ReleaseMutex() }
        $guard.Dispose()
    }
}
