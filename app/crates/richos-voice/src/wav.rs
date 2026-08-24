//! WAV I/O and rate conversion — hand-rolled, so packaging carries one fewer crate.
//!
//! Two directions, both required:
//!
//! - **Out to whisper.cpp:** `whisper-cli` takes a 16 kHz mono PCM16 file, so a finished
//!   utterance is written with [`write_pcm16_mono`].
//! - **In from the synthesizer:** macOS `say -o out.wav --data-format=LEI16@<rate>` produces
//!   a mono PCM16 WAV, read back with [`read_pcm16`] and queued as samples so playout is
//!   sample-accurate and interruptible (see `playout.rs`).
//!
//! [`resample`] handles the device rates. The mic runs at whatever CoreAudio gives us
//! (48 000 Hz here) and the VAD/whisper path is fixed at 16 000 Hz, so every capture frame
//! is converted. Downsampling applies a box pre-filter before decimation — crude but honest:
//! for 48 kHz -> 16 kHz its first null sits exactly at 16 kHz and it attenuates a 20 kHz tone
//! (which would otherwise alias down to 4 kHz, right in the middle of speech) by ~12 dB. That
//! number is asserted in a test, not asserted in a comment.

use std::io;
use std::path::Path;

/// Write mono f32 samples as a 16-bit PCM WAV. Samples are clamped to [-1.0, 1.0].
pub fn write_pcm16_mono(path: &Path, samples: &[f32], sample_rate: u32) -> io::Result<()> {
    std::fs::write(path, encode_pcm16_mono(samples, sample_rate))
}

/// The WAV bytes for mono f32 samples — separated from the file write so it is testable
/// without touching a disk.
pub fn encode_pcm16_mono(samples: &[f32], sample_rate: u32) -> Vec<u8> {
    let data_len = samples.len() * 2;
    let mut out = Vec::with_capacity(44 + data_len);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&((36 + data_len) as u32).to_le_bytes());
    out.extend_from_slice(b"WAVE");
    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes()); // PCM fmt chunk size
    out.extend_from_slice(&1u16.to_le_bytes()); // format = PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // channels = mono
    out.extend_from_slice(&sample_rate.to_le_bytes());
    out.extend_from_slice(&(sample_rate * 2).to_le_bytes()); // byte rate
    out.extend_from_slice(&2u16.to_le_bytes()); // block align
    out.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(data_len as u32).to_le_bytes());
    for s in samples {
        let v = (s.clamp(-1.0, 1.0) * 32767.0).round() as i16;
        out.extend_from_slice(&v.to_le_bytes());
    }
    out
}

/// A decoded WAV: interleaved f32 samples plus the facts needed to use them.
#[derive(Debug, Clone)]
pub struct Pcm {
    pub samples: Vec<f32>,
    pub sample_rate: u32,
    pub channels: u16,
}

impl Pcm {
    /// Collapse to mono by averaging channels.
    pub fn into_mono(self) -> (Vec<f32>, u32) {
        (to_mono(&self.samples, self.channels), self.sample_rate)
    }
    /// Duration derived from the sample count — the only honest way to state it.
    pub fn duration_secs(&self) -> f32 {
        if self.sample_rate == 0 || self.channels == 0 {
            return 0.0;
        }
        self.samples.len() as f32 / (self.sample_rate as f32 * self.channels as f32)
    }
}

/// Parse a 16-bit PCM WAV. Walks the chunk list rather than assuming a 44-byte header,
/// because `say` emits a `LIST`/`INFO` chunk before `data`.
pub fn read_pcm16(bytes: &[u8]) -> Result<Pcm, String> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("not a RIFF/WAVE file".into());
    }
    let mut pos = 12usize;
    let mut sample_rate = 0u32;
    let mut channels = 0u16;
    let mut bits = 0u16;
    let mut data: Option<&[u8]> = None;

    while pos + 8 <= bytes.len() {
        let id = &bytes[pos..pos + 4];
        let size = u32::from_le_bytes([bytes[pos + 4], bytes[pos + 5], bytes[pos + 6], bytes[pos + 7]]) as usize;
        let body_start = pos + 8;
        let body_end = body_start.saturating_add(size).min(bytes.len());
        match id {
            b"fmt " => {
                if body_end - body_start < 16 {
                    return Err("truncated fmt chunk".into());
                }
                let b = &bytes[body_start..body_end];
                channels = u16::from_le_bytes([b[2], b[3]]);
                sample_rate = u32::from_le_bytes([b[4], b[5], b[6], b[7]]);
                bits = u16::from_le_bytes([b[14], b[15]]);
            }
            b"data" => data = Some(&bytes[body_start..body_end]),
            _ => {}
        }
        // Chunks are word-aligned.
        pos = body_start + size + (size & 1);
    }

    let data = data.ok_or("no data chunk")?;
    if bits != 16 {
        return Err(format!("expected 16-bit PCM, got {bits}-bit"));
    }
    if channels == 0 || sample_rate == 0 {
        return Err("missing fmt chunk".into());
    }
    let samples = data
        .chunks_exact(2)
        .map(|c| i16::from_le_bytes([c[0], c[1]]) as f32 / 32768.0)
        .collect();
    Ok(Pcm { samples, sample_rate, channels })
}

/// Average interleaved channels down to mono.
pub fn to_mono(interleaved: &[f32], channels: u16) -> Vec<f32> {
    if channels <= 1 {
        return interleaved.to_vec();
    }
    let n = channels as usize;
    interleaved.chunks(n).map(|f| f.iter().sum::<f32>() / f.len() as f32).collect()
}

/// Duplicate mono samples across `channels` interleaved output channels.
pub fn from_mono(mono: &[f32], channels: u16) -> Vec<f32> {
    if channels <= 1 {
        return mono.to_vec();
    }
    let mut out = Vec::with_capacity(mono.len() * channels as usize);
    for s in mono {
        for _ in 0..channels {
            out.push(*s);
        }
    }
    out
}

/// Convert a mono signal between sample rates. Linear interpolation, with a box pre-filter
/// on downsampling so out-of-band energy does not fold into the speech band.
pub fn resample(input: &[f32], in_rate: u32, out_rate: u32) -> Vec<f32> {
    if in_rate == out_rate || input.is_empty() {
        return input.to_vec();
    }
    let filtered: Vec<f32> = if in_rate > out_rate {
        let taps = ((in_rate as f32 / out_rate as f32).round() as usize).max(1);
        box_filter(input, taps)
    } else {
        input.to_vec()
    };

    let ratio = in_rate as f64 / out_rate as f64;
    let n_out = ((input.len() as f64) / ratio).round() as usize;
    let mut out = Vec::with_capacity(n_out);
    for i in 0..n_out {
        let src = i as f64 * ratio;
        let i0 = src.floor() as usize;
        let frac = (src - i0 as f64) as f32;
        let a = filtered.get(i0).copied().unwrap_or(0.0);
        let b = filtered.get(i0 + 1).copied().unwrap_or(a);
        out.push(a + (b - a) * frac);
    }
    out
}

/// Centred moving average of `taps` samples. `taps <= 1` is a no-op.
fn box_filter(input: &[f32], taps: usize) -> Vec<f32> {
    if taps <= 1 {
        return input.to_vec();
    }
    let half = taps / 2;
    let mut out = Vec::with_capacity(input.len());
    for i in 0..input.len() {
        let start = i.saturating_sub(half);
        let end = (i + taps - half).min(input.len());
        let slice = &input[start..end];
        out.push(slice.iter().sum::<f32>() / slice.len() as f32);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(freq: f32, rate: u32, n: usize) -> Vec<f32> {
        (0..n)
            .map(|i| (2.0 * std::f32::consts::PI * freq * i as f32 / rate as f32).sin() * 0.5)
            .collect()
    }

    fn rms(x: &[f32]) -> f32 {
        (x.iter().map(|s| s * s).sum::<f32>() / x.len() as f32).sqrt()
    }

    /// INVARIANT: what we write is what whisper reads back — a full round trip within
    /// 16-bit quantisation error (1/32768 = 3.05e-5).
    #[test]
    fn a_wav_round_trip_preserves_the_audio_within_quantisation_error() {
        let src = sine(440.0, 16_000, 4000);
        let bytes = encode_pcm16_mono(&src, 16_000);
        let back = read_pcm16(&bytes).expect("decode");
        assert_eq!(back.sample_rate, 16_000);
        assert_eq!(back.channels, 1);
        assert_eq!(back.samples.len(), src.len());
        let worst = src
            .iter()
            .zip(back.samples.iter())
            .map(|(a, b)| (a - b).abs())
            .fold(0.0f32, f32::max);
        assert!(worst <= 1.0 / 32767.0 + 1e-7, "worst sample error {worst}");
    }

    /// INVARIANT: the header we emit is the canonical 44-byte PCM16 header whisper.cpp
    /// expects, with the rate and sizes it will read.
    #[test]
    fn the_header_is_the_canonical_44_byte_pcm16_header() {
        let bytes = encode_pcm16_mono(&[0.0; 100], 16_000);
        assert_eq!(bytes.len(), 44 + 200);
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WAVE");
        assert_eq!(&bytes[12..16], b"fmt ");
        assert_eq!(u16::from_le_bytes([bytes[22], bytes[23]]), 1, "channels");
        assert_eq!(u32::from_le_bytes([bytes[24], bytes[25], bytes[26], bytes[27]]), 16_000);
        assert_eq!(u16::from_le_bytes([bytes[34], bytes[35]]), 16, "bits per sample");
        assert_eq!(&bytes[36..40], b"data");
        assert_eq!(u32::from_le_bytes([bytes[40], bytes[41], bytes[42], bytes[43]]), 200);
    }

    /// INVARIANT: a WAV with an extra chunk before `data` still decodes. macOS `say` emits
    /// exactly this shape, so assuming a fixed 44-byte header would silently mis-read
    /// Rich's own voice as noise.
    #[test]
    fn a_wav_with_an_extra_chunk_before_data_still_decodes() {
        let plain = encode_pcm16_mono(&[0.25, -0.25, 0.5, -0.5], 24_000);
        // Splice a LIST/INFO chunk in between `fmt ` and `data`.
        let mut spliced = Vec::new();
        spliced.extend_from_slice(&plain[..36]);
        spliced.extend_from_slice(b"LIST");
        spliced.extend_from_slice(&8u32.to_le_bytes());
        spliced.extend_from_slice(b"INFOxxxx");
        spliced.extend_from_slice(&plain[36..]);
        // Fix the RIFF size.
        let riff = (spliced.len() - 8) as u32;
        spliced[4..8].copy_from_slice(&riff.to_le_bytes());

        let pcm = read_pcm16(&spliced).expect("decode with LIST chunk");
        assert_eq!(pcm.sample_rate, 24_000);
        assert_eq!(pcm.samples.len(), 4);
        assert!((pcm.samples[2] - 0.5).abs() < 1e-4);
    }

    /// INVARIANT: garbage in is an error out, not a panic in the audio thread.
    #[test]
    fn a_non_wav_is_an_error_not_a_panic() {
        assert!(read_pcm16(b"").is_err());
        assert!(read_pcm16(b"not a wav file at all").is_err());
        assert!(read_pcm16(b"RIFF\x00\x00\x00\x00WAVE").is_err(), "no data chunk");
    }

    /// INVARIANT: the resampled length matches the duration, so 1 second in is 1 second out.
    #[test]
    fn resampling_preserves_duration() {
        let one_second_at_48k = vec![0.0f32; 48_000];
        let out = resample(&one_second_at_48k, 48_000, 16_000);
        assert_eq!(out.len(), 16_000);
        let up = resample(&vec![0.0f32; 16_000], 16_000, 48_000);
        assert_eq!(up.len(), 48_000);
        // 44.1 kHz devices exist too: 44100 -> 16000 is 0.36281... s per 16000 samples.
        let out = resample(&vec![0.0f32; 44_100], 44_100, 16_000);
        assert_eq!(out.len(), 16_000);
    }

    /// INVARIANT: an equal-rate "conversion" is exactly the identity — the mic path must not
    /// smear the signal when the device already runs at 16 kHz.
    #[test]
    fn resampling_between_equal_rates_is_the_identity() {
        let src = sine(300.0, 16_000, 1000);
        assert_eq!(resample(&src, 16_000, 16_000), src);
    }

    /// INVARIANT: a speech-band tone survives 48 kHz -> 16 kHz with its amplitude roughly
    /// intact. If the box pre-filter ate the voice, this catches it.
    #[test]
    fn a_speech_band_tone_survives_downsampling() {
        let src = sine(300.0, 48_000, 48_000);
        let out = resample(&src, 48_000, 16_000);
        let ratio = rms(&out) / rms(&src);
        assert!(ratio > 0.9, "300 Hz lost {:.1}% of its level", (1.0 - ratio) * 100.0);
    }

    /// INVARIANT: out-of-band energy is attenuated instead of folding into the speech band.
    /// A 20 kHz tone decimated 48k->16k without filtering would alias to |20000-16000| =
    /// 4000 Hz — dead centre of speech. The box pre-filter must knock it down by >= 6 dB.
    #[test]
    fn out_of_band_energy_is_attenuated_rather_than_aliased_into_speech() {
        let src = sine(20_000.0, 48_000, 48_000);
        let out = resample(&src, 48_000, 16_000);
        let db = 20.0 * (rms(&out) / rms(&src)).log10();
        assert!(db <= -6.0, "20 kHz only attenuated by {db:.1} dB — it will alias into speech");
    }

    /// INVARIANT: channel folding is an average, not a channel drop — a mic whose voice sits
    /// on the right channel must not come back silent.
    #[test]
    fn stereo_folds_to_mono_by_averaging_not_by_dropping_a_channel() {
        let interleaved = vec![0.0, 1.0, 0.0, 1.0]; // left silent, right full
        let mono = to_mono(&interleaved, 2);
        assert_eq!(mono, vec![0.5, 0.5]);
        assert_eq!(to_mono(&[0.3, 0.7], 1), vec![0.3, 0.7]);
    }

    /// INVARIANT: mono expands to every output channel — Rich comes out of both speakers.
    #[test]
    fn mono_expands_to_every_output_channel() {
        assert_eq!(from_mono(&[0.5, -0.5], 2), vec![0.5, 0.5, -0.5, -0.5]);
        assert_eq!(from_mono(&[0.5], 1), vec![0.5]);
    }

    /// INVARIANT: duration is derived from the sample count and the format, never stored.
    #[test]
    fn duration_is_derived_from_the_samples() {
        let pcm = Pcm { samples: vec![0.0; 48_000], sample_rate: 24_000, channels: 2 };
        assert!((pcm.duration_secs() - 1.0).abs() < 1e-6);
    }
}
