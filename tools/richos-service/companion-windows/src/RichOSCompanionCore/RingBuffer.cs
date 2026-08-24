using System.Collections.Generic;

namespace RichOSCompanionCore
{
    /// <summary>
    /// A minimal thread-safe FIFO of float samples. The two audio callbacks (mic WASAPI client,
    /// system loopback client) run on independent threads; each appends its mono-downmixed frames
    /// here, and the writer thread pulls frame-aligned blocks. Locking is coarse but the payloads are
    /// small (a few ms of audio per callback) so contention is negligible; the callbacks never block
    /// on I/O. The peer of the macOS companion's <c>RingBuffer.swift</c>.
    /// </summary>
    public sealed class RingBuffer
    {
        private readonly List<float> _storage = new List<float>();
        private readonly object _lock = new object();

        /// <summary>Absolute epoch-ms of the most recent append — the starvation clock (§6.2).</summary>
        public long LastAppendMs { get; private set; }

        public void Append(IReadOnlyList<float> samples, long nowMs)
        {
            lock (_lock)
            {
                for (int i = 0; i < samples.Count; i++) _storage.Add(samples[i]);
                LastAppendMs = nowMs;
            }
        }

        public int Count
        {
            get { lock (_lock) { return _storage.Count; } }
        }

        /// <summary>Remove and return the first <paramref name="n"/> samples (or fewer if not available).</summary>
        public float[] Take(int n)
        {
            lock (_lock)
            {
                int k = n < _storage.Count ? n : _storage.Count;
                if (k <= 0) return System.Array.Empty<float>();
                var outBuf = new float[k];
                _storage.CopyTo(0, outBuf, 0, k);
                _storage.RemoveRange(0, k);
                return outBuf;
            }
        }

        public long LastAppend()
        {
            lock (_lock) { return LastAppendMs; }
        }
    }
}
