#requires -Version 5.1
# Probe the mouse itself when it is connected by USB (VID_12D1 PID_10DA).
# 1) list collections, 2) brute force accepted output report IDs,
# 3) send the 0x2e battery query and read replies.

. "$PSScriptRoot\hid_io.ps1"

$guid = '{4d1e55b2-f16f-11cf-88cb-001111000030}'
$root = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$guid"

$names = @(Get-ChildItem $root -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match 'VID_12D1' -and $_.PSChildName -match 'PID_10DA' } |
    ForEach-Object { $_.PSChildName })

Write-Output "paths for PID_10DA: $($names.Count)"

$index = 0
foreach ($name in $names) {
    $index++
    $path = $name -replace '^##\?#', '\\?\'
    $h = [HidIo5]::Open($path)
    if ([HidIo5]::IsInvalid($h)) {
        Write-Output ("#{0} OPEN FAILED win32={1}" -f $index, [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        continue
    }
    try {
        $caps = [HidIo5]::GetCaps($h)
        Write-Output ("#{0} in={1} out={2} feat={3}" -f $index, $caps.InputReportByteLength, $caps.OutputReportByteLength, $caps.FeatureReportByteLength)
        if ($caps.OutputReportByteLength -lt 2) { continue }

        $len = [int]$caps.OutputReportByteLength
        $accepted = @()
        for ($rid = 0; $rid -le 255; $rid++) {
            $probe = New-Object byte[] $len
            $probe[0] = [byte]$rid
            if ([HidIo5]::TryWrite($h, $probe, 110) -eq 0) { $accepted += $rid }
        }
        if ($accepted.Count -eq 0) { continue }
        Write-Output ("    accepted OUT ids: {0}" -f (($accepted | ForEach-Object { '0x{0:X2}' -f $_ }) -join ','))

        foreach ($rid in $accepted) {
            $q = New-Object byte[] $len
            $q[0] = [byte]$rid
            $payload = @(0x2E, 0x04, 0x20, 0x00, 0x1A, 0x06)
            for ($i = 0; $i -lt $payload.Count -and ($i + 1) -lt $q.Length; $i++) { $q[$i + 1] = [byte]$payload[$i] }

            if ([HidIo5]::TryWrite($h, $q, 300) -ne 0) { continue }

            for ($i = 0; $i -lt 8; $i++) {
                if ($caps.InputReportByteLength -lt 2) { break }
                $buf = New-Object byte[] ([int]$caps.InputReportByteLength)
                [uint32]$got = 0
                if ([HidIo5]::TryRead($h, $buf, 350, [ref]$got) -ne 0) { break }
                $n = [Math]::Min(15, $buf.Length - 1)
                $hex = ($buf[0..$n] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                Write-Output ("    id=0x{0:X2} recv {1}B: {2}" -f $rid, $got, $hex)
            }
        }
    } finally {
        $null = [HidIo5]::CloseHandle($h)
    }
}
