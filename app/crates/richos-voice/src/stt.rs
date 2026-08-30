//! Speech to text — local whisper.cpp, reusing the model path the repo already ships.
//!
//! **No cloud STT, ever.** The repo already runs whisper.cpp locally in two places — the
//! open-wispr dictation path (the local-dictation notes) and the call-transcription service
//! (`tools/richos-service/lib/{config,transcribe}.js`) — so this is a Rust port of that
//! resolution logic, not a new dependency. Same binary (`whisper-cli`), same model
//! directories, same env-override names, so one machine feeds all three.
//!
//! ## Utterance-endpointed, NOT token-streaming — stated plainly
//!
//! `whisper-cli` transcribes a finished file. There is no partial-hypothesis stream and
//! therefore **no live transcript building word-by-word while the CEO talks** (the UX direction §4.1
//! sketch shows one; this v1 does not deliver it). What the CEO gets instead is the finished
//! transcript landing in the thread within ~0.5 s of him stopping. The upgrade path is a warm
//! whisper daemon or `whisper-stream`, both flagged in the brief.
//!
//! ## Model choice for the CONVERSATIONAL loop: `small.en`
//!
//! Measured on this M4, cold subprocess, a 3.095 s utterance ("Rich, what is the status of
//! the voice pipeline today?"), three runs: **0.74 s / 0.47 s / 0.47 s**, transcript exact.
//! The local-dictation notes record the same profile (0.48–1.08 s) and record that
//! turbo-class accuracy costs **+0.63–0.79 s absolute** for −2.1 WER points. That cost is
//! mostly COMPUTE, not model load: measured 2026-08-26, turbo's fixed per-invocation overhead
//! is 0.48–0.59 s and `small.en`'s is 0.20–0.23 s, so a warm daemon returns only ~0.3 s of
//! the gap. An earlier note here claimed a ~1.4 s load tax and that a warm daemon would give
//! turbo accuracy at `small.en` speed — both are measured FALSE
//! (the dictation-daemon + q5 brief, 2026-08-26). Dictation can absorb the
//! remaining cost; a spoken conversation cannot — a second of dead air after every sentence is
//! the difference between talking to Rich and operating him. So the conversational default
//! stays `small.en`, and the honest lever is a smaller/quantized model, not a daemon.
//! `RICHOS_VOICE_WHISPER_MODEL` overrides for anyone who wants turbo anyway.

use crate::vad::SAMPLE_RATE;
use crate::wav;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

/// The conversational default. NOT the same as the service's `large-v3-turbo` default —
/// see the module docs for why latency wins here and accuracy wins there.
pub const DEFAULT_MODEL_ID: &str = "small.en";

#[derive(Debug)]
pub enum SttError {
    BinaryNotFound(String),
    ModelNotFound(String),
    Io(String),
    Failed { status: String, stderr: String },
}

impl SttError {
    /// The CEO-facing line. No paths, no exit codes, no model filenames.
    pub fn ceo_message(&self) -> String {
        match self {
            SttError::BinaryNotFound(_) | SttError::ModelNotFound(_) => {
                // NAMES THE PARTY. "Aren't installed yet" implies somebody will install them
                // and never said who, leaving a reader who cannot install anything holding a
                // job with no owner.
                "My ears aren't installed on this machine yet — whoever set RichOS up adds \
                 those. I can still read what you type."
                    .into()
            }
            SttError::Io(_) | SttError::Failed { .. } => {
                "I didn't catch that — say it again?".into()
            }
        }
    }
}

impl std::fmt::Display for SttError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SttError::BinaryNotFound(s) => write!(f, "whisper binary not found: {s}"),
            SttError::ModelNotFound(s) => write!(f, "whisper model not found: {s}"),
            SttError::Io(s) => write!(f, "stt io: {s}"),
            SttError::Failed { status, stderr } => write!(f, "whisper failed ({status}): {stderr}"),
        }
    }
}

/// Resolve `whisper-cli`: `RICHOS_WHISPER_BIN`, then PATH, then the Homebrew prefixes.
/// Deliberately the SAME env var the Node service uses so one machine configures both.
pub fn resolve_whisper_bin() -> Result<PathBuf, SttError> {
    if let Ok(v) = std::env::var("RICHOS_WHISPER_BIN") {
        let p = PathBuf::from(expand_tilde(&v));
        if p.exists() {
            return Ok(p);
        }
        return Err(SttError::BinaryNotFound(format!("RICHOS_WHISPER_BIN={v} does not exist")));
    }
    if let Ok(out) = Command::new("/usr/bin/env").args(["sh", "-c", "command -v whisper-cli"]).output() {
        let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !s.is_empty() && Path::new(&s).exists() {
            return Ok(PathBuf::from(s));
        }
    }
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
        let p = Path::new(dir).join("whisper-cli");
        if p.exists() {
            return Ok(p);
        }
    }
    Err(SttError::BinaryNotFound("whisper-cli is not on PATH".into()))
}

/// Resolve a GGML model file. Mirrors `tools/richos-service/lib/config.js::resolveModel`,
/// plus a voice-specific override so the conversational model can differ from the
/// transcription service's without fighting over one variable.
pub fn resolve_model(model_id: &str) -> Result<PathBuf, SttError> {
    for var in ["RICHOS_VOICE_WHISPER_MODEL", "RICHOS_WHISPER_MODEL"] {
        if let Ok(v) = std::env::var(var) {
            let p = PathBuf::from(expand_tilde(&v));
            if p.exists() {
                return Ok(p);
            }
            return Err(SttError::ModelNotFound(format!("{var}={v} does not exist")));
        }
    }
    let file = format!("ggml-{model_id}.bin");
    let home = std::env::var("HOME").unwrap_or_default();
    let mut dirs: Vec<PathBuf> = Vec::new();
    if let Ok(d) = std::env::var("RICHOS_MODEL_DIR") {
        dirs.push(PathBuf::from(expand_tilde(&d)));
    }
    dirs.push(Path::new(&home).join(".config/open-wispr/models"));
    dirs.push(Path::new(&home).join("Models/Whisper"));
    dirs.push(Path::new(&home).join(".cache/whisper.cpp"));
    for d in &dirs {
        let p = d.join(&file);
        if p.exists() {
            return Ok(p);
        }
    }
    Err(SttError::ModelNotFound(format!(
        "{file} not found in {}",
        dirs.iter().map(|d| d.display().to_string()).collect::<Vec<_>>().join(", ")
    )))
}

fn expand_tilde(p: &str) -> String {
    if let Some(rest) = p.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return format!("{home}/{rest}");
        }
    }
    p.to_string()
}

/// A resolved, ready-to-use recognizer. Resolution happens ONCE at voice-mode start so a
/// missing model is a calm message at the toggle, not a failure in the middle of a sentence.
pub struct Recognizer {
    bin: PathBuf,
    model: PathBuf,
    model_id: String,
    /// Optional decoding hint. The loro entity-biasing lever from the local-dictation notes
    /// plugs in HERE — feed `loro/entities.json` terms and whisper biases toward the
    /// company's names and jargon. Not wired to loro in v1; the seam is one string.
    prompt: Option<String>,
}

impl Recognizer {
    pub fn resolve() -> Result<Recognizer, SttError> {
        let model_id =
            std::env::var("RICHOS_VOICE_WHISPER_MODEL_ID").unwrap_or_else(|_| DEFAULT_MODEL_ID.to_string());
        Ok(Recognizer {
            bin: resolve_whisper_bin()?,
            model: resolve_model(&model_id)?,
            model_id,
            prompt: std::env::var("RICHOS_WHISPER_PROMPT").ok().filter(|s| !s.trim().is_empty()),
        })
    }

    pub fn model_id(&self) -> &str {
        &self.model_id
    }
    pub fn model_path(&self) -> &Path {
        &self.model
    }
    pub fn binary_path(&self) -> &Path {
        &self.bin
    }

    /// Transcribe one utterance (16 kHz mono f32). Returns the text and the MEASURED
    /// wall-clock recognition latency.
    pub fn transcribe(&self, samples: &[f32], scratch_dir: &Path) -> Result<(String, u64), SttError> {
        std::fs::create_dir_all(scratch_dir).map_err(|e| SttError::Io(e.to_string()))?;
        let wav_path = scratch_dir.join(format!("utt-{}.wav", std::process::id()));
        wav::write_pcm16_mono(&wav_path, samples, SAMPLE_RATE).map_err(|e| SttError::Io(e.to_string()))?;

        let started = Instant::now();
        let mut cmd = Command::new(&self.bin);
        cmd.arg("-m")
            .arg(&self.model)
            .arg("-f")
            .arg(&wav_path)
            .args(["-l", "en", "-t", "4"])
            .arg("-np") // no progress prints — keep stdout clean
            .arg("-nt"); // no timestamps — we want the words, nothing else
        if let Some(p) = &self.prompt {
            cmd.arg("--prompt").arg(p);
        }
        let out = cmd.output().map_err(|e| SttError::Io(e.to_string()))?;
        let elapsed_ms = started.elapsed().as_millis() as u64;
        let _ = std::fs::remove_file(&wav_path);

        if !out.status.success() {
            return Err(SttError::Failed {
                status: out.status.to_string(),
                stderr: String::from_utf8_lossy(&out.stderr).trim().to_string(),
            });
        }
        Ok((clean_transcript(&String::from_utf8_lossy(&out.stdout)), elapsed_ms))
    }
}

/// Collapse whisper's stdout into one line of plain text.
pub fn clean_transcript(raw: &str) -> String {
    raw.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Whisper's documented silence/noise hallucinations. This is a NARROW, evidence-based list,
/// not a general stopword filter: "yes", "no", "yeah" and "okay" are real CEO decisions and
/// must survive. Verified on this machine — 1.000 s of digital silence through `small.en`
/// returns the single word "you".
const NOISE_TRANSCRIPTS: &[&str] = &[
    "you",
    "thank you",
    "thanks",
    "thank you very much",
    "thanks for watching",
    "thank you for watching",
    "please subscribe",
    "subscribe",
    "bye",
    "goodbye",
];

/// Is this transcript worth sending to Rich as a turn?
///
/// An open mic in a quiet room WILL produce spurious transcripts — see [`NOISE_TRANSCRIPTS`].
/// Sending one costs a real Claude turn and puts words in the CEO's mouth in the durable
/// ledger, which is the worse failure. Dropping a genuine "yes" is the failure this list is
/// kept narrow to avoid.
pub fn is_meaningful(transcript: &str) -> bool {
    let stripped = strip_annotations(transcript);
    let norm: String = stripped
        .trim()
        .trim_matches(|c: char| !c.is_alphanumeric())
        .to_lowercase();
    if norm.is_empty() {
        return false;
    }
    if !norm.chars().any(|c| c.is_alphanumeric()) {
        return false;
    }
    !NOISE_TRANSCRIPTS.contains(&norm.as_str())
}

/// Remove `[BLANK_AUDIO]`, `(upbeat music)` and friends — whisper's non-speech annotations.
fn strip_annotations(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut depth_sq = 0i32;
    let mut depth_par = 0i32;
    for c in s.chars() {
        match c {
            '[' => depth_sq += 1,
            ']' => depth_sq = (depth_sq - 1).max(0),
            '(' => depth_par += 1,
            ')' => depth_par = (depth_par - 1).max(0),
            _ if depth_sq == 0 && depth_par == 0 => out.push(c),
            _ => {}
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// INVARIANT: whisper's stdout becomes one clean line, whatever leading newline or
    /// padding the CLI adds. (Observed: it prefixes "\n " before the text.)
    #[test]
    fn whisper_stdout_becomes_one_clean_line() {
        assert_eq!(
            clean_transcript("\n Rich, what is the status of the voice pipeline today?"),
            "Rich, what is the status of the voice pipeline today?"
        );
        assert_eq!(clean_transcript("\n one\n two \n\n three\n"), "one two three");
        assert_eq!(clean_transcript(""), "");
    }

    /// INVARIANT: the exact hallucination this machine produces from digital silence is
    /// rejected. Measured, not guessed: 1.000 s of zeros through small.en returns "you".
    #[test]
    fn the_word_whisper_hallucinates_from_silence_is_rejected() {
        assert!(!is_meaningful("\n you"), "the measured silence hallucination got through");
        assert!(!is_meaningful("You."));
        assert!(!is_meaningful("Thank you."));
        assert!(!is_meaningful("Thanks for watching!"));
    }

    /// INVARIANT: non-speech annotations alone are not a turn.
    #[test]
    fn annotation_only_transcripts_are_not_turns() {
        assert!(!is_meaningful("[BLANK_AUDIO]"));
        assert!(!is_meaningful("(upbeat music)"));
        assert!(!is_meaningful("[Music]"));
        assert!(!is_meaningful("   "));
        assert!(!is_meaningful("..."));
        assert!(!is_meaningful("."));
    }

    /// INVARIANT: the noise filter is NARROW. A one-word decision from the CEO is the whole
    /// point of voice mode and must never be swallowed.
    #[test]
    fn one_word_ceo_decisions_are_never_swallowed_by_the_noise_filter() {
        for word in ["Yes.", "No.", "Yeah", "Okay", "Approved.", "Stop.", "Ship it."] {
            assert!(is_meaningful(word), "{word} was dropped as noise");
        }
    }

    /// INVARIANT: real speech passes, including speech that merely CONTAINS a noise phrase.
    #[test]
    fn real_speech_passes_even_when_it_contains_a_noise_phrase() {
        assert!(is_meaningful("Renegotiate Acme and get me the number by Thursday."));
        assert!(is_meaningful("Thank you, that's exactly right."));
        assert!(is_meaningful("[cough] renegotiate Acme"));
    }

    /// INVARIANT: the conversational default is small.en, deliberately NOT the transcription
    /// service's large-v3-turbo — latency is the binding constraint in a conversation.
    #[test]
    fn the_conversational_default_model_is_small_en_for_latency() {
        assert_eq!(DEFAULT_MODEL_ID, "small.en");
        assert_ne!(DEFAULT_MODEL_ID, "large-v3-turbo");
    }

    /// INVARIANT: a missing recognizer reaches the CEO as a calm line with no path in it,
    /// while the developer-facing Display keeps the path.
    #[test]
    fn a_missing_recognizer_reaches_the_ceo_without_a_path_in_it() {
        let e = SttError::ModelNotFound("/Users/x/.config/open-wispr/models/ggml-small.en.bin".into());
        assert!(!e.ceo_message().contains('/'));
        assert!(e.to_string().contains("ggml-small.en.bin"));
    }

    /// Resolution is environment-dependent, so this asserts the CONTRACT (a result either
    /// way, never a panic) rather than a machine-specific path.
    #[test]
    fn resolution_returns_a_result_and_never_panics() {
        let _ = resolve_whisper_bin();
        let _ = resolve_model("small.en");
        let _ = resolve_model("definitely-not-a-real-model");
        assert!(resolve_model("definitely-not-a-real-model").is_err());
    }
}
