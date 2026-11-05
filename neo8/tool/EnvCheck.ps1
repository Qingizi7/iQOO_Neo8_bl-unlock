# Windows PowerShell 5.1, UTF-8 BOM. Read-only phone diagnostics.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Neo8BL.ps1')
$script:EnvChecks = New-Object 'Collections.Generic.List[object]'

function Add-EnvCheck([string]$Level, [string]$Title, [string]$Detail) {
    $script:EnvChecks.Add([pscustomobject]@{ Level = $Level; Title = $Title; Detail = $Detail })
    $color = [ConsoleColor]::Gray
    $label = '说明'
    switch ($Level) {
        'PASS' { $color = [ConsoleColor]::Green; $label = '通过' }
        'WARN' { $color = [ConsoleColor]::Yellow; $label = '待处理/未验证' }
        'FAIL' { $color = [ConsoleColor]::Red; $label = '未通过' }
    }
    Say ("[$label] $Title") $color
    Say ('  ' + $Detail)
}

function Get-DriverSnapshot {
    # Present PnP devices only. Absence does not prove a driver is not installed.
    return @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "Present = TRUE AND (PNPDeviceID LIKE 'USB%VID_2D95%' OR PNPDeviceID LIKE 'USB%VID_18D1%' OR PNPDeviceID LIKE 'USB%VID_05C6%' OR Name LIKE '%ADB%' OR Name LIKE '%Android%' OR Name LIKE '%vivo%' OR Name LIKE '%iQOO%')" -OperationTimeoutSec 15 -ErrorAction Stop)
}

function Show-DriverSnapshot {
    try {
        $devices = @(Get-DriverSnapshot)
        if ($devices.Count -eq 0) {
            Add-EnvCheck 'INFO' 'Windows USB 驱动线索' '当前没有发现相关的已连接设备条目；可能未连接手机，不能据此断定没装驱动。'
            return
        }
        foreach ($device in $devices) {
            $code = $device.ConfigManagerErrorCode
            if ($null -eq $code) {
                Add-EnvCheck 'WARN' 'Windows USB 设备' ($device.Name + '：系统没有返回驱动状态。')
            } elseif ($code -eq 0) {
                Add-EnvCheck 'INFO' 'Windows USB 设备' ($device.Name + '：当前设备管理器未报告错误；ADB / fastboot 是否可用看下面的实际检测。')
            } else {
                Add-EnvCheck 'WARN' 'Windows USB 设备存在问题' ($device.Name + "：设备管理器错误代码 $code。请检查适用驱动和数据线；工具不自动安装驱动。")
            }
        }
    } catch {
        Add-EnvCheck 'WARN' 'Windows USB 驱动线索读取失败' ('无法读取设备管理器信息，继续实际连接检测。' + $_.Exception.Message)
    }
}

function Check-AndroidEnvironment([string]$Serial) {
    Add-EnvCheck 'PASS' 'ADB USB 连接与调试授权' ('已授权设备：' + $Serial)
    try {
        $identity = Get-Identity $Serial
        Add-EnvCheck 'INFO' '手机信息' ('{0} / {1}；槽位 {4}；固件 {2}；内核 {3}' -f $identity.Model, $identity.Device, $identity.Firmware, $identity.Kernel, $identity.Slot)
        $matchesProfile = $false
        try {
            Assert-Profile $identity
            $matchesProfile = $true
            Add-EnvCheck 'PASS' '工具支持的机型、固件、内核和槽位' '与支持版本一致。解锁前还会进一步检查，当前检测通过不代表保证成功。'
        } catch { Add-EnvCheck 'FAIL' '工具适配检查' $_.Exception.Message }
        Add-EnvCheck 'INFO' '系统报告的 BL 状态' ('{1}（locked 为未解锁，unlocked 为已解锁；以 fastboot 验证为准）。' -f $identity.Locked, $identity.State, $identity.Verified)
        if ($identity.Locked -eq '0' -or $identity.State -eq 'unlocked') {
            Add-EnvCheck 'INFO' '重复操作提醒' '系统报告已经解锁，无须再执行解锁。'
        }
        if ($matchesProfile) {
            try {
                Assert-Root $Serial
                Add-EnvCheck 'PASS' 'Shell Root 权限' '电脑端已取得 Root 权限。本次检查不能判断重启后是否保留。'
            } catch {
                Add-EnvCheck 'WARN' 'Shell Root 权限未就绪' ('先取得临时 Root，并在管理器里授权 Shell / UID 2000。' + $_.Exception.Message)
            }
        } else { Add-EnvCheck 'INFO' 'Shell Root 检查' '机型或固件不适配，未向这台设备请求 Root。' }
    } catch { Add-EnvCheck 'FAIL' '读取手机信息失败' $_.Exception.Message }
}

function Check-FastbootEnvironment([string]$Serial) {
    Add-EnvCheck 'PASS' 'fastboot USB 识别' ('当前识别到设备：' + $Serial)
    try {
        $result = Invoke-External $script:Fastboot @('-s', $Serial, 'getvar', 'unlocked') 12
        if (Test-UnlockedOutput $result) {
            Add-EnvCheck 'PASS' 'fastboot 通信' 'bootloader 明确返回 unlocked: yes；已经解锁，无须重复解锁。'
        } elseif ($result.Code -eq 0 -and $result.Text -notmatch '(?i)FAILED|error:' -and $result.Text -match '(?im)^\s*(?:\(bootloader\)\s*)?unlocked\s*:\s*no\s*$') {
            Add-EnvCheck 'PASS' 'fastboot 通信' 'bootloader 明确返回 unlocked: no；通信正常，BL 仍锁定。'
        } else { Add-EnvCheck 'WARN' 'fastboot 查询未确认' ('已识别设备，但没有得到明确的解锁状态：' + $result.Text) }
    } catch { Add-EnvCheck 'WARN' 'fastboot 通信失败' $_.Exception.Message }
    Add-EnvCheck 'INFO' 'Android 与 Root 检查' '手机当前在 fastboot，不能检查 Android 内的固件和 Root；返回系统后可再次检测。本工具不会自动重启手机。'
}

function Check-Connections([bool]$AdbReady, [bool]$FastbootReady) {
    $androidDevices = @(); $bootDevices = @()
    if ($AdbReady) {
        try {
            $result = Invoke-External $script:Adb @('devices', '-l') 15
            Require-OK $result 'ADB 设备枚举失败'
            $androidDevices = @(Read-DeviceList $result.Out)
            foreach ($line in ($result.Out -split '\r?\n')) {
                if ($line -match '^([A-Za-z0-9_-]+)\s+unauthorized\b') {
                    Add-EnvCheck 'WARN' 'USB 调试尚未授权' ($Matches[1] + '：解锁手机屏幕，在“允许 USB 调试”提示中允许这台电脑，再运行检测。')
                } elseif ($line -match '^([A-Za-z0-9_-]+)\s+offline\b') {
                    Add-EnvCheck 'WARN' 'ADB 设备离线' ($Matches[1] + '：检查数据线、USB 调试及手机状态，重新连接后再检测。')
                }
            }
        } catch { Add-EnvCheck 'FAIL' 'ADB 连接检测失败' $_.Exception.Message }
    }
    if ($FastbootReady) {
        try {
            $result = Invoke-External $script:Fastboot @('devices') 12
            Require-OK $result 'fastboot 设备枚举失败'
            $bootDevices = @(Read-DeviceList $result.Out -FastbootMode)
        } catch { Add-EnvCheck 'FAIL' 'fastboot 连接检测失败' $_.Exception.Message }
    }
    if (($androidDevices.Count + $bootDevices.Count) -gt 1) {
        Add-EnvCheck 'WARN' '检测到多个 USB 调试设备' '请只连接目标手机后重新检测；本次不自动选择设备，也不请求 Root。'
        return
    }
    if ($androidDevices.Count -eq 1) {
        Check-AndroidEnvironment $androidDevices[0]
        Add-EnvCheck 'WARN' 'fastboot 驱动尚未实测' '手机当前在正常系统，未识别到 fastboot 设备属于正常现象。需要手机实际处于 bootloader 模式才能确认那一模式的驱动；不会自动切换模式。'
    } elseif ($bootDevices.Count -eq 1) {
        Check-FastbootEnvironment $bootDevices[0]
    } else {
        Add-EnvCheck 'WARN' '当前没有可用的 USB 手机' '可能未连接、未授权、处于其他模式或驱动不适配。检查支持数据传输的 USB 线、手机状态和设备管理器。本工具忽略无线设备和模拟器。'
    }
}

function Start-EnvironmentCheck {
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    $directory = Join-Path $script:ToolRoot 'env-report'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $stem = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $script:LogPath = Join-Path $directory ($stem + '.commands.log')
    $report = Join-Path $directory ($stem + '.txt')
    Say 'iQOO Neo8 环境检测'
    Say '只检查电脑和手机状态，不重启、不解锁、不写分区。手机可能出现 Shell Root 授权提示。'
    Add-EnvCheck 'PASS' 'Windows PowerShell' ($PSVersionTable.PSVersion.ToString())
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($script:ToolRoot))
    $free = [math]::Round($drive.AvailableFreeSpace / 1GB, 2)
    if ($drive.AvailableFreeSpace -ge 512MB) { Add-EnvCheck 'PASS' '备份空间及报告目录写入' ("剩余 $free GB；满足工具至少 512MB 的要求。") }
    else { Add-EnvCheck 'FAIL' '备份空间' ("剩余 $free GB；工具至少需要 512MB。") }
    Show-DriverSnapshot
    $adbReady = $false; $fastbootReady = $false
    try {
        Find-Tools
        foreach ($name in @('Adb', 'Fastboot')) {
            try {
                $path = Get-Variable -Name $name -Scope Script -ValueOnly
                $versionArgs = @('--version')
                if ($name -eq 'Adb') { $versionArgs = @('version') }
                $result = Invoke-External $path $versionArgs 12
                Require-OK $result ($name + ' 无法运行')
                if ($result.Text -notmatch '(?i)version') { throw '没有返回预期的版本信息' }
                Add-EnvCheck 'PASS' ($name + ' 可运行') ($path + "`n  " + $result.Text)
                if ($name -eq 'Adb' -and $result.Text -match '(?im)^Version\s+36\.0\.[01](?:[-\s]|$)') {
                    Add-EnvCheck 'WARN' 'ADB 版本存在已知问题' 'Google 发布说明记录了 Windows 上这些版本可能截断下载文件的问题。请先更新官方 Platform-Tools 再做备份和解锁；本次仍可继续只读连接检测。参考：https://developer.android.com/tools/releases/platform-tools'
                }
                if ($name -eq 'Adb') { $adbReady = $true } else { $fastbootReady = $true }
            } catch { Add-EnvCheck 'FAIL' ($name + ' 不可用') ('请解压完整的 Platform-Tools，保留配套文件。' + $_.Exception.Message) }
        }
    } catch {
        Add-EnvCheck 'FAIL' '电脑工具未就绪' ('请把完整 platform-tools 文件夹放到 BAT 旁边。官方下载：https://developer.android.com/tools/releases/platform-tools 。' + $_.Exception.Message)
    }
    Check-Connections $adbReady $fastbootReady
    $failed = @($script:EnvChecks | Where-Object Level -eq 'FAIL').Count
    $pending = @($script:EnvChecks | Where-Object Level -eq 'WARN').Count
    Say ''
    Say ("检测结束：$failed 项未通过，$pending 项待处理或尚未验证。请按对应提示处理。")
    $lines = @('iQOO Neo8 环境检测报告', (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), '')
    foreach ($check in $script:EnvChecks) { $lines += ('[{0}] {1}' -f $check.Level, $check.Title); $lines += $check.Detail; $lines += '' }
    $lines += "未通过：$failed；待处理/未验证：$pending。检测不等于最终解锁适配确认。"
    [IO.File]::WriteAllLines($report, [string[]]$lines, $script:Utf8)
    Say ('报告已保存：' + $report)
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Start-EnvironmentCheck } catch { Write-Host ('检测停止：' + $_.Exception.Message) -ForegroundColor Red; exit 1 }
}
