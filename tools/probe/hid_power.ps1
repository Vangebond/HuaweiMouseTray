#requires -Version 5.1
# 用 GoPlay 的真实字节发查询：report 0x04 + payload 20 00 1a 06
. "$PSScriptRoot\hid_io.ps1"

$guid = '{4d1e55b2-f16f-11cf-88cb-001111000030}'
$root = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$guid"

$names = @(Get-ChildItem $root -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match 'VID_12D1' } |
    ForEach-Object { $_.PSChildName })

$index = 0
foreach ($name in $names) {
    $index++
    $path = $name -replace '^##\?#', '\\?\'
    $h = [HidIo5]::Open($path)
    if ([HidIo5]::IsInvalid($h)) { continue }
    try {
        $caps = [HidIo5]::GetCaps($h)
        if ($caps.InputReportByteLength -ne 64 -or $caps.OutputReportByteLength -ne 64) { continue }

        # 只找接受 0x04 的集合
        $ok04 = $false
        $probe = New-Object byte[] 64
        $probe[0] = 0x04
        if ([HidIo5]::TryWrite($h, $probe, 120) -eq 0) { $ok04 = $true }
        if (-not $ok04) { continue }

        Write-Output ""
        Write-Output ("=== collection #{0}  接受 report 0x04" -f $index)

        # 清空
        for ($k = 0; $k -lt 5; $k++) {
            $j = New-Object byte[] 64; [uint32]$jg = 0
            $null = [HidIo5]::TryRead($h, $j, 40, [ref]$jg)
        }

        # GoPlay 的确切字节：04 20 00 1a 06
        $q = New-Object byte[] 64
        $q[0] = 0x04; $q[1] = 0x20; $q[2] = 0x00; $q[3] = 0x1A; $q[4] = 0x06
        $rc = [HidIo5]::TryWrite($h, $q, 300)
        Write-Output ("  write rc={0}" -f $rc)
        if ($rc -ne 0) { continue }

        for ($i = 0; $i -lt 20; $i++) {
            $buf = New-Object byte[] 64
            [uint32]$got = 0
            if ([HidIo5]::TryRead($h, $buf, 220, [ref]$got) -ne 0) { continue }
            $n = [Math]::Min(23, $buf.Length - 1)
            $hex = ($buf[0..$n] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            $nonzero = ($buf | Where-Object { $_ -ne 0 }).Count
            Write-Output ("  [{0}] {1}  (nonzero={2})" -f $i, $hex, $nonzero)
        }
    } finally {
        $null = [HidIo5]::CloseHandle($h)
    }
}
