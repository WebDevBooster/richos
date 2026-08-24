using System;
using System.Runtime.InteropServices;

namespace RichOSCompanion.Interop
{
    /// <summary>
    /// The WASAPI COM interop the Windows capture engine needs (architecture §5.3). Hand-written P/Invoke /
    /// <c>[ComImport]</c> declarations so the project has ZERO NuGet dependency and CI is fully
    /// self-contained — the vtable method ORDER below is load-bearing (each interface lists every
    /// method in its real order, matching <c>mmdeviceapi.h</c> / <c>audioclient.h</c>), and every
    /// method uses <c>[PreserveSig]</c> returning the raw HRESULT so the capture engine can inspect
    /// traps like the process-loopback <c>GetMixFormat</c> = <c>E_NOTIMPL</c> (§5.3) rather than have
    /// them thrown as opaque exceptions.
    /// </summary>
    internal static class Hr
    {
        public const int S_OK = 0;
        public const int E_NOTIMPL = unchecked((int)0x80004001);
        public const int AUDCLNT_S_NO_SINGLE_PROCESS = unchecked((int)0x08890021);
        public static bool Ok(int hr) => hr >= 0;
    }

    internal static class Wasapi
    {
        // CLSIDs / IIDs (mmdeviceapi.h, audioclient.h).
        public static readonly Guid CLSID_MMDeviceEnumerator = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
        public static readonly Guid IID_IMMDeviceEnumerator = new Guid("A95664D2-9614-4F35-A746-DE8DB63617E6");
        public static readonly Guid IID_IAudioClient = new Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
        public static readonly Guid IID_IAudioCaptureClient = new Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317");

        // EDataFlow / ERole (mmdeviceapi.h).
        public const int eRender = 0;
        public const int eCapture = 1;
        public const int eConsole = 0;

        // AUDCLNT_SHAREMODE.
        public const int AUDCLNT_SHAREMODE_SHARED = 0;

        // Stream flags (audioclient.h).
        public const uint AUDCLNT_STREAMFLAGS_LOOPBACK = 0x00020000;
        public const uint AUDCLNT_STREAMFLAGS_EVENTCALLBACK = 0x00040000;
        public const uint AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM = 0x80000000;
        public const uint AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY = 0x08000000;

        // AUDCLNT_BUFFERFLAGS (audioclient.h) — on captured packets.
        public const uint AUDCLNT_BUFFERFLAGS_SILENT = 0x2;

        // WAVE format tags.
        public const ushort WAVE_FORMAT_PCM = 1;
        public const ushort WAVE_FORMAT_IEEE_FLOAT = 3;
        public const ushort WAVE_FORMAT_EXTENSIBLE = 0xFFFE;

        // CoCreateInstance context.
        public const uint CLSCTX_ALL = 23;

        [DllImport("ole32.dll")]
        public static extern int CoCreateInstance(
            in Guid rclsid, IntPtr pUnkOuter, uint dwClsContext, in Guid riid,
            [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
    }

    /// <summary>WAVEFORMATEX (mmreg.h). Sequential, 1-byte packed to match the C layout exactly.</summary>
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    internal struct WAVEFORMATEX
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;

        /// <summary>Build a canonical 32-bit IEEE-float WAVEFORMATEX (what WASAPI shared/loopback delivers).</summary>
        public static WAVEFORMATEX Float32(int sampleRate, int channels)
        {
            ushort ch = (ushort)channels;
            ushort bits = 32;
            ushort blockAlign = (ushort)(ch * (bits / 8));
            return new WAVEFORMATEX
            {
                wFormatTag = Wasapi.WAVE_FORMAT_IEEE_FLOAT,
                nChannels = ch,
                nSamplesPerSec = (uint)sampleRate,
                nAvgBytesPerSec = (uint)(sampleRate * blockAlign),
                nBlockAlign = blockAlign,
                wBitsPerSample = bits,
                cbSize = 0,
            };
        }
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role,
            [MarshalAs(UnmanagedType.Interface)] out IMMDevice endpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id,
            [MarshalAs(UnmanagedType.Interface)] out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        [PreserveSig] int Activate(in Guid iid, uint clsCtx, IntPtr activationParams,
            [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(uint access, out IntPtr props);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out uint state);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioClient
    {
        [PreserveSig] int Initialize(int shareMode, uint streamFlags, long hnsBufferDuration,
            long hnsPeriodicity, IntPtr pFormat, IntPtr audioSessionGuid);
        [PreserveSig] int GetBufferSize(out uint numBufferFrames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint numPaddingFrames);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr pFormat, out IntPtr closestMatch);
        [PreserveSig] int GetMixFormat(out IntPtr deviceFormat);
        [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr eventHandle);
        [PreserveSig] int GetService(in Guid iid,
            [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    }

    [ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioCaptureClient
    {
        [PreserveSig] int GetBuffer(out IntPtr data, out uint numFramesToRead, out uint flags,
            out ulong devicePosition, out ulong qpcPosition);
        [PreserveSig] int ReleaseBuffer(uint numFramesRead);
        [PreserveSig] int GetNextPacketSize(out uint numFramesInNextPacket);
    }
}
