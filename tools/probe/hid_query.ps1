#requires -Version 5.1
# Send the 0x2e battery query with the collection's own report ID, then read replies.

. "$PSScriptRoot\hid_io.ps1"

$guid = '{4d1e55b2-f16f-11cf-88cb-001111000030}'
$root = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$guid"
$names = @(Get-ChildItem $root -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match 'VID_12D1' -and $_.PSChildName -match 'PID_10DB' } |
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

        # 找出这个集合接受的输出报告 ID
        $accepted = @()
        for ($rid = 0; $rid -le 255; $rid++) {
            $probe = New-Object byte[] 64
            $probe[0] = [byte]$rid
            if ([HidIo5]::TryWrite($h, $probe, 120) -eq 0) { $accepted += $rid }
        }
        if ($accepted.Count -eq 0) { continue }

        foreach ($rid in $accepted) {
            Write-Output ""
            Write-Output ("=== path#{0} reportId=0x{1:X2}" -f $index, $rid)

            # 清掉可能积压的输入
            for ($k = 0; $k -lt 3; $k++) {
                $junk = New-Object byte[] 64
                [uint32]$g = 0
                $null = [HidIo5]::TryRead($h, $junk, 60, [ref]$g)
            }

            # 发送查询：[reportId][2e 04 20 00 1a 06][0 ...]
            $q = New-Object byte[] 64
            $q[0] = [byte]$rid
            $q[1] = 0x2E; $q[2] = 0x04; $q[3] = 0x20; $q[4] = 0x00; $q[5] = 0x1A; $q[6] = 0x06
            $rc = [HidIo5]::TryWrite($h, $q, 300)
            if ($rc -ne 0) { Write-Output ("    send failed rc={0}" -f $rc); continue }

            $seen = 0
            for ($i = 0; $i -lt 8; $i++) {
                $buf = New-Object byte[] 64
                [uint32]$got = 0
                $rr = [HidIo5]::TryRead($h, $buf, 350, [ref]$got)
                if ($rr -ne 0) { Write-Output ("    read rc={0} (no more data)" -f $rr); break }
                $n = [Math]::Min(15, $buf.Length - 1)
                $hex = ($buf[0..$n] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                Write-Output ("    in[{0}] {1}" -f $got, $hex)
                $seen++
            }
            if ($seen -eq 0) { Write-Output '    (no input reports)' }
        }
    } finally {
        $null = [HidIo5]::CloseHandle($h)
    }
}
