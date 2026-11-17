#requires -Version 5.1
<#
.SYNOPSIS
    HUAWEI 星闪鼠标任务栏托盘：官方反白 logo 图标 + 悬停看电量 + 点击打开 GoPlay，
    并可以规定 HUAWEI GoPlay 关闭时是「最小化到托盘」还是「直接退出」。

.DESCRIPTION
    图标使用官方规范 2.07「标志的其他形态」里的反白标志（preview/nearlink-white.ico），
    图标本身不画电量，保持 logo 原样。

      * 左键单击  -> 打开 HUAWEI GoPlay（已隐藏则唤回，不会开第二个实例）
      * 右键菜单  -> 当前电量 / 打开 HUAWEI GoPlay / 关闭 GoPlay 时（最小化到托盘 | 直接退出）/
                     立即退出 HUAWEI GoPlay / 立即刷新 / 开机自动启动 / 退出
      * 悬停提示  -> 当前电量百分比

    电量读的是 Windows 对该 BLE 设备电池服务（GATT 0x180F）的缓存值，
    和「设置 > 蓝牙和设备」以及 GoPlay 里显示的数字同源。
    读取走 CfgMgr32.dll 的 CM_Get_DevNode_PropertyW，不经过 WMI，单次约 0.2 ms。

    GoPlay 自己点 X 只会把主窗口（窗口类 MainWnd）隐藏起来、进程继续留在后台；
    这里用轻量窗口探测识别「刚被关闭」这一刻，再按设置决定是否结束进程。

    轮询只有一条 1 秒节拍（单 Timer，全脚本唯一的常驻循环）：
      * GoPlay 在跑  -> 每秒一次，且窗口句柄缓存后只做 IsWindow + IsWindowVisible 两次 API 调用；
      * GoPlay 没跑  -> 降到每 3 秒一次进程名查询，窗口枚举一次都不做；
      * 电量         -> 按 IntervalSeconds 计数触发，且优先复用缓存的 BLE 实例，
                        不再每次全量枚举设备。

.PARAMETER Once
    只读一次状态并输出 JSON，不启动托盘（自检用）。

.PARAMETER IntervalSeconds
    电量轮询间隔，默认 10 秒。
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [int]$IntervalSeconds = 10,
    [string]$TraceFile,
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'

$script:TracePath = $null
function Write-Trace {
    param([string]$Message)
    if ([string]::IsNullOrEmpty($script:TracePath)) { return }
    try { Add-Content -LiteralPath $script:TracePath -Value ("{0:HH:mm:ss.fff}  {1}" -f (Get-Date), $Message) -Encoding UTF8 } catch { }
}

if (-not [string]::IsNullOrEmpty($TraceFile)) { $script:TracePath = $TraceFile }
# 菜单/托盘回调统一入口：异常一律落到 trace。
function Invoke-Guarded {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
    } catch {
        Write-Trace ("handler[" + $Name + "] ERROR: " + $_.Exception.ToString())
    }
}

Write-Trace 'script start'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class NearLinkCfg
{
    [StructLayout(LayoutKind.Sequential)]
    public struct DEVPROPKEY { public Guid fmtid; public uint pid; }

    [DllImport("CfgMgr32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int CM_Get_Device_ID_List_SizeW(out uint size, string filter, uint flags);

    [DllImport("CfgMgr32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int CM_Get_Device_ID_ListW(string filter, StringBuilder buffer, uint len, uint flags);

    [DllImport("CfgMgr32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int CM_Locate_DevNodeW(out uint devInst, string deviceId, uint flags);

    [DllImport("CfgMgr32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int CM_Get_DevNode_PropertyW(uint devInst, ref DEVPROPKEY key, out uint propType, byte[] buffer, ref uint size, uint flags);

    public static readonly Guid GUID_BLUETOOTH = new Guid("104EA319-6EE2-4701-BD47-8DDBF425BBE5");
    public static readonly Guid GUID_DEVICE = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0");
}

public static class GoPlayWin
{
    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    public static IntPtr FindWindowByClass(uint pid, string className)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) =>
        {
            uint owner;
            GetWindowThreadProcessId(h, out owner);
            if (owner != pid) return true;
            var sb = new StringBuilder(256);
            GetClassName(h, sb, 256);
            if (sb.ToString() == className) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // 句柄缓存后的快路径：两次 API 调用，不再遍历窗口
    public static bool IsAlive(IntPtr hWnd)
    {
        return hWnd != IntPtr.Zero && IsWindow(hWnd);
    }

    public static bool IsAliveVisible(IntPtr hWnd)
    {
        return hWnd != IntPtr.Zero && IsWindow(hWnd) && IsWindowVisible(hWnd);
    }

    public static void BringToFront(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero) return;
        ShowWindow(hWnd, 9);   // SW_RESTORE
        ShowWindow(hWnd, 5);   // SW_SHOW
        SetForegroundWindow(hWnd);
    }
}
'@

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------

$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $script:ScriptDir 'HuaweiMouseTray.ps1' }
# GoPlay 路径：默认留空，交给注册表探测。需要固定路径时设环境变量
# HUAWEIMOUSETRAY_GOPLAY，或在 settings.json 里写 "goPlayPath"。
$script:DefaultGoPlay = if ($env:HUAWEIMOUSETRAY_GOPLAY) { $env:HUAWEIMOUSETRAY_GOPLAY } else { '' }
$script:GoPlayPathOverride = ''
$script:GoPlayProcessName = 'HUAWEI GoPlay'
$script:GoPlayWindowClass = 'MainWnd'
$script:IconPath = Join-Path $script:ScriptDir 'icons\tray.ico'
$script:SettingsPath = Join-Path $script:ScriptDir 'settings.json'

$script:State = [pscustomobject]@{
    InstanceId = $null
    Name       = $null
    Level      = $null
    UpdatedAt  = $null
}

# GoPlay 关闭时的行为：'exit' = 直接退出，'minimize' = 留在托盘
$script:Settings = [pscustomobject]@{
    displayName = ''
    goPlayClose = 'exit'
    levelColor  = $true
    thinIcon    = $true
    # 判定「用户关掉了 GoPlay」的门槛（秒）：窗口连续可见 + 进程存活
    goPlayCloseMinVisible = 0.5
    goPlayCloseMinAlive   = 5.0
    # 退出托盘时是否顺手结束 GoPlay（默认关）
    killGoPlayOnExit = $false
}

function Load-Settings {
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return }
    try {
        $raw = [System.IO.File]::ReadAllText($script:SettingsPath, [System.Text.Encoding]::UTF8)
        $raw = $raw.TrimStart([char]0xFEFF)          # 去掉可能存在的 BOM
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $data = $raw | ConvertFrom-Json
        if ($null -ne $data.goPlayClose -and $data.goPlayClose -in @('exit', 'minimize')) {
            $script:Settings.goPlayClose = $data.goPlayClose
        }
        if ($null -ne $data.levelColor) {
            $script:Settings.levelColor = [bool]$data.levelColor
        }
        if ($null -ne $data.displayName) {
            $script:Settings.displayName = ([string]$data.displayName).Trim()
        }
        if ($null -ne $data.thinIcon) {
            $script:Settings.thinIcon = [bool]$data.thinIcon
        }
        if ($null -ne $data.goPlayCloseMinVisible) {
            $script:Settings.goPlayCloseMinVisible = [double]$data.goPlayCloseMinVisible
        }
        if ($null -ne $data.goPlayCloseMinAlive) {
            $script:Settings.goPlayCloseMinAlive = [double]$data.goPlayCloseMinAlive
        }
        if ($null -ne $data.goPlayPath) {
            $script:GoPlayPathOverride = ([string]$data.goPlayPath).Trim()
        }
        if ($null -ne $data.killGoPlayOnExit) {
            $script:Settings.killGoPlayOnExit = [bool]$data.killGoPlayOnExit
        }
    } catch {
        Write-Trace "读取设置失败：$($_.Exception.Message)"
    }
}

function Save-Settings {
    try {
        $json = $script:Settings | ConvertTo-Json
        [System.IO.File]::WriteAllText($script:SettingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Trace "保存设置失败：$($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 设备读取
# ---------------------------------------------------------------------------

function Read-DevNodeProperty {
    param([uint32]$DevInst, [Guid]$PropertyGuid, [uint32]$PropertyId)

    $key = New-Object NearLinkCfg+DEVPROPKEY
    $key.fmtid = $PropertyGuid
    $key.pid = $PropertyId

    [uint32]$type = 0
    [uint32]$size = 2048
    $buffer = New-Object byte[] 2048
    $rc = [NearLinkCfg]::CM_Get_DevNode_PropertyW($DevInst, [ref]$key, [ref]$type, $buffer, [ref]$size, 0)
    if ($rc -ne 0) { return $null }

    switch ($type) {
        3  { return [int]$buffer[0] }
        5  { return [int][BitConverter]::ToUInt16($buffer, 0) }
        7  { return [int][BitConverter]::ToUInt32($buffer, 0) }
        18 { return [Text.Encoding]::Unicode.GetString($buffer, 0, [int]$size).TrimEnd([char]0) }
        default { return $null }
    }
}

function Get-BthLeDeviceIds {
    [uint32]$size = 0
    $null = [NearLinkCfg]::CM_Get_Device_ID_List_SizeW([ref]$size, 'BTHLE', 1)
    if ($size -le 0) { return @() }
    $builder = New-Object Text.StringBuilder ([int]$size)
    $null = [NearLinkCfg]::CM_Get_Device_ID_ListW('BTHLE', $builder, [uint32]$size, 1)
    return @($builder.ToString().Split([char]0) | Where-Object { $_ -ne '' })
}

# GoPlay 不在时的充电兜底：鼠标走 USB 直连（VID_12D1&PID_10DA）就说明插着线。
function Test-UsbMouseAttached {
    [uint32]$size = 0
    $rc = [NearLinkCfg]::CM_Get_Device_ID_List_SizeW([ref]$size, 'USB', 1)
    if ($rc -ne 0 -or $size -le 0) { return $false }
    $builder = New-Object Text.StringBuilder ([int]$size)
    $rc = [NearLinkCfg]::CM_Get_Device_ID_ListW('USB', $builder, [uint32]$size, 1)
    if ($rc -ne 0) { return $false }
    foreach ($id in $builder.ToString().Split([char]0)) {
        if ($id -match 'VID_12D1&PID_10DA') { return $true }
    }
    return $false
}

function Locate-DevNode {
    param([string]$InstanceId)
    if ([string]::IsNullOrEmpty($InstanceId)) { return $null }
    [uint32]$devInst = 0
    if ([NearLinkCfg]::CM_Locate_DevNodeW([ref]$devInst, $InstanceId, 0) -ne 0) { return $null }
    if ($devInst -eq 0) { return $null }
    return $devInst
}

function Read-BatteryLevel {
    param([uint32]$DevInst)
    $level = Read-DevNodeProperty -DevInst $DevInst -PropertyGuid ([NearLinkCfg]::GUID_BLUETOOTH) -PropertyId 2
    if ($null -eq $level -or $level -lt 0 -or $level -gt 100) { return $null }
    return [int]$level
}

# GoPlay 用 USB 连鼠标时会把每次轮询结果写进 NeoUsb.log：
#   "get power value 100 power state 2" / "Device Index=4 PowerValue=100"
# 这是和它界面上显示完全一致的真值，比 Windows 那个蓝牙缓存靠谱。
$script:GoPlayUsbLog = Join-Path $env:LOCALAPPDATA 'HUAWEI GoPlay\NeoUsb.log'

function Get-GoPlayLogBattery {
    $path = $script:GoPlayUsbLog
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $info = Get-Item -LiteralPath $path
        # 超过 24 小时没更新就认为不是当前连接状态，交给蓝牙缓存兜底
        if (((Get-Date) - $info.LastWriteTime).TotalHours -gt 24) { return $null }
        $tail = Get-Content -LiteralPath $path -Tail 400 -ErrorAction Stop
    } catch { return $null }

    $level = $null
    $state = $null
    foreach ($line in $tail) {
        if ($line -match 'PowerValue=(\d+)') { $level = [int]$matches[1] }
        elseif ($line -match 'power value (\d+) power state (\d+)') { $level = [int]$matches[1]; $state = [int]$matches[2] }
    }
    if ($null -eq $level -or $level -lt 0 -or $level -gt 100) { return $null }
    return [pscustomobject]@{ Level = $level; State = $state }
}

function Get-MouseBattery {
    # GoPlay 日志读不到时的兜底：USB 在场即视为充电中（约 0.2 ms）
    $usbCharging = $false
    try { $usbCharging = Test-UsbMouseAttached } catch { }

    # 优先用 GoPlay 的 USB 日志（真值）
    $fromGoPlay = Get-GoPlayLogBattery
    if ($null -ne $fromGoPlay) {
        return [pscustomobject]@{
            Connected  = $true
            Name       = 'HUAWEI Mouse CD28S-63'
            Level      = $fromGoPlay.Level
            InstanceId = $script:State.InstanceId
            Source     = 'goplay'
            Charging   = ($fromGoPlay.State -ge 1)
            Full       = ($fromGoPlay.State -eq 2)
        }
    }
    # 快路径：上次锁定的设备实例还在，就只读「电量」这一个属性，
    # 不再把整条 BTHLE 设备列表拉一遍。
    $cachedId = $script:State.InstanceId
    if (-not [string]::IsNullOrEmpty($cachedId)) {
        $devInst = Locate-DevNode -InstanceId $cachedId
        if ($null -ne $devInst) {
            $level = Read-BatteryLevel -DevInst $devInst
            if ($null -ne $level) {
                $name = $script:State.Name
                if ([string]::IsNullOrEmpty($name)) {
                    $name = Read-DevNodeProperty -DevInst $devInst -PropertyGuid ([NearLinkCfg]::GUID_DEVICE) -PropertyId 14
                }
                return [pscustomobject]@{ Connected = $true; Name = $name; Level = $level; InstanceId = $cachedId; Source = 'ble'; Charging = $usbCharging; Full = $false }
            }
        } else {
            # 设备节点已经消失（换设备 / 配对被删），缓存作废
            $script:State.InstanceId = $null
        }
    }

    $candidates = @()
    foreach ($id in Get-BthLeDeviceIds) {
        $devInst = Locate-DevNode -InstanceId $id
        if ($null -eq $devInst) { continue }

        $name = Read-DevNodeProperty -DevInst $devInst -PropertyGuid ([NearLinkCfg]::GUID_DEVICE) -PropertyId 14
        $level = Read-BatteryLevel -DevInst $devInst
        if ($null -eq $level) { continue }

        $candidates += [pscustomobject]@{
            InstanceId = $id
            Name       = if ($null -eq $name) { 'BLE 设备' } else { $name }
            Level      = $level
            IsHuawei   = ($null -ne $name -and $name -match 'HUAWEI')
        }
    }

    $picked = $candidates | Where-Object { $_.IsHuawei } | Select-Object -First 1
    if ($null -eq $picked) { $picked = $candidates | Select-Object -First 1 }

    if ($null -eq $picked) {
        return [pscustomobject]@{ Connected = $false; Name = $script:State.Name; Level = $null; InstanceId = $null }
    }
    return [pscustomobject]@{ Connected = $true; Name = $picked.Name; Level = $picked.Level; InstanceId = $picked.InstanceId; Source = 'ble'; Charging = $usbCharging; Full = $false }
}

# ---------------------------------------------------------------------------
# HUAWEI GoPlay
# ---------------------------------------------------------------------------

function Get-GoPlayPath {
    if ($script:GoPlayPathOverride -and (Test-Path -LiteralPath $script:GoPlayPathOverride)) { return $script:GoPlayPathOverride }
    if (Test-Path -LiteralPath $script:DefaultGoPlay) { return $script:DefaultGoPlay }
    foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        $entry = Get-ItemProperty $root -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -eq 'HUAWEI GoPlay' } | Select-Object -First 1
        if ($null -ne $entry -and $entry.DisplayIcon) {
            $icon = $entry.DisplayIcon -replace '^"', ''
            $icon = $icon -replace '",\d+$', ''
            $icon = $icon -replace ',\d+$', ''
            if (Test-Path -LiteralPath $icon) { return $icon }
        }
    }
    return $null
}

function Get-GoPlayProcess {
    return Get-Process -Name $script:GoPlayProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-GoPlayWindow {
    param([int]$Id)
    if ($Id -le 0) { return [IntPtr]::Zero }
    return [GoPlayWin]::FindWindowByClass([uint32]$Id, $script:GoPlayWindowClass)
}

# 「窗口一出来就唤到前台」改成节拍驱动：点击回调里不再 Sleep 轮询，菜单不会卡住
$script:PendingFront = [pscustomobject]@{ Pid = 0; Deadline = [datetime]::MinValue }

function Start-GoPlay {
    $null = Stop-GoPlayDuplicates
    $proc = Get-GoPlayProcess
    if ($null -ne $proc) {
        $hwnd = Get-GoPlayWindow -Id $proc.Id
        if ($hwnd -ne [IntPtr]::Zero) { [GoPlayWin]::BringToFront($hwnd); return }
        # 进程在、窗口还没出来（可能带着「上次隐藏」的状态启动）：交给节拍去等
        $script:PendingFront.Pid = $proc.Id
        $script:PendingFront.Deadline = (Get-Date).AddSeconds(6)
        return
    }

    $exe = Get-GoPlayPath
    if ($null -eq $exe) {
        [System.Windows.Forms.MessageBox]::Show('没有找到 HUAWEI GoPlay。请把安装路径写进 settings.json 的 goPlayPath，或设置环境变量 HUAWEIMOUSETRAY_GOPLAY。', '星闪电量') | Out-Null
        return
    }
    $started = Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -PassThru
    $script:PendingFront.Pid = if ($null -ne $started) { $started.Id } else { 0 }
    $script:PendingFront.Deadline = (Get-Date).AddSeconds(6)
}

function Update-PendingFront {
    param([datetime]$Now)
    if ($Now -gt $script:PendingFront.Deadline) { return }
    try {
        $targetId = $script:PendingFront.Pid
        $hwnd = Get-GoPlayWindow -Id $targetId
        if ($hwnd -eq [IntPtr]::Zero) {
            # launcher 可能又起了子进程，按名字兜底找一次
            $proc = Get-GoPlayProcess
            if ($null -ne $proc) {
                $targetId = $proc.Id
                $hwnd = Get-GoPlayWindow -Id $targetId
            }
        }
        if ($hwnd -ne [IntPtr]::Zero) {
            [GoPlayWin]::BringToFront($hwnd)
            $script:PendingFront.Deadline = [datetime]::MinValue
            $script:PendingFront.Pid = 0
        }
    } catch {
        Write-Trace ("front ERROR: " + $_.Exception.Message)
    }
}

function Stop-GoPlay {
    $procs = @(Get-Process -Name $script:GoPlayProcessName -ErrorAction SilentlyContinue)
    foreach ($proc in $procs) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { Write-Trace "结束 GoPlay 失败：$($_.Exception.Message)" }
    }
    return $procs.Count
}

# 至多保留一个 GoPlay：优先留有可见主窗口的，其次留启动最早的，其余关掉。
function Stop-GoPlayDuplicates {
    $procs = @(Get-Process -Name $script:GoPlayProcessName -ErrorAction SilentlyContinue)
    if ($procs.Count -le 1) { return 0 }

    $keep = $null
    foreach ($p in $procs) {
        if ([GoPlayWin]::IsAliveVisible((Get-GoPlayWindow -Id $p.Id))) { $keep = $p; break }
    }
    if ($null -eq $keep) {
        $keep = $procs | Sort-Object StartTime | Select-Object -First 1
    }

    $killed = 0
    foreach ($p in $procs) {
        if ($p.Id -eq $keep.Id) { continue }
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            $killed++
        } catch {
            Write-Trace ("dedupe: 结束 pid=$($p.Id) 失败 " + $_.Exception.Message)
        }
    }
    if ($killed -gt 0) {
        Write-Trace ("dedupe: 保留 pid=$($keep.Id)，结束 $killed 个多余 GoPlay")
    }
    return $killed
}

# 上一次观察到的 GoPlay 窗口状态。窗口句柄缓存住，稳态下每秒只做
# IsWindow + IsWindowVisible 两次 API 调用，不再遍历全部顶层窗口。
$script:GoPlayWatch = [pscustomobject]@{
    Pid          = 0
    Hwnd         = [IntPtr]::Zero
    Visible      = $false
    VisibleSince = $null
    StartedAt    = $null
    LastProbeAt  = $null
    EverVisible  = $false   # 这个进程是否露过脸（用来判断「憋在后台」的残留）
}
$script:GoPlayWatchEnabled = $false
$script:GoPlayDedupeAt = $null

# GoPlay 没在跑的时候，进程名查询降到 3 秒一次；它在跑时保持 1 秒
$script:GoPlayIdleProbeSeconds = 3

function Reset-GoPlayWatch {
    $script:GoPlayWatch.Pid = 0
    $script:GoPlayWatch.Hwnd = [IntPtr]::Zero
    $script:GoPlayWatch.Visible = $false
    $script:GoPlayWatch.VisibleSince = $null
    $script:GoPlayWatch.StartedAt = $null
    $script:GoPlayWatch.EverVisible = $false
}

function Update-GoPlayWatch {
    param([datetime]$Now = (Get-Date))
    if (-not $script:GoPlayWatchEnabled) { return }
    try {
        # 空闲降频：Pid 归零（没在跑）时不必每秒查一次进程表
        if ($script:GoPlayWatch.Pid -eq 0 -and $null -ne $script:GoPlayWatch.LastProbeAt -and
            ($Now - $script:GoPlayWatch.LastProbeAt).TotalSeconds -lt $script:GoPlayIdleProbeSeconds) {
            return
        }

        $proc = Get-GoPlayProcess
        $script:GoPlayWatch.LastProbeAt = $Now

        if ($null -eq $proc) {
            if ($script:GoPlayWatch.Pid -ne 0) { Reset-GoPlayWatch }
            return
        }

        # 至多一个 GoPlay：多开就关掉多余的，5 秒查一次免得日志刷屏
        if ($null -eq $script:GoPlayDedupeAt -or ($Now - $script:GoPlayDedupeAt).TotalSeconds -ge 5) {
            $script:GoPlayDedupeAt = $Now
            $null = Stop-GoPlayDuplicates
        }

        if ($script:GoPlayWatch.Pid -ne $proc.Id) {
            Reset-GoPlayWatch
            $script:GoPlayWatch.Pid = $proc.Id
            # 用进程的真实启动时间，而不是「首次被探测到的时间」。
            # 空闲探测是 3 秒一次，用 $Now 会把存活时间少算最多 3 秒，
            # 于是刚用几秒就关掉的 GoPlay 会被误判成「启动阶段」而不处理。
            $startedAt = $Now
            try { $startedAt = $proc.StartTime } catch { }
            $script:GoPlayWatch.StartedAt = $startedAt
            # 新进程：必须先枚举一次窗口，把句柄找出来
            $script:GoPlayWatch.Hwnd = Get-GoPlayWindow -Id $proc.Id
        } elseif (-not [GoPlayWin]::IsAlive($script:GoPlayWatch.Hwnd)) {
            # 缓存的句柄失效（窗口重建 / 启动时窗口还没建出来）：补一次枚举
            $script:GoPlayWatch.Hwnd = Get-GoPlayWindow -Id $proc.Id
        }

        $visible = [GoPlayWin]::IsAliveVisible($script:GoPlayWatch.Hwnd)
        if ($visible -and $null -eq $script:GoPlayWatch.VisibleSince) { $script:GoPlayWatch.VisibleSince = $Now }

        $wasVisible = $script:GoPlayWatch.Visible
        $script:GoPlayWatch.Visible = $visible
        if ($visible) { $script:GoPlayWatch.EverVisible = $true }

        # 「平时只有托盘」：GoPlay 从没显示过窗口、却已经存活 15 秒以上 —— 这是憋在后台的残留。
        if ($script:Settings.goPlayClose -eq 'exit' -and -not $visible -and
            -not $script:GoPlayWatch.EverVisible) {
            $aliveForLingering = if ($null -ne $script:GoPlayWatch.StartedAt) { ($Now - $script:GoPlayWatch.StartedAt).TotalSeconds } else { 0 }
            if ($aliveForLingering -ge 15) {
                $killedLingering = Stop-GoPlay
                Write-Trace ("lingering: GoPlay 从未显示窗口、已存活 {0:N0}s，结束 {1} 个" -f $aliveForLingering, $killedLingering)
                Reset-GoPlayWatch
                return
            }
        }

        # 只在「窗口稳定显示过一会儿」之后消失，才当成用户关掉了它
        # （GoPlay 自己启动时会先亮 2 秒窗口再隐藏，不能误判）
        if ($wasVisible -and -not $visible) {
            $visibleFor = if ($null -ne $script:GoPlayWatch.VisibleSince) { ($Now - $script:GoPlayWatch.VisibleSince).TotalSeconds } else { 0 }
            $aliveFor = if ($null -ne $script:GoPlayWatch.StartedAt) { ($Now - $script:GoPlayWatch.StartedAt).TotalSeconds } else { 0 }
            Write-Trace ("GoPlay 窗口隐藏（已显示 {0:N1}s，进程存活 {1:N1}s）" -f $visibleFor, $aliveFor)
            $minAlive = [double]$script:Settings.goPlayCloseMinAlive
            $minVisible = [double]$script:Settings.goPlayCloseMinVisible
            if ($aliveFor -ge $minAlive -and $visibleFor -ge $minVisible -and $script:Settings.goPlayClose -eq 'exit') {
                $count = Stop-GoPlay
                Write-Trace "按设置结束 GoPlay 进程（$count 个）"
                Reset-GoPlayWatch
            } else {
                Write-Trace '启动阶段 / 显示时间过短，忽略'
            }
        }

        # 窗口一隐藏就把「可见起点」清掉：否则这个时间戳会跨越多段可见时间，
        # 让「连续可见满 3 秒」的防护在第一次隐藏之后形同虚设。
        if (-not $visible) { $script:GoPlayWatch.VisibleSince = $null }
    } catch {
        Write-Trace ("watch ERROR: " + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# 开机自启
# ---------------------------------------------------------------------------

$script:VbsPath = Join-Path $script:ScriptDir 'start-hidden.vbs'
$script:StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'HuaweiMouseTray.lnk'

function Test-Autostart {
    return (Test-Path -LiteralPath $script:StartupLink)
}

function Set-Autostart {
    param([bool]$Enabled)
    if ($Enabled) {
        if (-not (Test-Path -LiteralPath $script:VbsPath)) { return }
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($script:StartupLink)
        $link.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $link.Arguments = '//nologo "' + $script:VbsPath + '"'
        $link.WorkingDirectory = $script:ScriptDir
        $link.IconLocation = $script:IconPath
        $link.Description = 'HUAWEI 星闪鼠标电量托盘'
        $link.Save()
    } elseif (Test-Path -LiteralPath $script:StartupLink) {
        Remove-Item -LiteralPath $script:StartupLink -Force
    }
}

Load-Settings

# ---------------------------------------------------------------------------
# 自检模式
# ---------------------------------------------------------------------------

# 图标资源分两套：icons\thin（不加粗）与 icons\bold（加粗）
$script:IconSubdir = if ($script:Settings.thinIcon) { 'icons\thin' } else { 'icons\bold' }
$script:IconPath = Join-Path $script:ScriptDir ($script:IconSubdir + '\tray.ico')

if ($Once) {
    $probe = Get-MouseBattery
    $goPlay = Get-GoPlayProcess
    $hwnd = if ($null -eq $goPlay) { [IntPtr]::Zero } else { Get-GoPlayWindow -Id $goPlay.Id }
    [pscustomobject]@{
        Connected       = $probe.Connected
        Name            = $probe.Name
        Level           = $probe.Level
        Charging        = [bool]$probe.Charging
        Full            = [bool]$probe.Full
        UsbAttached     = (Test-UsbMouseAttached)
        GoPlayRunning   = ($null -ne $goPlay)
        GoPlayVisible   = ($hwnd -ne [IntPtr]::Zero) -and [GoPlayWin]::IsWindowVisible($hwnd)
        GoPlayCloseMode = $script:Settings.goPlayClose
        LevelColor      = $script:Settings.levelColor
        ThinIcon        = $script:Settings.thinIcon
        Icon            = $script:IconPath
        IconExists      = (Test-Path -LiteralPath $script:IconPath)
        Autostart       = Test-Autostart
    } | ConvertTo-Json -Compress
    return
}

# ---------------------------------------------------------------------------
# -Restart：先结束已经在跑的实例，保证图标一定重新出现
# ---------------------------------------------------------------------------
# 图标不见时进程可能还活着（互斥体被占着），直接重新拉起会被单实例挡住。
# 桌面快捷方式就是带 -Restart 调用的：双击 = 关掉旧的 + 起一个新的。

if ($Restart) {
    # 用绝对脚本路径做匹配，避免误伤命令行里恰好出现脚本名的其它 PowerShell
    $selfPattern = '*-File*' + $script:ScriptPath + '*'
    $stale = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $PID -and
        $_.Name -eq 'powershell.exe' -and
        $_.CommandLine -like $selfPattern
    })
    Write-Trace ("restart: self=$PID pattern=$selfPattern matched=$($stale.Count)")
    foreach ($proc in $stale) {
        Write-Trace ("restart: killing pid=$($proc.ProcessId)")
        try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop } catch { Write-Trace "结束旧实例失败：$($_.Exception.Message)" }
    }
    if ($stale.Count -gt 0) { Start-Sleep -Milliseconds 1200 }
    Write-Trace ("restart: 结束 {0} 个旧实例" -f $stale.Count)
}

# ---------------------------------------------------------------------------
# 单实例
# ---------------------------------------------------------------------------

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\HuaweiNearLinkBatteryTray', [ref]$createdNew)
if (-not $createdNew) {
    Write-Warning '托盘已经在运行了。'
    return
}

# 拿到锁之后清掉同脚本的残留实例：保证「至多一个托盘」。
$selfPattern = '*-File*' + $script:ScriptPath + '*'
$parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).ParentProcessId
$strays = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessId -ne $PID -and
    $_.ProcessId -ne $parentPid -and
    $_.Name -eq 'powershell.exe' -and
    $_.CommandLine -like $selfPattern
})
foreach ($p in $strays) {
    try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        Write-Trace ("single-instance: 结束残留 pid=$($p.ProcessId)")
    } catch {
        Write-Trace ("single-instance: 结束 pid=$($p.ProcessId) 失败 " + $_.Exception.Message)
    }
}
if ($strays.Count -gt 0) { Write-Trace ("single-instance: 共清理 {0} 个残留实例" -f $strays.Count) }

# 「平时只有托盘」：自己起来的时候，若 GoPlay 还在后台憋着（没有可见主窗口），一并清掉。
if ($script:Settings.goPlayClose -eq 'exit') {
    try {
        foreach ($p in @(Get-Process -Name $script:GoPlayProcessName -ErrorAction SilentlyContinue)) {
            $hw = Get-GoPlayWindow -Id $p.Id
            if (-not [GoPlayWin]::IsAliveVisible($hw)) {
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                Write-Trace ("startup: 清理后台残留 GoPlay pid=$($p.Id)")
            }
        }
    } catch {
        Write-Trace ("startup: 清理 GoPlay 异常 " + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# 托盘
# ---------------------------------------------------------------------------

# WinForms 只在真正要建托盘时才加载；-Once 自检不碰它，启动更快
. (Join-Path $script:ScriptDir 'dpi-aware.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $script:IconPath)) {
    throw "找不到图标文件：$($script:IconPath)"
}

# 按当前 DPI 选一个正好匹配任务栏尺寸的帧，避免被系统缩放糊掉
# PowerShell 5.1 不是 DPI 感知进程，Graphics.DpiX 只会返回 96；
# 直接读系统的缩放设置（AppliedDPI：96 / 120 / 144 / 192...）
$appliedDpi = 96
try {
    $wm = Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction Stop
    if ($null -ne $wm.AppliedDPI -and $wm.AppliedDPI -gt 0) { $appliedDpi = [int]$wm.AppliedDPI }
} catch {
    $dpiGraphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $appliedDpi = [int]$dpiGraphics.DpiX
    $dpiGraphics.Dispose()
}
$iconSize = [int][math]::Round(16 * ($appliedDpi / 96.0))
Write-Trace ("applied dpi: {0} -> tray icon {1}px" -f $appliedDpi, $iconSize)
$iconSize = [math]::Min(64, [math]::Max(16, $iconSize))
$script:Icon = New-Object System.Drawing.Icon($script:IconPath, $iconSize, $iconSize)
Write-Trace ("icon loaded: {0}x{1} (requested {2})" -f $script:Icon.Width, $script:Icon.Height, $iconSize)

# 按电量分档的图标：高=品牌绿、中=反白、低=红
$script:LevelIcons = @{}
foreach ($levelName in 'green', 'yellow', 'red', 'white', 'black') {
    $levelPath = Join-Path $script:ScriptDir ($script:IconSubdir + '\tray-' + $levelName + '.ico')
    if (Test-Path -LiteralPath $levelPath) {
        $script:LevelIcons[$levelName] = New-Object System.Drawing.Icon($levelPath, $iconSize, $iconSize)
    }
}
Write-Trace ("level icons: " + (($script:LevelIcons.Keys | Sort-Object) -join ','))
$script:CurrentLevelColor = ''

# 任务栏是浅色还是深色：托盘图标跟 SystemUsesLightTheme，菜单跟 AppsUseLightTheme
function Test-TaskbarLight {
    try {
        $v = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name SystemUsesLightTheme -ErrorAction Stop
        return ([int]$v.SystemUsesLightTheme -eq 1)
    } catch {
        return $false
    }
}

function Get-LevelBucket {
    param([int]$Level)
    if ($Level -ge 60) { return 'green' }
    if ($Level -gt 35) { return 'yellow' }
    return 'red'
}

function Update-LevelIcon {
    param($Level)
    # 关闭个性化 -> 固定白色
    if (-not $script:Settings.levelColor) {
        # 跟随系统：浅色任务栏用黑色标记，深色任务栏用反白标记
        $want = if (Test-TaskbarLight) { 'black' } else { 'white' }
        if ($script:CurrentLevelColor -ne $want -and $script:LevelIcons.ContainsKey($want)) {
            $script:CurrentLevelColor = $want
            $script:NotifyIcon.Icon = $script:LevelIcons[$want]
            Write-Trace ("level icon -> $want (follow system)")
        }
        return
    }
    if ($null -eq $Level) { return }
    $bucket = Get-LevelBucket -Level ([int]$Level)
    if ($bucket -eq $script:CurrentLevelColor) { return }
    if (-not $script:LevelIcons.ContainsKey($bucket)) { return }
    $script:CurrentLevelColor = $bucket
    $script:NotifyIcon.Icon = $script:LevelIcons[$bucket]
    Write-Trace ("level icon -> $bucket")
}

$script:MenuItemStatus = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuItemStatus.Enabled = $false

$script:MenuItemOpen = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuItemOpen.Text = '打开 HUAWEI GoPlay'
$script:MenuItemOpen.Add_Click({ Invoke-Guarded 'open' { Start-GoPlay } })

$script:MenuItemRefresh = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuItemRefresh.Text = '立即刷新'

$script:MenuItemCloseMode = New-Object System.Windows.Forms.ToolStripMenuItem

$script:MenuItemCloseKeep = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuItemCloseKeep.Text = '最小化到托盘（留在后台）'

$script:MenuItemCloseExit = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuItemCloseExit.Text = '直接退出（不留后台进程）'

function Sync-CloseModeChecks {
    $isExit = $script:Settings.goPlayClose -eq 'exit'
    $script:MenuItemCloseKeep.Checked = -not $isExit
    $script:MenuItemCloseExit.Checked = $isExit
    $script:MenuItemCloseMode.Text = if ($isExit) { '关闭 GoPlay 时：直接退出' } else { '关闭 GoPlay 时：最小化到托盘' }
}

$script:MenuItemCloseKeep.Add_Click({
    Invoke-Guarded 'closeMode:minimize' {
        $script:Settings.goPlayClose = 'minimize'
        Save-Settings
        Sync-CloseModeChecks
        Write-Trace 'closeMode -> minimize'
    }
})

$script:MenuItemCloseExit.Add_Click({
    Invoke-Guarded 'closeMode:exit' {
        $script:Settings.goPlayClose = 'exit'
        Save-Settings
        Sync-CloseModeChecks
        Write-Trace 'closeMode -> exit'
    }
})

$null = $script:MenuItemCloseMode.DropDownItems.Add($script:MenuItemCloseKeep)
$null = $script:MenuItemCloseMode.DropDownItems.Add($script:MenuItemCloseExit)
Sync-CloseModeChecks

$script:MenuItemKillGoPlay = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuItemKillGoPlay.Text = '立即退出 HUAWEI GoPlay'
$script:MenuItemKillGoPlay.Add_Click({
    Invoke-Guarded 'killGoPlay' {
        $count = Stop-GoPlay
        Write-Trace ("killGoPlay -> 结束 {0} 个进程" -f $count)
        if ($count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('HUAWEI GoPlay 当前没有在运行。', '星闪电量') | Out-Null
        }
    }
})

$script:MenuItemLevelColor = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuItemLevelColor.Text = '按电量变色'
$script:MenuItemLevelColor.CheckOnClick = $false
$script:MenuItemLevelColor.Checked = $script:Settings.levelColor
$script:MenuItemLevelColor.Add_Click({
    Invoke-Guarded 'levelColor' {
        $script:Settings.levelColor = -not $script:Settings.levelColor
        Save-Settings
        $script:MenuItemLevelColor.Checked = $script:Settings.levelColor
        $script:CurrentLevelColor = ''
        Update-LevelIcon -Level $script:State.Level
        Write-Trace ("levelColor -> " + $script:Settings.levelColor)
    }
})

$script:MenuItemAutostart = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuItemAutostart.Text = '开机自动启动'
$script:MenuItemAutostart.CheckOnClick = $true
$script:MenuItemAutostart.Checked = Test-Autostart
$script:MenuItemAutostart.Add_Click({
    try { Set-Autostart -Enabled $script:MenuItemAutostart.Checked }
    catch {
        $script:MenuItemAutostart.Checked = Test-Autostart
        [System.Windows.Forms.MessageBox]::Show("设置开机自启失败：$($_.Exception.Message)", '星闪电量') | Out-Null
    }
})

$script:MenuItemExit = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuItemExit.Text = '退出'

# 菜单主题（跟随系统浅色/深色）
. (Join-Path $script:ScriptDir 'menu-theme.ps1')

# 自定义鼠标名称
$script:MenuItemRename = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuItemRename.Text = '设置鼠标名称…'
$script:MenuItemRename.Add_Click({
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $current = if ($script:Settings.displayName) { $script:Settings.displayName } else { $script:State.Name }
        $entered = [Microsoft.VisualBasic.Interaction]::InputBox('给这只鼠标起个名字（留空则用设备名）', '星闪鼠标', [string]$current)
        if ($null -eq $entered) { return }
        $script:Settings.displayName = ([string]$entered).Trim()
        Save-Settings
        Update-Tray -Now (Get-Date)
    } catch {
        Write-Trace ("rename failed: " + $_.Exception.Message)
    }
})

# ---- 图标粗细：细 / 粗两套资源，切换后原地重载 ----
$script:MenuItemWeight = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuItemWeightThin = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuItemWeightThin.Text = '细'
$script:MenuItemWeightBold = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuItemWeightBold.Text = '粗'

function Sync-WeightChecks {
    $thin = [bool]$script:Settings.thinIcon
    $script:MenuItemWeightThin.Checked = $thin
    $script:MenuItemWeightBold.Checked = -not $thin
    $script:MenuItemWeight.Text = if ($thin) { '图标粗细：细' } else { '图标粗细：粗' }
}

function Set-IconWeight {
    param([bool]$Thin)
    $script:Settings.thinIcon = $Thin
    Save-Settings
    $script:IconSubdir = if ($Thin) { 'icons\thin' } else { 'icons\bold' }
    $script:IconPath = Join-Path $script:ScriptDir ($script:IconSubdir + '\tray.ico')

    foreach ($k in @($script:LevelIcons.Keys)) {
        try { $script:LevelIcons[$k].Dispose() } catch { }
    }
    $script:LevelIcons = @{}
    foreach ($levelName in 'green', 'yellow', 'red', 'white', 'black') {
        $levelPath = Join-Path $script:ScriptDir ($script:IconSubdir + '\tray-' + $levelName + '.ico')
        if (Test-Path -LiteralPath $levelPath) {
            $script:LevelIcons[$levelName] = New-Object System.Drawing.Icon($levelPath, $iconSize, $iconSize)
        }
    }
    try { $script:Icon.Dispose() } catch { }
    $script:Icon = New-Object System.Drawing.Icon($script:IconPath, $iconSize, $iconSize)
    $script:CurrentLevelColor = ''
    Update-LevelIcon -Level $script:State.Level
    Sync-WeightChecks
    Write-Trace ("icon weight -> " + $(if ($Thin) { 'thin' } else { 'bold' }))
}

$script:MenuItemWeightThin.Add_Click({ Invoke-Guarded 'weight:thin' { Set-IconWeight -Thin $true } })
$script:MenuItemWeightBold.Add_Click({ Invoke-Guarded 'weight:bold' { Set-IconWeight -Thin $false } })

$null = $script:MenuItemWeight.DropDownItems.Add($script:MenuItemWeightThin)
$null = $script:MenuItemWeight.DropDownItems.Add($script:MenuItemWeightBold)
Sync-WeightChecks

# ---- 个性化子菜单 ----
$script:MenuItemPersonalize = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuItemPersonalize.Text = '个性化'
$null = $script:MenuItemPersonalize.DropDownItems.Add($script:MenuItemLevelColor)
$null = $script:MenuItemPersonalize.DropDownItems.Add($script:MenuItemWeight)
$null = $script:MenuItemPersonalize.DropDownItems.Add($script:MenuItemRename)
$null = $script:MenuItemPersonalize.DropDownItems.Add($script:MenuItemCloseMode)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$null = $menu.Items.Add($script:MenuItemStatus)
$null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$null = $menu.Items.Add($script:MenuItemOpen)
$null = $menu.Items.Add($script:MenuItemKillGoPlay)
$null = $menu.Items.Add($script:MenuItemRefresh)
$null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$null = $menu.Items.Add($script:MenuItemPersonalize)
$null = $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$null = $menu.Items.Add($script:MenuItemAutostart)
$null = $menu.Items.Add($script:MenuItemExit)

Write-Trace 'creating NotifyIcon'
$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:MenuStrip = $menu
$menu.Add_Opening({ Invoke-Guarded 'menu:opening' { Update-MenuTheme } })
$script:NotifyIcon.ContextMenuStrip = $menu
$script:NotifyIcon.Icon = $script:Icon
$script:NotifyIcon.Text = '星闪鼠标电量读取中…'
$script:NotifyIcon.Visible = $true
$script:NotifyIcon.Add_MouseClick({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Invoke-Guarded 'tray:leftClick' { Start-GoPlay }
    }
})

function New-DisconnectedProbe {
    return [pscustomobject]@{ Connected = $false; Name = $script:State.Name; Level = $null; InstanceId = $null }
}

function Update-Tray {
    param([datetime]$Now = (Get-Date))
    try { Update-TrayCore -Now $Now }
    catch { Write-Trace ("tick ERROR: " + $_.Exception.ToString()) }
}

function Update-TrayCore {
    param([datetime]$Now = (Get-Date))
    try {
        $probe = Get-MouseBattery
    } catch {
        $probe = New-DisconnectedProbe
    }

    $script:State.Level = $probe.Level
    $script:State.Name = $probe.Name
    $script:State.InstanceId = $probe.InstanceId
    $script:State.UpdatedAt = $Now
    Update-LevelIcon -Level $probe.Level

    if ($probe.Connected) {
        $shortName = if ($script:Settings.displayName) { $script:Settings.displayName } elseif ($probe.Name -match 'CD28S') { 'CD28S' } else { '星闪鼠标' }
        $sourceTag = if ($probe.Source -eq 'goplay') { '' } else { '（缓存）' }
        $chargeTag = if ($probe.Full) { ' 已充满' } elseif ($probe.Charging) { ' 充电中' } else { '' }
        $script:NotifyIcon.Text = "$shortName 电量 $($probe.Level)%$chargeTag$sourceTag"
        if ($script:NotifyIcon.Text.Length -gt 63) { $script:NotifyIcon.Text = $script:NotifyIcon.Text.Substring(0, 63) }
        $statusName = if ($script:Settings.displayName) { $script:Settings.displayName } else { $probe.Name }
        $script:MenuItemStatus.Text = "$statusName   电量 $($probe.Level)%$chargeTag$sourceTag"
    } else {
        $script:NotifyIcon.Text = '星闪鼠标未连接'
        $script:MenuItemStatus.Text = '星闪鼠标未连接'
    }
}

$script:MenuItemRefresh.Add_Click({
    Invoke-Guarded 'refresh' {
        Update-Tray
        $script:LastBatteryAt = Get-Date
        Write-Trace 'refresh: 手动刷新'
    }
})

# ---------------------------------------------------------------------------
# 唯一常驻节拍
# ---------------------------------------------------------------------------
# 原来是两个 Timer：电量 10 秒一个、GoPlay 1 秒一个。现在合并成 1 秒一个：
#   * 电量按计数触发（IntervalSeconds）；
#   * GoPlay 探测在进程不在时自动降到 3 秒一次；
#   * 「唤到前台」改成在节拍里做，点击回调不再 Start-Sleep 卡菜单。
$script:BatteryIntervalSeconds = [math]::Max(2, $IntervalSeconds)
$script:LastBatteryAt = [datetime]::MinValue

$script:Tick = New-Object System.Windows.Forms.Timer
$script:Tick.Interval = 1000
$script:Tick.Add_Tick({
    $now = Get-Date
    Update-PendingFront -Now $now
    Update-GoPlayWatch -Now $now
    if (($now - $script:LastBatteryAt).TotalSeconds -ge $script:BatteryIntervalSeconds) {
        Update-Tray -Now $now
        $script:LastBatteryAt = $now
    }
})
$script:Tick.Start()
$script:GoPlayWatchEnabled = $true

# 退出：任何一步失败都不能拦住 Application.Exit()，
# 否则进程会活着但图标没了、互斥体还被占着（再启动只会提示「托盘已经在运行了」）。
$script:MenuItemExit.Add_Click({
    Write-Trace 'exit: 用户点了退出'
    try {
        $script:GoPlayWatchEnabled = $false
        $script:Tick.Stop()
        if ($script:Settings.killGoPlayOnExit) {
            $killed = Stop-GoPlay
            Write-Trace ("exit: killGoPlayOnExit -> 结束 {0} 个 GoPlay 进程" -f $killed)
        } else {
            $deduped = Stop-GoPlayDuplicates
            Write-Trace ("exit: 保留至多 1 个 GoPlay，结束 {0} 个多余实例" -f $deduped)
        }
    } catch {
        Write-Trace ("exit: 停止阶段异常 " + $_.Exception.ToString())
    }
    try {
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
    } catch {
        Write-Trace ("exit: 隐藏/释放托盘图标异常 " + $_.Exception.Message)
    }
    try { $script:Icon.Dispose() } catch { Write-Trace ("exit: Icon.Dispose 异常 " + $_.Exception.Message) }
    try { $mutex.ReleaseMutex() } catch { Write-Trace ("exit: ReleaseMutex 异常 " + $_.Exception.Message) }
    try { $mutex.Dispose() } catch { Write-Trace ("exit: Mutex.Dispose 异常 " + $_.Exception.Message) }
    finally {
        Write-Trace 'exit: Application.Exit'
        [System.Windows.Forms.Application]::Exit()
    }
})

Write-Trace 'initial update + message loop'
$script:LastBatteryAt = Get-Date
Update-Tray -Now $script:LastBatteryAt
Update-GoPlayWatch -Now $script:LastBatteryAt
Write-Trace 'entering Application.Run'
[System.Windows.Forms.Application]::Run()
Write-Trace 'Application.Run returned'
