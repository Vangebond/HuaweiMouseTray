#requires -Version 5.1
# Try: send the query on the short (13-byte) channel, listen on the 64-byte channels.

. "$PSScriptRoot\hid_io.ps1"

$guid = '{4d1e55b2-f16f-11cf-88cb-001111000030}'
$root = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$guid"
$names = @(Get-ChildItem $root -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match 'VID_12D1' -and $_.PSChildName -match 'PID_10DB' } |
    ForEach-Object { $_.PSChildName })

# 打开全部能开的集合
$handles = @()
foreach ($name in $names) {
    $path = $name -replace '^##\?#', '\\?\'
    $h = [HidIo5]::Open($path)
    if ([HidIo5]::IsInvalid($h)) { continue }
    $caps = [HidIo5]::GetCaps($h)
    $handles += [pscustomobject]@{
        Handle = $h
        In     = [int]$caps.InputReportByteLength
        Out    = [int]$caps.OutputReportByteLength
        Name   = $name.Substring([Math]::Max(0, $name.Length - 22))
    }
}
"openable: $($handles.Count)"
$handles | ForEach-Object { "  in=$($_.In) out=$($_.Out)  $($_.Name)" }

# 找出 13 字节输出通道的 ID
foreach ($t in $handles) {
    if ($t.Out -lt 2 -or $t.Out -eq 64) { continue }
    $accepted = @()
    for ($rid = 0; $rid -le 255; $rid++) {
        $p = New-Object byte[] $t.Out
        $p[0] = [byte]$rid
        if ([HidIo5]::TryWrite($t.Handle, $p, 100) -eq 0) { $accepted += $rid }
    }
    "short channel out=$($t.Out) accepted ids: $(($accepted | ForEach-Object { '0x{0:X2}' -f $_ }) -join ',')"

    foreach ($rid in $accepted) {
        $q = New-Object byte[] $t.Out
        $q[0] = [byte]$rid
        $payload = @(0x2E, 0x04, 0x20, 0x00, 0x1A, 0x06)
        for ($i = 0; $i -lt $payload.Count -and ($i + 1) -lt $q.Length; $i++) { $q[$i + 1] = [byte]$payload[$i] }

        $rc = [HidIo5]::TryWrite($t.Handle, $q, 300)
        "  send on short(id 0x{0:X2}) -> rc={1}" -f $rid, $rc
        if ($rc -ne 0) { continue }

        foreach ($r in $handles) {
            if ($r.In -lt 2) { continue }
            for ($i = 0; $i -lt 3; $i++) {
                $buf = New-Object byte[] $r.In
                [uint32]$got = 0
                if ([HidIo5]::TryRead($r.Handle, $buf, 250, [ref]$got) -ne 0) { continue }
                $n = [Math]::Min(15, $buf.Length - 1)
                $hex = ($buf[0..$n] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                "    recv(in=$($r.In)) ${got}B: $hex"
            }
        }
    }
}

foreach ($t in $handles) { $null = [HidIo5]::CloseHandle($t.Handle) }
