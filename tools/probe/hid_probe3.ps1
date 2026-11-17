#requires -Version 5.1
# Try Huawei vendor collections: send the 0x2e query, then pull input reports.

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class HidIo3
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
    public struct OVERLAPPED { public IntPtr Internal; public IntPtr InternalHigh; public uint Offset; public uint OffsetHigh; public IntPtr hEvent; }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr h);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetAttributes(IntPtr h, ref HIDD_ATTRIBUTES a);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr data);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_FreePreparsedData(IntPtr data);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern int HidP_GetCaps(IntPtr data, ref HIDP_CAPS caps);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetInputReport(IntPtr h, byte[] buffer, int length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteFile(IntPtr h, byte[] buffer, int count, out int written, IntPtr overlapped);

    public static IntPtr Open(string path)
    {
        return CreateFileW(path, 0xC0000000u, 3u, IntPtr.Zero, 3u, 0u, IntPtr.Zero);
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

    public static bool Write(IntPtr h, byte[] buffer)
    {
        int written;
        return WriteFile(h, buffer, buffer.Length, out written, IntPtr.Zero);
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

foreach ($path in $paths) {
    $short = $path.Substring([Math]::Max(0, $path.Length - 30))
    $h = [HidIo3]::Open($path)
    if ([HidIo3]::IsInvalid($h)) { continue }
    try {
        $caps = [HidIo3]::GetCaps($h)
        if ($caps.InputReportByteLength -ne 64) { continue }

        Write-Output ""
        Write-Output "=== $short  (in=$($caps.InputReportByteLength) out=$($caps.OutputReportByteLength))"

        # 1) 先直接 GET input report
        $buf = New-Object byte[] 64
        $buf[0] = 0x2E
        if ([HidIo3]::HidD_GetInputReport($h, $buf, 64)) {
            $hex = ($buf[0..9] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            Write-Output "    GET_INPUT[2e] ok: $hex"
        } else {
            Write-Output "    GET_INPUT[2e] failed win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }

        # 2) 写入查询，再 GET 一次
        if ([HidIo3]::Write($h, $query)) {
            Start-Sleep -Milliseconds 120
            $buf2 = New-Object byte[] 64
            $buf2[0] = 0x2E
            if ([HidIo3]::HidD_GetInputReport($h, $buf2, 64)) {
                $hex = ($buf2[0..9] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                Write-Output "    after write, GET_INPUT ok: $hex"
            } else {
                Write-Output "    after write, GET_INPUT failed win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
        } else {
            Write-Output "    write failed win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
    } finally {
        $null = [HidIo3]::CloseHandle($h)
    }
}
