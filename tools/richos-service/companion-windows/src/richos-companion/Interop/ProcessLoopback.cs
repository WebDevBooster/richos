using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace RichOSCompanion.Interop
{
    /// <summary>
    /// The process-loopback activation path (architecture §5.3, "preferred where available", Windows 10 build
    /// 20348+): scope the RIGHT channel to a target app's process TREE (Zoom/Teams + children),
    /// excluding music/notifications. Uses <c>ActivateAudioInterfaceAsync</c> with
    /// <c>AUDIOCLIENT_ACTIVATION_PARAMS</c> (activation type PROCESS_LOOPBACK,
    /// <c>PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE</c>). The caller falls back to plain
    /// system loopback if activation fails.
    ///
    /// <b>Documented trap (§5.3):</b> on the process-loopback client, <c>GetMixFormat()</c> /
    /// <c>IsFormatSupported()</c> return <c>E_NOTIMPL</c> — the format MUST be supplied manually. The
    /// capture engine never calls GetMixFormat on this path; it builds a canonical
    /// <see cref="WAVEFORMATEX"/> itself.
    /// </summary>
    internal static class ProcessLoopback
    {
        /// <summary>The magic device path for process-loopback activation (audioclientactivationparams.h).</summary>
        public const string VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK = "VAD\\Process_Loopback";

        // AUDIOCLIENT_ACTIVATION_TYPE
        public const int AUDIOCLIENT_ACTIVATION_TYPE_DEFAULT = 0;
        public const int AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK = 1;

        // PROCESS_LOOPBACK_MODE
        public const int PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE = 0;
        public const int PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE = 1;

        public const ushort VT_BLOB = 0x41;

        [DllImport("Mmdevapi.dll", ExactSpelling = true, PreserveSig = true)]
        public static extern int ActivateAudioInterfaceAsync(
            [MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
            in Guid riid,
            IntPtr activationParams, // PROPVARIANT* (VT_BLOB -> AUDIOCLIENT_ACTIVATION_PARAMS)
            [MarshalAs(UnmanagedType.Interface)] IActivateAudioInterfaceCompletionHandler completionHandler,
            [MarshalAs(UnmanagedType.Interface)] out IActivateAudioInterfaceAsyncOperation activationOperation);

        /// <summary>AUDIOCLIENT_ACTIVATION_PARAMS with the single-member process-loopback union flattened.</summary>
        [StructLayout(LayoutKind.Sequential)]
        public struct AUDIOCLIENT_ACTIVATION_PARAMS
        {
            public int ActivationType;
            public uint TargetProcessId;
            public int ProcessLoopbackMode;
        }

        /// <summary>PROPVARIANT holding a VT_BLOB (64-bit field offsets).</summary>
        [StructLayout(LayoutKind.Explicit)]
        public struct PROPVARIANT_BLOB
        {
            [FieldOffset(0)] public ushort vt;
            [FieldOffset(8)] public uint cbSize;    // BLOB.cbSize
            [FieldOffset(16)] public IntPtr pBlobData; // BLOB.pBlobData
        }
    }

    [ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IActivateAudioInterfaceAsyncOperation
    {
        [PreserveSig] int GetActivateResult(out int activateResult,
            [MarshalAs(UnmanagedType.IUnknown)] out object activatedInterface);
    }

    [ComImport, Guid("41D949AB-9862-444A-80F6-C261334DA5EB")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IActivateAudioInterfaceCompletionHandler
    {
        [PreserveSig] int ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation);
    }

    // IAgileObject is a marker interface (no methods beyond IUnknown). The completion handler must be
    // agile per the MS Application-loopback sample, so we also expose it.
    [ComImport, Guid("94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAgileObject
    {
    }

    /// <summary>
    /// Managed completion handler: <c>ActivateAudioInterfaceAsync</c> calls back on a system thread;
    /// we just signal an event so the (synchronous) caller can retrieve the result. Implements
    /// <see cref="IAgileObject"/> so COM treats it as free-threaded (required by the API).
    /// </summary>
    internal sealed class ActivationCompletionHandler : IActivateAudioInterfaceCompletionHandler, IAgileObject
    {
        private readonly ManualResetEventSlim _done = new ManualResetEventSlim(false);
        public IActivateAudioInterfaceAsyncOperation? Operation { get; private set; }

        public int ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation)
        {
            Operation = activateOperation;
            _done.Set();
            return Hr.S_OK;
        }

        public bool Wait(int timeoutMs) => _done.Wait(timeoutMs);
    }
}
