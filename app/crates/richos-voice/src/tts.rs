//! Text to speech — ONE bundled Rich voice, behind a trait so it can be replaced.
//!
//! CEO decision, 2026-08-24: *"ONE bundled Rich voice for v1. Voice choice/cloning is a later
//! feature — do not build selection UI."* So there is no picker, no settings row, and no
//! per-thread voice. There is one voice, one env override for an operator, and a trait seam.
//!
//! ## Why macOS `say` for v1, and what it costs
//!
//! `say` is AVSpeechSynthesizer on the command line: already present on every Mac, offline,
//! free, zero bytes to bundle, and — the part that matters for a conversation — fast.
//! Measured on this M4: a 4.358 s sentence synthesises to 48 kHz PCM in **0.324 s**, a
//! real-time factor of **0.074**, i.e. ~13.5x faster than it plays. That headroom is exactly
//! what makes gapless sentence pipelining work: sentence N+1 is always ready before sentence
//! N finishes.
//!
//! What it costs: the compact system voices are recognisably synthetic next to a modern
//! neural voice. Two upgrade paths, neither of which touches this pipeline:
//! 1. **Free, no code:** the CEO installs an Enhanced/Premium variant in System Settings ->
//!    Accessibility -> Spoken Content. [`pick_voice`] already prefers those variants, so the
//!    same "Daniel" gets materially better the moment one exists. **None is installed on this
//!    machine today** — `say -v '?'` lists 177 voices and zero of them are Enhanced or Premium.
//! 2. **Bundled neural voice:** implement [`SpeechSynth`] over Piper/Kokoro and hand the
//!    packaging engineer a model file. Nothing above this trait changes.
//!
//! The voice IDENTITY is "Daniel" — en_GB, calm and measured, which is the chief-of-staff
//! register the design lead's direction asks for. `RICHOS_TTS_VOICE` overrides it for an operator; it
//! is deliberately NOT surfaced in the UI.

use crate::wav;
use std::path::Path;
use std::process::Command;
use std::time::Instant;

/// The bundled Rich voice, in preference order. The first three are the SAME voice at
/// increasing quality — if the CEO ever installs an Enhanced/Premium variant, Rich simply
/// sounds better with no code change. The tail is a fallback for a stripped system.
pub const VOICE_PREFERENCE: &[&str] =
    &["Daniel (Premium)", "Daniel (Enhanced)", "Daniel", "Reed (English (US))", "Samantha"];

/// Words per minute. `say`'s default is faster than a chief of staff should sound.
pub const DEFAULT_RATE_WPM: u32 = 180;

#[derive(Debug)]
pub enum TtsError {
    Io(String),
    Failed { status: String, stderr: String },
    Decode(String),
}

impl TtsError {
    /// NAMES THE PARTY. Speech synthesis failing is not something the CEO can fix from
    /// inside the app, and the old line did not say so — it read as a fault he might be
    /// expected to chase. Naming the owner is what a NEEDS-SOMEONE-ELSE state owes its
    /// reader. ("text" is load-bearing here: this file's own
    /// `a_synthesis_failure_degrades_to_text_without_leaking_machinery` asserts the CEO is
    /// told the conversation continues.)
    pub fn ceo_message(&self) -> String {
        "My voice isn't working on this machine — whoever set RichOS up would need to look at \
         that. I'll keep answering in text."
            .into()
    }
}

impl std::fmt::Display for TtsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TtsError::Io(s) => write!(f, "tts io: {s}"),
            TtsError::Failed { status, stderr } => write!(f, "say failed ({status}): {stderr}"),
            TtsError::Decode(s) => write!(f, "tts decode: {s}"),
        }
    }
}

/// One synthesised sentence: mono f32 at the rate that was asked for, plus the measurement.
#[derive(Debug, Clone)]
pub struct Speech {
    pub samples: Vec<f32>,
    pub sample_rate: u32,
    /// Wall-clock synthesis time — measured, so the real-time factor in the brief is real.
    pub synth_ms: u64,
}

impl Speech {
    pub fn duration_secs(&self) -> f32 {
        if self.sample_rate == 0 {
            return 0.0;
        }
        self.samples.len() as f32 / self.sample_rate as f32
    }
    /// synthesis time / audio duration. Below 1.0 means synthesis outruns playback, which is
    /// the precondition for gapless pipelining.
    pub fn realtime_factor(&self) -> f32 {
        let d = self.duration_secs();
        if d <= 0.0 {
            return 0.0;
        }
        (self.synth_ms as f32 / 1000.0) / d
    }
}

/// The replaceable synthesizer. A bundled neural voice implements this and nothing else in
/// the crate changes.
pub trait SpeechSynth: Send + Sync {
    /// Synthesise one sentence as mono f32 at `target_rate` (the output device's rate, so
    /// playout never resamples Rich's voice).
    fn synthesize(&self, text: &str, target_rate: u32, scratch_dir: &Path) -> Result<Speech, TtsError>;
    /// Honest identity for logs and the brief — never shown to the CEO.
    fn voice_label(&self) -> String;
}

/// macOS `say`. v1's synthesizer.
pub struct MacSay {
    voice: String,
    rate_wpm: u32,
}

impl MacSay {
    pub fn new() -> MacSay {
        MacSay {
            voice: pick_voice(),
            rate_wpm: std::env::var("RICHOS_TTS_RATE")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(DEFAULT_RATE_WPM),
        }
    }

    pub fn voice(&self) -> &str {
        &self.voice
    }
    pub fn rate_wpm(&self) -> u32 {
        self.rate_wpm
    }
}

impl Default for MacSay {
    fn default() -> Self {
        MacSay::new()
    }
}

impl SpeechSynth for MacSay {
    fn synthesize(&self, text: &str, target_rate: u32, scratch_dir: &Path) -> Result<Speech, TtsError> {
        std::fs::create_dir_all(scratch_dir).map_err(|e| TtsError::Io(e.to_string()))?;
        let stamp = format!("{}-{:?}", std::process::id(), std::thread::current().id());
        let txt_path = scratch_dir.join(format!("say-{stamp}.txt"));
        let wav_path = scratch_dir.join(format!("say-{stamp}.wav"));

        // Text goes through a FILE, never argv: a sentence starting with "-" would otherwise
        // be parsed as a flag, and Rich's own words must never become command-line options.
        std::fs::write(&txt_path, text).map_err(|e| TtsError::Io(e.to_string()))?;

        let started = Instant::now();
        let out = Command::new("/usr/bin/say")
            .arg("-v")
            .arg(&self.voice)
            .arg("-r")
            .arg(self.rate_wpm.to_string())
            .arg("-f")
            .arg(&txt_path)
            .arg("-o")
            .arg(&wav_path)
            .arg(format!("--data-format=LEI16@{target_rate}"))
            .output()
            .map_err(|e| TtsError::Io(e.to_string()))?;
        let synth_ms = started.elapsed().as_millis() as u64;
        let _ = std::fs::remove_file(&txt_path);

        if !out.status.success() {
            let _ = std::fs::remove_file(&wav_path);
            return Err(TtsError::Failed {
                status: out.status.to_string(),
                stderr: String::from_utf8_lossy(&out.stderr).trim().to_string(),
            });
        }
        let bytes = std::fs::read(&wav_path).map_err(|e| TtsError::Io(e.to_string()))?;
        let _ = std::fs::remove_file(&wav_path);
        let pcm = wav::read_pcm16(&bytes).map_err(TtsError::Decode)?;
        let (mono, rate) = pcm.into_mono();
        // `say` honours the requested rate, but never assume it: convert if it did not.
        let samples = if rate == target_rate { mono } else { wav::resample(&mono, rate, target_rate) };
        Ok(Speech { samples, sample_rate: target_rate, synth_ms })
    }

    fn voice_label(&self) -> String {
        format!("macOS say · {} · {} wpm", self.voice, self.rate_wpm)
    }
}

/// Choose THE voice. `RICHOS_TTS_VOICE` wins; otherwise the first installed entry of
/// [`VOICE_PREFERENCE`]; otherwise "Samantha", which ships on every Mac.
pub fn pick_voice() -> String {
    if let Ok(v) = std::env::var("RICHOS_TTS_VOICE") {
        if !v.trim().is_empty() {
            return v;
        }
    }
    let installed = installed_voices();
    for want in VOICE_PREFERENCE {
        if installed.iter().any(|v| v == want) {
            return (*want).to_string();
        }
    }
    "Samantha".to_string()
}

/// Voice names `say -v '?'` reports. Parses the fixed-width listing: the name runs up to the
/// locale column (two-or-more spaces followed by a `xx_YY` token).
pub fn installed_voices() -> Vec<String> {
    let Ok(out) = Command::new("/usr/bin/say").args(["-v", "?"]).output() else {
        return Vec::new();
    };
    String::from_utf8_lossy(&out.stdout).lines().filter_map(parse_voice_line).collect()
}

/// Pull the voice name out of one `say -v '?'` line. Names contain spaces and parentheses
/// ("Daniel (Enhanced)", "Eddy (English (UK))"), so the split point is the locale token.
pub fn parse_voice_line(line: &str) -> Option<String> {
    let idx = line.find(|c: char| c == '#')?;
    let before = &line[..idx];
    // The locale is the last whitespace-separated token before the comment marker.
    let mut parts: Vec<&str> = before.split_whitespace().collect();
    parts.pop()?; // the locale, e.g. en_GB
    let name = parts.join(" ");
    if name.is_empty() {
        None
    } else {
        Some(name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// INVARIANT: the preference list is the SAME voice at three quality tiers first, so a
    /// CEO installing an Enhanced variant upgrades Rich's voice without changing his
    /// identity — and without any code change.
    #[test]
    fn the_voice_preference_upgrades_quality_without_changing_identity() {
        assert_eq!(VOICE_PREFERENCE[0], "Daniel (Premium)");
        assert_eq!(VOICE_PREFERENCE[1], "Daniel (Enhanced)");
        assert_eq!(VOICE_PREFERENCE[2], "Daniel");
        assert!(VOICE_PREFERENCE[..3].iter().all(|v| v.starts_with("Daniel")));
    }

    /// INVARIANT: `say -v '?'` lines parse into names, including the parenthesised ones that
    /// a naive "first token" split would truncate.
    #[test]
    fn voice_lines_parse_including_parenthesised_names() {
        assert_eq!(parse_voice_line("Daniel              en_GB    # Hello!").as_deref(), Some("Daniel"));
        assert_eq!(
            parse_voice_line("Eddy (English (UK)) en_GB    # Hello! My name is Eddy.").as_deref(),
            Some("Eddy (English (UK))")
        );
        assert_eq!(
            parse_voice_line("Daniel (Enhanced)   en_GB    # Hello!").as_deref(),
            Some("Daniel (Enhanced)")
        );
        assert_eq!(parse_voice_line("Bad News            en_US    # Hello!").as_deref(), Some("Bad News"));
        assert_eq!(parse_voice_line("no comment marker here"), None);
    }

    /// INVARIANT: duration and real-time factor are DERIVED from the samples and the
    /// measured clock — never stored, never estimated.
    #[test]
    fn speech_metrics_are_derived_not_stored() {
        let s = Speech { samples: vec![0.0; 48_000], sample_rate: 48_000, synth_ms: 324 };
        assert!((s.duration_secs() - 1.0).abs() < 1e-6);
        assert!((s.realtime_factor() - 0.324).abs() < 1e-6);
        let empty = Speech { samples: vec![], sample_rate: 48_000, synth_ms: 10 };
        assert_eq!(empty.duration_secs(), 0.0);
        assert_eq!(empty.realtime_factor(), 0.0);
    }

    /// INVARIANT: a synthesis failure never leaks machinery to the CEO — and never stops the
    /// conversation, because text still works.
    #[test]
    fn a_synthesis_failure_degrades_to_text_without_leaking_machinery() {
        let e = TtsError::Failed { status: "exit code: 1".into(), stderr: "/usr/bin/say: no voice".into() };
        let msg = e.ceo_message();
        assert!(!msg.contains("/usr/bin"));
        assert!(!msg.contains("exit"));
        assert!(msg.contains("text"), "the CEO must be told the conversation continues: {msg}");
        assert!(e.to_string().contains("no voice"));
    }

    /// LIVE (macOS): the real synthesizer produces real audio, fast enough for gapless
    /// pipelining. Ignored elsewhere. Asserts the real-time factor is well under 1.0 —
    /// the precondition the whole pipelining design rests on.
    #[test]
    #[cfg(target_os = "macos")]
    fn live_macos_synthesis_outruns_playback() {
        if !Path::new("/usr/bin/say").exists() {
            return;
        }
        let dir = std::env::temp_dir().join("richos-voice-tts-test");
        let synth = MacSay::new();
        let speech = synth
            .synthesize("Acme signed at 4.5 million. I would push back.", 48_000, &dir)
            .expect("say should synthesise");
        assert_eq!(speech.sample_rate, 48_000);
        assert!(speech.duration_secs() > 1.0, "suspiciously short: {}", speech.duration_secs());
        assert!(
            speech.realtime_factor() < 0.5,
            "synthesis too slow for gapless pipelining: rtf {:.3}",
            speech.realtime_factor()
        );
        // Real audio, not a silent file.
        let peak = speech.samples.iter().fold(0.0f32, |m, s| m.max(s.abs()));
        assert!(peak > 0.05, "synthesised audio is silent (peak {peak})");
        std::fs::remove_dir_all(&dir).ok();
    }
}
