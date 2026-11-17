#requires -Version 5.1
# Probe: can we read the vendor HID report from the receiver?
# Enumerates HID interface paths from the registry (no SetupAPI marshalling),
# opens each one, and tries HidD_GetFeature on report IDs 0x00..0x2e.

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class HidIo
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
    public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr h);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetAttributes(IntPtr h, ref HIDD_ATTRIBUTES a);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr data);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_FreePreparsedData(IntPtr data);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern int HidP_GetCaps(IntPtr data, ref HIDP_CAPS caps);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetFeature(IntPtr h, byte[] buffer, int length);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetProductString(IntPtr h, byte[] buffer, int length);

    public static HIDP_CAPS GetCaps(IntPtr handle)
    {
        IntPtr prep;
        var caps = new HIDP_CAPS();
        if (!HidD_GetPreparsedData(handle, out prep)) return caps;
        try { HidP_GetCaps(prep, ref caps); } finally { HidD_FreePreparsedData(prep); }
        return caps;
    }
}
'@

$guid = '{4d1e55b2-f16f-11cf-88cb-001111000030}'
$root = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$guid"
if (-not (Test-Path $root)) { Write-Output 'no HID device-class key'; return }

$paths = @(Get-ChildItem $root -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match 'VID_12D1' -and $_.PSChildName -match 'PID_10DB' } |
    ForEach-Object {
        $name = $_.PSChildName
        $p = $name -replace '^##\?\?', '\\?\' -replace '#', '\'
        $p
    })

Write-Output "found $($paths.Count) HID interface paths for VID_12D1/PID_10DB"
foreach ($p in $paths) { Write-Output "  $p" }

$GENERIC_READ = 0x80000000
$GENERIC_WRITE = 0x40000000
$SHARE = 0x3
$OPEN_EXISTING = 3
$FILE_FLAG_OVERLAPPED = 0x40000000

foreach ($path in $paths) {
    Write-Output ""
    Write-Output "--- $($path.Substring([Math]::Max(0, $path.Length - 60)))"
    $h = [HidIo]::CreateFileW($path, $GENERIC_READ -bor $GENERIC_WRITE, $SHARE, [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)
    if ($h -eq [IntPtr]::new(-1)) {
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Output "    open FAILED (win32 $err)"
        continue
    }
    try {
        $attr = New-Object HidIo+HIDD_ATTRIBUTES
        $attr.Size = [Runtime.InteropServices.Marshal]::SizeOf($attr)
        $null = [HidIo]::HidD_GetAttributes($h, [ref]$attr)
        $caps = [HidIo]::GetCaps($h)
        Write-Output ("    vid=0x{0:X4} pid=0x{1:X4}  in={2} out={3} feature={4} page=0x{5:X2} usage=0x{6:X2}" -f `
            $attr.VendorID, $attr.ProductID, $caps.InputReportByteLength, $caps.OutputReportByteLength, `
            $caps.FeatureReportByteLength, $caps.UsagePage, $caps.Usage)

        if ($caps.FeatureReportByteLength -le 1) { Write-Output '    no feature reports'; continue }

        foreach ($rid in 0x2e, 0x00, 0x01, 0x02, 0x03, 0x20) {
            $buf = New-Object byte[] $caps.FeatureReportByteLength
            $buf[0] = [byte]$rid
            if ([HidIo]::HidD_GetFeature($h, $buf, $caps.FeatureReportByteLength)) {
                $hex = ($buf[0..([Math]::Min(11, $buf.Length - 1))] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                $nonzero = ($buf | Where-Object { $_ -ne 0 }).Count
                Write-Output "    feature[$('{0:X2}' -f $rid)] = $hex  (nonzero=$nonzero)"
            } else {
                $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Write-Output "    feature[$('{0:X2}' -f $rid)] failed (win32 $err)"
            }
        }
    } finally {
        $null = [HidIo]::CloseHandle($h)
    }
}
