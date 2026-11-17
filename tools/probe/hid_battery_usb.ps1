#requires -Version 5.1
# 向 USB 直连的鼠标（PID_10DA）发查询，并持续读取，收集所有不同的回报。

. "$PSScriptRoot\hid_io.ps1"

$guid = '{4d1e55b2-f16f-11cf-88cb-001111000030}'
$root = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$guid"

$names = @(Get-ChildItem $root -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match 'VID_12D1' -and $_.PSChildName -match 'PID_10DA' } |
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

        $accepted = @()
        for ($rid = 0; $rid -le 255; $rid++) {
            $probe = New-Object byte[] 64
            $probe[0] = [byte]$rid
            if ([HidIo5]::TryWrite($h, $probe, 90) -eq 0) { $accepted += $rid }
        }
        if ($accepted.Count -eq 0) { continue }

        Write-Output ""
        Write-Output ("=== collection #{0}  可使用报告 ID: {1}" -f $index, (($accepted | ForEach-Object { '0x{0:X2}' -f $_ }) -join ','))

        foreach ($rid in $accepted) {
            # 清空积压
            for ($k = 0; $k -lt 4; $k++) {
                $j = New-Object byte[] 64; [uint32]$jg = 0
                $null = [HidIo5]::TryRead($h, $j, 40, [ref]$jg)
            }

            $q = New-Object byte[] 64
            $q[0] = [byte]$rid
            $q[1] = 0x2E; $q[2] = 0x04; $q[3] = 0x20; $q[4] = 0x00; $q[5] = 0x1A; $q[6] = 0x06
            if ([HidIo5]::TryWrite($h, $q, 300) -ne 0) { continue }

            $seen = @{}
            for ($i = 0; $i -lt 30; $i++) {
                $buf = New-Object byte[] 64
                [uint32]$got = 0
                if ([HidIo5]::TryRead($h, $buf, 150, [ref]$got) -ne 0) { continue }
                $n = [Math]::Min(19, $buf.Length - 1)
                $hex = ($buf[0..$n] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                if (-not $seen.ContainsKey($hex)) {
                    $seen[$hex] = $i
                    Write-Output ("  id=0x{0:X2} [{1}] {2}" -f $rid, $i, $hex)
                }
            }
            if ($seen.Count -eq 0) { Write-Output ("  id=0x{0:X2}  无回报" -f $rid) }
        }
    } finally {
        $null = [HidIo5]::CloseHandle($h)
    }
}
