using System;
using System.IO;
using System.Text;

namespace RichOSCompanionCore
{
    /// <summary>
    /// A minimal 16-bit PCM WAV reader — just enough to drive the headless <c>ingest</c> proof path,
    /// where a pre-made sample is pushed through the SAME SessionWriter/ChannelMixer/WavWriter code the
    /// live capture uses. This proves the contract + P1 handoff end-to-end WITHOUT the mic permission
    /// grant. The peer of the macOS companion's <c>WavReader.swift</c>.
    /// </summary>
    public static class WavReader
    {
        public sealed class Pcm
        {
            public int SampleRate;
            public int Channels;
            /// <summary>Deinterleaved mono float channels: <c>[0]</c> = LEFT, <c>[1]</c> = RIGHT, ...</summary>
            public float[][] ChannelsData = Array.Empty<float[]>();
        }

        public static Pcm Read(string path)
        {
            byte[] data = File.ReadAllBytes(path);
            int U32(int o) => data[o] | (data[o + 1] << 8) | (data[o + 2] << 16) | (data[o + 3] << 24);
            int U16(int o) => data[o] | (data[o + 1] << 8);
            string Ascii(int o, int n) => Encoding.ASCII.GetString(data, o, n);

            if (data.Length <= 44 || Ascii(0, 4) != "RIFF" || Ascii(8, 4) != "WAVE")
                throw new InvalidDataException("not a RIFF/WAVE file");

            // Walk chunks to locate fmt + data (WAVs are not always header-at-44).
            int o2 = 12;
            int sampleRate = 0, channels = 0, bits = 0;
            int dataOffset = -1, dataLen = 0;
            while (o2 + 8 <= data.Length)
            {
                string id = Ascii(o2, 4);
                int sz = U32(o2 + 4);
                int body = o2 + 8;
                if (id == "fmt ")
                {
                    channels = U16(body + 2);
                    sampleRate = U32(body + 4);
                    bits = U16(body + 14);
                }
                else if (id == "data")
                {
                    dataOffset = body;
                    dataLen = Math.Min(sz, data.Length - body);
                }
                o2 = body + sz + (sz % 2); // chunks are word-aligned
            }

            if (bits != 16 || dataOffset < 0 || channels <= 0)
                throw new InvalidDataException("only 16-bit PCM WAV supported");

            int frames = dataLen / (channels * 2);
            var outBuf = new float[channels][];
            for (int c = 0; c < channels; c++) outBuf[c] = new float[frames];
            for (int f = 0; f < frames; f++)
            {
                for (int c = 0; c < channels; c++)
                {
                    int idx = dataOffset + (f * channels + c) * 2;
                    short s = unchecked((short)(data[idx] | (data[idx + 1] << 8)));
                    outBuf[c][f] = s / 32767.0f;
                }
            }
            return new Pcm { SampleRate = sampleRate, Channels = channels, ChannelsData = outBuf };
        }
    }
}
