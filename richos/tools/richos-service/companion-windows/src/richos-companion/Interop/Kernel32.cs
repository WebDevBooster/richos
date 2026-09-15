using System;
using System.Runtime.InteropServices;

namespace RichOSCompanion.Interop
{
    /// <summary>Just the event + COM-apartment primitives the event-driven process-loopback path needs.</summary>
    internal static class Kernel32
    {
        public const uint WAIT_OBJECT_0 = 0;
        public const uint WAIT_TIMEOUT = 0x102;
        public const uint INFINITE = 0xFFFFFFFF;

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr CreateEventW(IntPtr lpEventAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool bManualReset,
            [MarshalAs(UnmanagedType.Bool)] bool bInitialState,
            [MarshalAs(UnmanagedType.LPWStr)] string? lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr hObject);
    }

    internal static class Ole32
    {
        public const uint COINIT_MULTITHREADED = 0x0;

        [DllImport("ole32.dll")]
        public static extern int CoInitializeEx(IntPtr pvReserved, uint dwCoInit);

        [DllImport("ole32.dll")]
        public static extern void CoUninitialize();

        [DllImport("ole32.dll")]
        public static extern void CoTaskMemFree(IntPtr pv);
    }
}
