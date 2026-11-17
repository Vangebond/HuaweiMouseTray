Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class HidIo5
{
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

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateEventW(IntPtr attr, bool manual, bool initial, IntPtr name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr h, uint ms);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetOverlappedResult(IntPtr h, ref OVERLAPPED ov, out uint transferred, bool wait);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteFile(IntPtr h, byte[] buf, int count, out uint written, ref OVERLAPPED ov);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadFile(IntPtr h, byte[] buf, int count, out uint read, ref OVERLAPPED ov);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr data);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_FreePreparsedData(IntPtr data);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern int HidP_GetCaps(IntPtr data, ref HIDP_CAPS caps);

    public static IntPtr Open(string path)
    {
        return CreateFileW(path, 0xC0000000u, 3u, IntPtr.Zero, 3u, 0x40000000u, IntPtr.Zero);
    }

    public static bool IsInvalid(IntPtr h) { return h == IntPtr.Zero || h == new IntPtr(-1); }

    public static HIDP_CAPS GetCaps(IntPtr h)
    {
        var caps = new HIDP_CAPS();
        caps.Reserved = new ushort[17];
        IntPtr prep;
        if (!HidD_GetPreparsedData(h, out prep)) return caps;
        try { HidP_GetCaps(prep, ref caps); } finally { HidD_FreePreparsedData(prep); }
        return caps;
    }

    // returns: 0 = ok, otherwise win32 error
    public static int TryWrite(IntPtr h, byte[] buf, int timeoutMs)
    {
        IntPtr ev = CreateEventW(IntPtr.Zero, true, false, IntPtr.Zero);
        if (ev == IntPtr.Zero) return -1;
        try
        {
            var ov = new OVERLAPPED();
            ov.hEvent = ev;
            uint done;
            if (!WriteFile(h, buf, buf.Length, out done, ref ov))
            {
                int err = Marshal.GetLastWin32Error();
                if (err == 87) return 87;
                if (err != 997) return err;
                if (WaitForSingleObject(ev, (uint)timeoutMs) != 0) return 121;   // timeout
                uint got;
                if (!GetOverlappedResult(h, ref ov, out got, false)) return Marshal.GetLastWin32Error();
            }
            return 0;
        }
        finally { CloseHandle(ev); }
    }

    public static int TryRead(IntPtr h, byte[] buf, int timeoutMs, out uint got)
    {
        got = 0;
        IntPtr ev = CreateEventW(IntPtr.Zero, true, false, IntPtr.Zero);
        if (ev == IntPtr.Zero) return -1;
        try
        {
            var ov = new OVERLAPPED();
            ov.hEvent = ev;
            uint done;
            if (!ReadFile(h, buf, buf.Length, out done, ref ov))
            {
                int err = Marshal.GetLastWin32Error();
                if (err == 87) return 87;
                if (err != 997) return err;
                if (WaitForSingleObject(ev, (uint)timeoutMs) != 0) return 121;
                uint n;
                if (!GetOverlappedResult(h, ref ov, out n, false)) return Marshal.GetLastWin32Error();
                got = n;
                return 0;
            }
            got = done;
            return 0;
        }
        finally { CloseHandle(ev); }
    }
}
'@
