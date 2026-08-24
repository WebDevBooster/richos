using System;
using System.IO;

namespace RichOSCompanionCore
{
    /// <summary>
    /// An appendable 2-channel 16-bit PCM WAV writer with crash-recoverable framing.
    ///
    /// Why WAV single-part (architecture §3.1 explicitly sanctions "Opus-in-Ogg OR 16 kHz WAV"), identical to
    /// the macOS companion's decision: the frozen pipeline's multi-part concat (<c>normalize.js</c>)
    /// copies parts into a <c>.webm</c> container with <c>-c copy</c>, which PCM cannot enter — so
    /// multiple WAV parts would break the pipeline, while a SINGLE self-contained WAV is used directly
    /// (the <c>parts.length === 1</c> path in <c>normalize.js</c>). Windows WASAPI has no built-in Opus
    /// encoder either, so WAV is the correct zero-dependency choice. Recoverability (§6.5 "continuous
    /// write + periodic fsync, worst case one chunk") is met by rewriting the RIFF/data size headers
    /// on every flush + <c>FileStream.Flush(true)</c> (flush-to-disk): a crash loses at most the
    /// samples since the last flush, and the on-disk header always describes a valid, decodable prefix.
    /// </summary>
    public sealed class WavWriter : IDisposable
    {
        private readonly FileStream _stream;
        public string Path { get; }
        public int SampleRate { get; }
        public int Channels { get; }
        public int BitsPerSample { get; }
        public int DataBytes { get; private set; }

        private const int HeaderSize = 44;

        public WavWriter(string path, int sampleRate, int channels = 2, int bitsPerSample = 16)
        {
            Path = path;
            SampleRate = sampleRate;
            Channels = channels;
            BitsPerSample = bitsPerSample;
            _stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
            _stream.Write(Header(0, sampleRate, channels, bitsPerSample), 0, HeaderSize);
        }

        /// <summary>Append interleaved Int16 PCM sample bytes (little-endian).</summary>
        public void Append(byte[] bytes)
        {
            _stream.Write(bytes, 0, bytes.Length);
            DataBytes += bytes.Length;
        }

        /// <summary>
        /// Rewrite the two size fields to describe everything written so far, then flush to disk.
        /// Called on the flush cadence so the on-disk file is always a valid WAV describing a decodable
        /// prefix (§6.5).
        /// </summary>
        public void Flush()
        {
            long end = _stream.Position;
            _stream.Seek(4, SeekOrigin.Begin);
            _stream.Write(U32Le(HeaderSize - 8 + DataBytes), 0, 4);
            _stream.Seek(40, SeekOrigin.Begin);
            _stream.Write(U32Le(DataBytes), 0, 4);
            _stream.Seek(end, SeekOrigin.Begin);
            // Durable to disk — the <= one-flush-window crash guarantee (§6.5).
            _stream.Flush(flushToDisk: true);
        }

        public void Close()
        {
            Flush();
            _stream.Dispose();
        }

        public void Dispose() => _stream.Dispose();

        public int TotalBytesOnDisk => HeaderSize + DataBytes;

        // MARK: - Header

        internal static byte[] Header(int dataBytes, int sampleRate, int channels, int bitsPerSample)
        {
            int byteRate = sampleRate * channels * (bitsPerSample / 8);
            int blockAlign = channels * (bitsPerSample / 8);
            var d = new byte[HeaderSize];
            int o = 0;
            void PutAscii(string s) { foreach (var c in s) d[o++] = (byte)c; }
            void PutU32(int v) { var b = U32Le(v); d[o++] = b[0]; d[o++] = b[1]; d[o++] = b[2]; d[o++] = b[3]; }
            void PutU16(int v) { var b = U16Le(v); d[o++] = b[0]; d[o++] = b[1]; }

            PutAscii("RIFF");
            PutU32(HeaderSize - 8 + dataBytes); // file size - 8
            PutAscii("WAVE");
            PutAscii("fmt ");
            PutU32(16);            // PCM fmt chunk size
            PutU16(1);             // audio format = PCM
            PutU16(channels);
            PutU32(sampleRate);
            PutU32(byteRate);
            PutU16(blockAlign);
            PutU16(bitsPerSample);
            PutAscii("data");
            PutU32(dataBytes);
            return d;
        }

        internal static byte[] U32Le(int v)
        {
            uint u = unchecked((uint)v);
            return new[] { (byte)(u & 0xff), (byte)((u >> 8) & 0xff), (byte)((u >> 16) & 0xff), (byte)((u >> 24) & 0xff) };
        }

        internal static byte[] U16Le(int v)
        {
            ushort u = unchecked((ushort)v);
            return new[] { (byte)(u & 0xff), (byte)((u >> 8) & 0xff) };
        }
    }
}
