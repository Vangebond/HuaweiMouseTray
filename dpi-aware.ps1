#requires -Version 5.1
# 把当前进程标成 DPI 感知。
# 不这样做的话，150% 缩放下 WinForms 菜单是按 96 DPI 画完再被系统位图放大，字会发虚。
# 必须在任何窗口创建之前调用（主脚本在加载 WinForms / 建 NotifyIcon 之前点源本文件）。

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DpiAwareness
{
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
'@

$script:DpiAware = $false
try {
    $script:DpiAware = [DpiAwareness]::SetProcessDPIAware()
} catch {
    Write-Trace ("SetProcessDPIAware failed: " + $_.Exception.Message)
}
