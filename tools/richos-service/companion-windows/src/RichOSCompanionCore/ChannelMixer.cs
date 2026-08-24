using System;
using System.Collections.Generic;

namespace RichOSCompanionCore
{
    /// <summary>
    /// The frozen audio invariant (P1 README / architecture §3.1), made mechanical and testable:
    ///
    ///   <b>Exactly two channels, LEFT = me (microphone), RIGHT = others (system loopback). Never a
    ///   pre-mix.</b>
    ///
    /// This gives free "me vs them" separation with no diarization model and lets the pipeline
    /// transcribe each channel independently. <see cref="ChannelMixer"/> is the ONE place that
    /// assignment is encoded — a swapped L/R here would silently mis-attribute every speaker in every
    /// transcript — so it is unit-tested to death, exactly like the macOS companion's
    /// <c>ChannelMixer.swift</c>.
    /// </summary>
    public static class ChannelMixer
    {
        /// <summary>Clamp a float sample in [-1, 1] to signed 16-bit PCM (round half away from zero).</summary>
        public static short FloatToInt16(float x)
        {
            float clamped = Math.Max(-1.0f, Math.Min(1.0f, x));
            // 32767 (not 32768) so +1.0 maps to short.MaxValue without overflow.
            double scaled = Math.Round((double)clamped * 32767.0, MidpointRounding.AwayFromZero);
            return (short)scaled;
        }

        /// <summary>
        /// Downmix an interleaved multi-channel float frame block to mono by averaging channels.
        /// WASAPI loopback/mic often deliver stereo or N-channel; the contract's per-side channel is
        /// mono, so we average (not just take ch0) to avoid dropping a hard-panned talker.
        /// </summary>
        public static float[] DownmixToMono(float[] interleaved, int channelCount)
        {
            if (channelCount <= 1) return interleaved;
            int frames = interleaved.Length / channelCount;
            var outBuf = new float[frames];
            for (int f = 0; f < frames; f++)
            {
                float sum = 0;
                for (int c = 0; c < channelCount; c++) sum += interleaved[f * channelCount + c];
                outBuf[f] = sum / channelCount;
            }
            return outBuf;
        }

        /// <summary>
        /// Interleave two equal-length mono float streams into 2-channel Int16 PCM: LEFT=mic,
        /// RIGHT=system. The two inputs MUST be frame-aligned (same sample rate, same count) — the
        /// caller (<see cref="SessionWriter"/>) guarantees this by pulling <c>min(available)</c> from
        /// both ring buffers each pump.
        /// </summary>
        public static short[] InterleaveToInt16(float[] mic, float[] system)
        {
            if (mic.Length != system.Length)
                throw new ArgumentException("mic/system must be frame-aligned");
            var outBuf = new short[mic.Length * 2];
            int j = 0;
            for (int i = 0; i < mic.Length; i++)
            {
                outBuf[j++] = FloatToInt16(mic[i]);     // LEFT  = me
                outBuf[j++] = FloatToInt16(system[i]);  // RIGHT = others
            }
            return outBuf;
        }

        /// <summary>Little-endian byte serialization of interleaved Int16 PCM (WAV sample data).</summary>
        public static byte[] Int16LeBytes(short[] samples)
        {
            var bytes = new byte[samples.Length * 2];
            int j = 0;
            foreach (var s in samples)
            {
                ushort u = unchecked((ushort)s);
                bytes[j++] = (byte)(u & 0xff);
                bytes[j++] = (byte)((u >> 8) & 0xff);
            }
            return bytes;
        }

        /// <summary>Peak absolute amplitude of a float block, for the health per-channel level.</summary>
        public static double Peak(IReadOnlyList<float> block)
        {
            float m = 0;
            for (int i = 0; i < block.Count; i++) { float a = Math.Abs(block[i]); if (a > m) m = a; }
            return m;
        }

        /// <summary>RMS of a float block, for the health per-channel mean level.</summary>
        public static double Rms(IReadOnlyList<float> block)
        {
            if (block.Count == 0) return 0;
            double sum = 0;
            for (int i = 0; i < block.Count; i++) sum += (double)block[i] * block[i];
            return Math.Sqrt(sum / block.Count);
        }
    }
}
