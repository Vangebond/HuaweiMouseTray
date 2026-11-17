#requires -Version 5.1
# Probe: can we read the vendor HID report from the receiver?

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class HidIo2
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
    public static extern bool HidD_GetFeature(IntPtr h, byte[] buffer, int length);

    public static IntPtr Open(string path)
    {
        // GENERIC_READ|GENERIC_WRITE, share R/W, OPEN_EXISTING
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
}
'@

$guid = '{4d1e55b2-f16f-11cf-88cb-001111000030}'
$root = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$guid"
$paths = @(Get-ChildItem $root -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match 'VID_12D1' -and $_.PSChildName -match 'PID_10DB' } |
    ForEach-Object { $_.PSChildName -replace '^##\?#', '\\?\' })

Write-Output "paths: $($paths.Count)"

foreach ($path in $paths) {
    $short = $path.Substring([Math]::Max(0, $path.Length - 34))
    $h = [HidIo2]::Open($path)
    if ([HidIo2]::IsInvalid($h)) {
        Write-Output ("{0}  OPEN FAILED win32={1}" -f $short, [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        continue
    }
    try {
        $attr = New-Object HidIo2+HIDD_ATTRIBUTES
        $attr.Size = [Runtime.InteropServices.Marshal]::SizeOf($attr)
        $null = [HidIo2]::HidD_GetAttributes($h, [ref]$attr)
        $caps = [HidIo2]::GetCaps($h)
        Write-Output ("{0}  vid=0x{1:X4} pid=0x{2:X4} in={3} out={4} feat={5}" -f `
            $short, $attr.VendorID, $attr.ProductID, $caps.InputReportByteLength, $caps.OutputReportByteLength, $caps.FeatureReportByteLength)

        if ($caps.FeatureReportByteLength -gt 1) {
            foreach ($rid in 0x2E, 0x00, 0x01) {
                $buf = New-Object byte[] $caps.FeatureReportByteLength
                $buf[0] = [byte]$rid
                if ([HidIo2]::HidD_GetFeature($h, $buf, $caps.FeatureReportByteLength)) {
                    $n = [Math]::Min(11, $buf.Length - 1)
                    $hex = ($buf[0..$n] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                    Write-Output ("    feat[{0:X2}] {1}" -f $rid, $hex)
                }
            }
        }
    } finally {
        $null = [HidIo2]::CloseHandle($h)
    }
}
