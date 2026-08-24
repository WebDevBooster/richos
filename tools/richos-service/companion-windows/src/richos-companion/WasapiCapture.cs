using System;
using System.Runtime.InteropServices;
using System.Threading;
using RichOSCompanion.Interop;
using RichOSCompanionCore;

namespace RichOSCompanion
{
    /// <summary>
    /// The irreducibly-native Windows capture engine (architecture §5.3): a <b>WASAPI loopback</b> on all
    /// system output (Granola parity, §10-Q2 "all-output first") — refined to <b>process loopback</b>
    /// scoped to a target app's process tree when a target PID is supplied and the OS supports it
    /// (build 20348+) — plus the <b>default microphone</b>, mixed into the frozen 2-channel contract
    /// (LEFT=mic, RIGHT=system) via <see cref="SessionWriter"/>.
    ///
    /// - System audio: <c>IAudioClient.Initialize</c> with <c>AUDCLNT_STREAMFLAGS_LOOPBACK</c> on the
    ///   default render endpoint (baseline, every Windows 10/11), OR
    ///   <c>ActivateAudioInterfaceAsync</c> process loopback (preferred, scoped). Audio keeps playing
    ///   to the user — loopback reads a copy of the render mix.
    /// - Microphone: WASAPI shared-mode capture on the default input, auto-converted to the system
    ///   sample rate so the two async sources stay frame-aligned in <see cref="SessionWriter"/>.
    ///
    /// PERMISSION MODEL (§5.3): Windows does NOT gate loopback behind a consent dialog; the microphone
    /// requires the Windows microphone privacy permission. If the mic can't start (denied/absent) the
    /// engine keeps capturing SYSTEM audio and silence-fills LEFT, with a loud health alarm — a
    /// deliberate improvement over a both-or-nothing start (never lose the far side of the call).
    /// </summary>
    internal sealed class WasapiCapture
    {
        private readonly SessionWriter _writer;
        private readonly uint? _targetProcessId;
        private readonly string? _targetProcessName;

        private int _sampleRate = 48_000;
        private volatile bool _running;
        private Thread? _sysThread;
        private Thread? _micThread;
        private Thread? _micSilenceThread;

        private IntPtr _sysEvent = IntPtr.Zero;
        private IntPtr _micEvent = IntPtr.Zero;

        // Cheap level metering accumulated in the capture threads; snapshot+reset once per health tick.
        private readonly object _levelLock = new object();
        private double _micPeak, _micSumSq; private long _micN;
        private double _sysPeak, _sysSumSq; private long _sysN;

        public volatile bool TapRunning;  // system loopback capture client delivering
        public volatile bool MicRunning;

        public string CaptureMethod { get; private set; } = SessionContract.MethodSystemLoopback;
        public string CaptureTarget { get; private set; } = "system";
        public int SampleRate => _sampleRate;

        public WasapiCapture(SessionWriter writer, uint? targetProcessId, string? targetProcessName)
        {
            _writer = writer;
            _targetProcessId = targetProcessId;
            _targetProcessName = targetProcessName;
        }

        /// <summary>(micPeak, micRms, sysPeak, sysRms) since the last snapshot; resets accumulators.</summary>
        public (double, double, double, double) SnapshotLevels()
        {
            lock (_levelLock)
            {
                double mRms = _micN > 0 ? Math.Sqrt(_micSumSq / _micN) : 0;
                double sRms = _sysN > 0 ? Math.Sqrt(_sysSumSq / _sysN) : 0;
                var outv = (_micPeak, mRms, _sysPeak, sRms);
                _micPeak = 0; _micSumSq = 0; _micN = 0; _sysPeak = 0; _sysSumSq = 0; _sysN = 0;
                return outv;
            }
        }

        private void Meter(float[] block, bool mic)
        {
            double peak = 0, sumSq = 0;
            foreach (var x in block) { double a = Math.Abs(x); if (a > peak) peak = a; sumSq += (double)x * x; }
            lock (_levelLock)
            {
                if (mic) { if (peak > _micPeak) _micPeak = peak; _micSumSq += sumSq; _micN += block.Length; }
                else { if (peak > _sysPeak) _sysPeak = peak; _sysSumSq += sumSq; _sysN += block.Length; }
            }
        }

        // MARK: - Bring-up

        /// <summary>Bring up system loopback (or process loopback) + mic. Throws if system audio can't start.</summary>
        public void Start()
        {
            var (sysClient, sysCapture, sysFormat, sysEvent) = StartSystem();
            _sysEvent = sysEvent;
            _sampleRate = (int)sysFormat.nSamplesPerSec;

            IAudioClient? micClient = null;
            IAudioCaptureClient? micCapture = null;
            WAVEFORMATEX micFormat = default;
            try
            {
                (micClient, micCapture, micFormat, _micEvent) = StartMic(_sampleRate);
            }
            catch
            {
                micClient = null; // mic denied/absent — capture system-only + silence-fill LEFT (alarm).
            }

            _running = true;
            _sysThread = new Thread(() => CaptureLoop(sysClient, sysCapture, sysFormat, _sysEvent, isMic: false))
            { IsBackground = true, Name = "richos-sys-capture" };
            _sysThread.Start();

            if (micClient != null && micCapture != null)
            {
                IAudioClient mc = micClient; IAudioCaptureClient mcap = micCapture; var mf = micFormat;
                _micThread = new Thread(() => CaptureLoop(mc, mcap, mf, _micEvent, isMic: true))
                { IsBackground = true, Name = "richos-mic-capture" };
                _micThread.Start();
            }
            else
            {
                // Silence feeder keeps LEFT flowing so the pump never blocks on an absent mic; MicRunning
                // stays false, which the writer turns into a loud red health alarm (§6.4).
                MicRunning = false;
                _micSilenceThread = new Thread(MicSilenceLoop) { IsBackground = true, Name = "richos-mic-silence" };
                _micSilenceThread.Start();
            }
        }

        private void MicSilenceLoop()
        {
            int block = Math.Max(1, _sampleRate / 100); // ~10 ms of silence per tick
            var zeros = new float[block];
            while (_running)
            {
                _writer.PushMic(zeros);
                Thread.Sleep(10);
            }
        }

        public void Stop()
        {
            _running = false;
            _sysThread?.Join(1000);
            _micThread?.Join(1000);
            _micSilenceThread?.Join(1000);
            if (_sysEvent != IntPtr.Zero) { Kernel32.CloseHandle(_sysEvent); _sysEvent = IntPtr.Zero; }
            if (_micEvent != IntPtr.Zero) { Kernel32.CloseHandle(_micEvent); _micEvent = IntPtr.Zero; }
            TapRunning = false;
            MicRunning = false;
        }

        // MARK: - System capture (process loopback preferred, system loopback baseline)

        private (IAudioClient, IAudioCaptureClient, WAVEFORMATEX, IntPtr) StartSystem()
        {
            if (_targetProcessId.HasValue)
            {
                try
                {
                    var r = StartProcessLoopback(_targetProcessId.Value);
                    CaptureMethod = SessionContract.MethodProcessLoopback;
                    CaptureTarget = "process:" + (_targetProcessName ?? _targetProcessId.Value.ToString());
                    return r;
                }
                catch (Exception ex)
                {
                    Notifier.Info($"process loopback unavailable ({ex.Message}); falling back to system loopback");
                }
            }
            var s = StartSystemLoopback();
            CaptureMethod = SessionContract.MethodSystemLoopback;
            CaptureTarget = "system";
            return s;
        }

        private static IMMDeviceEnumerator CreateEnumerator()
        {
            int hr = Wasapi.CoCreateInstance(
                in Wasapi.CLSID_MMDeviceEnumerator, IntPtr.Zero, Wasapi.CLSCTX_ALL,
                in Wasapi.IID_IMMDeviceEnumerator, out object o);
            if (!Hr.Ok(hr) || o == null) throw new InvalidOperationException($"CoCreateInstance(MMDeviceEnumerator) failed 0x{hr:X8}");
            return (IMMDeviceEnumerator)o;
        }

        // The single target format for EVERY source (architecture §3.1: sample rate >= 16 kHz; the pipeline
        // ffmpeg-normalizes anyway). Forcing 48 kHz float32 stereo via AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
        // means WASAPI inserts a resampler so both the mic AND the loopback deliver at THIS exact rate —
        // so the two async sources are frame-aligned and the WAV header is always correct, with the rate
        // known before the WAV is opened (mirrors the macOS companion's fixed-48 kHz assumption, done
        // robustly instead of assuming the device rate).
        private const int TargetRate = 48_000;

        private (IAudioClient, IAudioCaptureClient, WAVEFORMATEX, IntPtr) StartSystemLoopback()
        {
            var enumr = CreateEnumerator();
            int hr = enumr.GetDefaultAudioEndpoint(Wasapi.eRender, Wasapi.eConsole, out IMMDevice dev);
            if (!Hr.Ok(hr)) throw new InvalidOperationException($"GetDefaultAudioEndpoint(render) failed 0x{hr:X8}");

            hr = dev.Activate(in Wasapi.IID_IAudioClient, Wasapi.CLSCTX_ALL, IntPtr.Zero, out object clientObj);
            if (!Hr.Ok(hr)) throw new InvalidOperationException($"Activate(IAudioClient) failed 0x{hr:X8}");
            var client = (IAudioClient)clientObj;

            // Request canonical float32 @ 48 kHz + AUTOCONVERT — no GetMixFormat needed; WASAPI resamples
            // the render mix to our uniform target format.
            var fmt = WAVEFORMATEX.Float32(TargetRate, 2);
            uint flags = Wasapi.AUDCLNT_STREAMFLAGS_LOOPBACK | Wasapi.AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
                         | Wasapi.AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
            var capture = InitAndGetCapture(client, fmt, flags, IntPtr.Zero);
            return (client, capture, fmt, IntPtr.Zero); // polling (no event) for loopback
        }

        private (IAudioClient, IAudioCaptureClient, WAVEFORMATEX, IntPtr) StartProcessLoopback(uint pid)
        {
            // Process loopback: format supplied MANUALLY (GetMixFormat is E_NOTIMPL here — the §5.3 trap).
            var fmt = WAVEFORMATEX.Float32(48_000, 2);

            var actParams = new ProcessLoopback.AUDIOCLIENT_ACTIVATION_PARAMS
            {
                ActivationType = ProcessLoopback.AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK,
                TargetProcessId = pid,
                ProcessLoopbackMode = ProcessLoopback.PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE,
            };
            int paramsSize = Marshal.SizeOf<ProcessLoopback.AUDIOCLIENT_ACTIVATION_PARAMS>();
            IntPtr paramsPtr = Marshal.AllocHGlobal(paramsSize);
            IntPtr propPtr = IntPtr.Zero;
            try
            {
                Marshal.StructureToPtr(actParams, paramsPtr, false);
                var prop = new ProcessLoopback.PROPVARIANT_BLOB
                {
                    vt = ProcessLoopback.VT_BLOB,
                    cbSize = (uint)paramsSize,
                    pBlobData = paramsPtr,
                };
                propPtr = Marshal.AllocHGlobal(Marshal.SizeOf<ProcessLoopback.PROPVARIANT_BLOB>());
                Marshal.StructureToPtr(prop, propPtr, false);

                var handler = new ActivationCompletionHandler();
                int hr = ProcessLoopback.ActivateAudioInterfaceAsync(
                    ProcessLoopback.VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
                    in Wasapi.IID_IAudioClient, propPtr, handler, out var op);
                if (!Hr.Ok(hr)) throw new InvalidOperationException($"ActivateAudioInterfaceAsync failed 0x{hr:X8}");
                if (!handler.Wait(5000) || handler.Operation == null)
                    throw new InvalidOperationException("process-loopback activation timed out");

                int ahr = handler.Operation.GetActivateResult(out int actHr, out object clientObj);
                if (!Hr.Ok(ahr) || !Hr.Ok(actHr) || clientObj == null)
                    throw new InvalidOperationException($"GetActivateResult failed 0x{actHr:X8}");
                var client = (IAudioClient)clientObj;

                IntPtr evt = Kernel32.CreateEventW(IntPtr.Zero, false, false, null);
                uint flags = Wasapi.AUDCLNT_STREAMFLAGS_LOOPBACK | Wasapi.AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
                var capture = InitAndGetCapture(client, fmt, flags, evt);
                return (client, capture, fmt, evt);
            }
            finally
            {
                if (propPtr != IntPtr.Zero) Marshal.FreeHGlobal(propPtr);
                Marshal.FreeHGlobal(paramsPtr);
            }
        }

        private (IAudioClient, IAudioCaptureClient, WAVEFORMATEX, IntPtr) StartMic(int targetRate)
        {
            var enumr = CreateEnumerator();
            int hr = enumr.GetDefaultAudioEndpoint(Wasapi.eCapture, Wasapi.eConsole, out IMMDevice dev);
            if (!Hr.Ok(hr)) throw new InvalidOperationException($"GetDefaultAudioEndpoint(capture) failed 0x{hr:X8}");

            hr = dev.Activate(in Wasapi.IID_IAudioClient, Wasapi.CLSCTX_ALL, IntPtr.Zero, out object clientObj);
            if (!Hr.Ok(hr)) throw new InvalidOperationException($"Activate(mic IAudioClient) failed 0x{hr:X8}");
            var client = (IAudioClient)clientObj;

            // Request float32 @ the SYSTEM rate + AUTOCONVERT so WASAPI resamples the device to match —
            // the two sources stay frame-aligned exactly like the macOS companion resamples the mic.
            var fmt = WAVEFORMATEX.Float32(targetRate, 1);
            uint flags = Wasapi.AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | Wasapi.AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
            var capture = InitAndGetCapture(client, fmt, flags, IntPtr.Zero);
            return (client, capture, fmt, IntPtr.Zero);
        }

        private static IAudioCaptureClient InitAndGetCapture(IAudioClient client, WAVEFORMATEX fmt, uint flags, IntPtr evt)
        {
            IntPtr fmtPtr = Marshal.AllocHGlobal(Marshal.SizeOf<WAVEFORMATEX>());
            try
            {
                Marshal.StructureToPtr(fmt, fmtPtr, false);
                const long bufferHns = 2_000_000; // 200 ms
                int hr = client.Initialize(Wasapi.AUDCLNT_SHAREMODE_SHARED, flags, bufferHns, 0, fmtPtr, IntPtr.Zero);
                if (!Hr.Ok(hr)) throw new InvalidOperationException($"IAudioClient.Initialize failed 0x{hr:X8}");
            }
            finally
            {
                Marshal.FreeHGlobal(fmtPtr);
            }
            if (evt != IntPtr.Zero)
            {
                int hr = client.SetEventHandle(evt);
                if (!Hr.Ok(hr)) throw new InvalidOperationException($"SetEventHandle failed 0x{hr:X8}");
            }
            int hg = client.GetService(in Wasapi.IID_IAudioCaptureClient, out object capObj);
            if (!Hr.Ok(hg) || capObj == null) throw new InvalidOperationException($"GetService(IAudioCaptureClient) failed 0x{hg:X8}");
            return (IAudioCaptureClient)capObj;
        }

        // MARK: - Capture loop

        private void CaptureLoop(IAudioClient client, IAudioCaptureClient capture, WAVEFORMATEX fmt, IntPtr evt, bool isMic)
        {
            // Each capture thread lives in its own MTA COM apartment.
            Ole32.CoInitializeEx(IntPtr.Zero, Ole32.COINIT_MULTITHREADED);
            int channels = fmt.nChannels > 0 ? fmt.nChannels : 2;
            try
            {
                int hr = client.Start();
                if (!Hr.Ok(hr)) { Notifier.Alarm($"{(isMic ? "mic" : "system")} client Start failed 0x{hr:X8}"); return; }
                if (isMic) MicRunning = true; else TapRunning = true;

                while (_running)
                {
                    if (evt != IntPtr.Zero) Kernel32.WaitForSingleObject(evt, 200);
                    else Thread.Sleep(10);

                    while (_running)
                    {
                        hr = capture.GetNextPacketSize(out uint packetFrames);
                        if (!Hr.Ok(hr) || packetFrames == 0) break;

                        hr = capture.GetBuffer(out IntPtr data, out uint frames, out uint flags, out _, out _);
                        if (!Hr.Ok(hr) || frames == 0) { if (Hr.Ok(hr)) capture.ReleaseBuffer(frames); break; }

                        float[] mono;
                        if ((flags & Wasapi.AUDCLNT_BUFFERFLAGS_SILENT) != 0 || data == IntPtr.Zero)
                        {
                            mono = new float[frames]; // digital silence packet
                        }
                        else
                        {
                            int total = (int)frames * channels;
                            var interleaved = new float[total];
                            Marshal.Copy(data, interleaved, 0, total);
                            mono = ChannelMixer.DownmixToMono(interleaved, channels);
                        }
                        capture.ReleaseBuffer(frames);

                        Meter(mono, isMic);
                        if (isMic) _writer.PushMic(mono); else _writer.PushSystem(mono);
                    }
                }
            }
            catch (Exception ex)
            {
                Notifier.Alarm($"{(isMic ? "mic" : "system")} capture loop error: {ex.Message}");
            }
            finally
            {
                try { client.Stop(); } catch { /* best-effort */ }
                if (isMic) MicRunning = false; else TapRunning = false;
                Ole32.CoUninitialize();
            }
        }
    }
}
