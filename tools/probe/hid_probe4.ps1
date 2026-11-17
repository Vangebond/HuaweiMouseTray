#requires -Version 5.1
# Stage 1: with GoPlay closed, can we open every vendor collection and talk to it?
# Uses overlapped I/O so a read can time out instead of hanging.

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public static class HidIo4
{
    [StructLayout(LayoutKind.Sequential)]
    public struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDP_CAPS
    {
        public ushort Usage; public ushort UsagePage;
        public ushort InputReportByteLength; public ushort OutputReportByteLength; public ushort FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes; public ushort NumberInputButtonCaps; public ushort NumberInputValueCaps;
        public ushort NumberInputDataIndices; public ushort NumberOutputButtonCaps; public ushort NumberOutputValueCaps;
        public ushort NumberOutputDataIndices; public ushort NumberFeatureButtonCaps; public ushort NumberFeatureValueCaps;
        public ushort NumberFeatureDataIndices;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct OVERLAPPED
    {
        public IntPtr Internal; public IntPtr InternalHigh;
        public uint Offset; public uint OffsetHigh;
        public IntPtr hEvent;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateEventW(IntPtr attr, bool manual, bool initial, IntPtr name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ResetEvent(IntPtr h);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr h, uint ms);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetOverlappedResult(IntPtr h, ref OVERLAPPED ov, out uint transferred, bool wait);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteFile(IntPtr h, byte[] buf, int count, out uint written, ref OVERLAPPED ov);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadFile(IntPtr h, byte[] buf, int count, out uint read, ref OVERLAPPED ov);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetAttributes(IntPtr h, ref HIDD_ATTRIBUTES a);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr data);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_FreePreparsedData(IntPtr data);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern int HidP_GetCaps(IntPtr data, ref HIDP_CAPS caps);

    const uint FLAG_OVERLAPPED = 0x40000000;

    public static IntPtr Open(string path)
    {
        return CreateFileW(path, 0xC0000000u, 3u, IntPtr.Zero, 3u, FLAG_OVERLAPPED, IntPtr.Zero);
    }

    public static bool IsInvalid(IntPtr h) { return h == IntPtr.Zero || h == new IntPtr(-1); }

    public static HIDP_CAPS GetCaps(IntPtr handle)
    {
        var caps = new HIDP_CAPS();
        caps.Reserved = new ushort[17];
        IntPtr prep;
        if (!HidD_GetPreparsedData(handle, out prep)) return caps;
        try { HidP_GetCaps(prep, ref caps); } finally { HidD_FreePreparsedData(prep); }
        return caps;
    }

    private static bool OverlappedIo(IntPtr h, byte[] buf, int count, bool isWrite, int timeoutMs, out uint transferred)
    {
        transferred = 0;
        IntPtr ev = CreateEventW(IntPtr.Zero, true, false, IntPtr.Zero);
        if (ev == IntPtr.Zero) return false;
        try
        {
            var ov = new OVERLAPPED();
            ov.hEvent = ev;
            uint done;
            bool ok;
            if (isWrite) ok = WriteFile(h, buf, count, out done, ref ov);
            else ok = ReadFile(h, buf, count, out done, ref ov);

            if (!ok)
            {
                int err = Marshal.GetLastWin32Error();
                if (err != 997) return false;          // 997 = ERROR_IO_PENDING
                if (WaitForSingleObject(ev, (uint)timeoutMs) != 0) return false;   // timed out
            }
            uint got;
            if (!GetOverlappedResult(h, ref ov, out got, false)) return false;
            transferred = got;
            return true;
        }
        finally
        {
            CloseHandle(ev);
        }
    }

    public static bool Send(IntPtr h, byte[] report, out uint sent)
    {
        return OverlappedIo(h, report, report.Length, true, 500, out sent);
    }

    public static bool Receive(IntPtr h, byte[] report, int timeoutMs, out uint received)
    {
        return OverlappedIo(h, report, report.Length, false, timeoutMs, out received);
    }
}
'@

$guid = '{4d1e55b2-f16f-11cf-88cb-001111000030}'
$root = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$guid"
$paths = @(Get-ChildItem $root -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match 'VID_12D1' -and $_.PSChildName -match 'PID_10DB' } |
    ForEach-Object { $_.PSChildName -replace '^##\?#', '\\?\' })

$query = New-Object byte[] 64
$query[0] = 0x2E; $query[1] = 0x04; $query[2] = 0x20; $query[3] = 0x00
$query[4] = 0x1A; $query[5] = 0x06

Write-Output "paths: $($paths.Count)"
$opened = 0

foreach ($path in $paths) {
    $short = $path.Substring([Math]::Max(0, $path.Length - 26))
    $h = [HidIo4]::Open($path)
    if ([HidIo4]::IsInvalid($h)) {
        Write-Output ("OPEN FAILED win32={0}  {1}" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error(), $short)
        continue
    }
    $opened++
    try {
        $caps = [HidIo4]::GetCaps($h)
        $line = "{0} in={1} out={2} feat={3}" -f $short, $caps.InputReportByteLength, $caps.OutputReportByteLength, $caps.FeatureReportByteLength
        Write-Output $line

        if ($caps.InputReportByteLength -ne 64 -or $caps.OutputReportByteLength -ne 64) { continue }

        [uint32]$sent = 0
        if (-not [HidIo4]::Send($h, $query, [ref]$sent)) {
            Write-Output ("    send FAILED win32={0}" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error())
            continue
        }
        Write-Output "    send ok ($sent bytes)"

        for ($i = 0; $i -lt 6; $i++) {
            $buf = New-Object byte[] 64
            [uint32]$got = 0
            if ([HidIo4]::Receive($h, $buf, 400, [ref]$got)) {
                $n = [Math]::Min(11, $got - 1)
                $hex = ($buf[0..$n] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                Write-Output "    recv ${got} bytes: $hex"
                if ($buf[0] -eq 0x2E -and $buf[4] -eq 0x1A) { break }
            } else {
                Write-Output "    recv timeout"
                break
            }
        }
    } finally {
        $null = [HidIo4]::CloseHandle($h)
    }
}
Write-Output "opened: $opened / $($paths.Count)"
