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
//! ## Model choice for the CONVERSATIONAL loop: ASKED, not compiled in
//!
//! Until 2026-09-10 this section defended a constant — `DEFAULT_MODEL_ID = "small.en"`,
//! identical on every machine in the world. The CEO's question was the right one:
//! *"WHY IS THE SHITTIEST POSSIBLE HARDWARE HARDCODED INTO THE APP???"* It now resolves at
//! run time from what the machine can actually do — [`crate::hardware`] holds the rule, the
//! measured ladder and the reasoning; this module supplies the measurement.
//!
//! **The budget stated here is the one the resolver gates on**, and it is unchanged: a
//! conversational utterance should land in **~0.5 s**, and **a second of dead air after every
//! sentence is the difference between talking to Rich and operating him.** That sentence is
//! now load-bearing rather than commentary — `model-costs.json` carries 1.000 s as the live
//! ceiling and cites this file for it.
//!
//! **What measuring it changed.** On this M4, three runs of a 3.095 s utterance cost
//! **0.539 / 0.578 / 0.593 s** for `small.en` — reproducing the 0.47–0.74 s this comment used to
//! claim, so the old figure was right and is now checked rather than trusted. The turbo-class
//! cost it quoted as "+0.63–0.79 s absolute" reproduces too, at **+0.749 s / +0.810 s** across
//! two load conditions. What was NOT right was the reason `small.en` was kept: the tier table
//! calls it the fallback for *"low-RAM hosts"*, and `large-v3-turbo-q5_0` measures
//! **8,945,664 B CHEAPER** in peak RSS. Memory never chose this model; latency did, and latency
//! is a property of the machine rather than of the product.
//!
//! So `q5_0` sits at the TOP of the live ladder and is rejected on every machine measured so far
//! (1.549 s and 1.331 s against the 1.000 s ceiling). The door opens by itself on the first
//! machine that decodes it in time. The honest lever is still a smaller/quantized model rather
//! than a warm daemon — turbo's fixed per-invocation overhead is 0.48–0.59 s against
//! `small.en`'s 0.20–0.23 s, so a daemon returns only ~0.3 s of the gap, and the earlier claim
//! of a ~1.4 s load tax curable by a daemon is measured FALSE (the dictation-daemon + q5 brief,
//! 2026-08-26).
//!
//! `RICHOS_VOICE_WHISPER_MODEL_ID` still names a model outright and
//! `RICHOS_VOICE_WHISPER_MODEL`/`RICHOS_WHISPER_MODEL` still pin the weights by path. Both win
//! over the resolver — an engineer reproducing a measurement needs them to. They are no longer
//! the ONLY control, which is the whole change.

use crate::vad::SAMPLE_RATE;
use crate::wav;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

/// The id assumed when NO resolution happened — and only then.
///
/// THIS IS NOT A DEFAULT AND THE RENAME IS THE POINT. It used to be `DEFAULT_MODEL_ID`, the
/// model every machine got. It is now reached in exactly two situations, neither of which is
/// "an ordinary launch":
///
/// 1. `RICHOS_VOICE_WHISPER_MODEL` or `RICHOS_WHISPER_MODEL` pinned the WEIGHTS BY PATH. Walking
///    a ladder then would be theatre — `resolve_model` returns that one file for every id, so
///    every rung would "measure" the same weights. The id is still needed, because
///    `toolchain.rs` looks the pin up by it, and this preserves exactly the behavior that
///    override has always had: point it at something else and the pin check refuses, loudly.
/// 2. The compiled-in registry is unusable, which is a build-time mistake in this repository.
///
/// The ORDINARY unmeasurable case does not come here: it goes to the registry's `safeRung`,
/// which the CEO is told about. See [`crate::hardware`].
pub const FALLBACK_MODEL_ID: &str = "small.en";

#[derive(Debug)]
pub enum SttError {
    BinaryNotFound(String),
    ModelNotFound(String),
    /// The model file is not the model RichOS pinned, or strict mode refused a changed binary.
    /// A SEPARATE variant from `ModelNotFound` on purpose: "not installed" and "installed but not
    /// what it claims to be" need different words to the CEO and different actions from whoever
    /// set the machine up.
    ToolchainRefused(String),
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
            SttError::ToolchainRefused(_) => {
                // DIFFERENT WORDS, because it is a different situation and the difference matters
                // to him. "Not installed yet" would be false and would send whoever helps him to
                // install something that is already there. Still no paths, no hashes, no
                // filenames — the detail is on stderr and in the record, where it is useful.
                "Something about my hearing changed on this machine and I'd rather not guess at \
                 what you said than get it wrong. Whoever set RichOS up can put it right. I can \
                 still read what you type."
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
            SttError::ToolchainRefused(s) => write!(f, "whisper toolchain refused: {s}"),
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

/// Text-context budget when NO decoding prompt is configured: none, the pipeline-wide invariant.
///
/// This path used to pass no `-mc` at all, which meant whisper.cpp's own `-1` — carry every
/// previously decoded token — the identical unexamined default that filled 7.8% of a 92-minute
/// channel with one fabricated sentence in the call-transcription service
/// (`docs/measurements/whisper-settings-2026-09-10/measurements/longform.txt`). It was fixed there
/// on 2026-08-29 and left live here, in a second consumer nobody had audited.
const MAX_CONTEXT_NO_PROMPT: &str = "0";

/// Text-context budget when a decoding prompt IS configured.
///
/// NOT a compromise and not a guess. At `0` the prompt is INERT — whisper has no room to keep the
/// prompt tokens, so the flag is accepted and does nothing. Measured on one 6-second utterance
/// through `small.en`, three runs each
/// (`docs/measurements/whisper-settings-2026-09-10/measurements/dictation-probe.txt`):
///
/// ```text
///   -mc -1  (what this path shipped)   "Haldan Freight"    587-661 ms
///   -mc 0                              "Haldan Freight"    612-641 ms
///   -mc 0  + prompt                    "Haldan Freight"    609-614 ms   <- prompt does NOTHING
///   -mc 64 + prompt                    "Halden Freight"    607-654 ms   <- correct
/// ```
///
/// 64 is the smallest budget measured to recover the names: on the 6-call reference corpus a
/// carried entity prompt at 64 takes proper-noun exact hits from 46 to 55 of 66 and gives the best
/// WER measured (2.73%), and going to 224 adds no further names while wrecking the transcript
/// (9.92%, insertions 8 -> 156).
///
/// THE COST, STATED. Carried context is what produces long-form fabrication: 64 tokens fills 3.3%
/// of a 92-minute timeline with repeated phrases where 0 fills none. That is why it is taken ONLY
/// when a prompt is set — dictation utterances are seconds long, so there is nothing to accumulate
/// — and why anyone routing a long recording through this path should read the settings table
/// first. The alternative was to accept a prompt and silently ignore it, and a seam that reports on
/// while doing nothing is the defect class this codebase refuses everywhere else.
const MAX_CONTEXT_WITH_PROMPT: &str = "64";

/// The decode flags this path hands to `whisper-cli`, everything except `-m` and `-f`.
///
/// A FUNCTION, SO THE SETTINGS CAN BE ASSERTED WITHOUT A DECODER. These values are decided in
/// `docs/measurements/whisper-settings-2026-09-10/whisper-settings-decisions.md` §7; a test that
/// cannot see them cannot stop the next one being added by accident.
pub fn decode_args(prompt: Option<&str>) -> Vec<String> {
    let mut args: Vec<String> = vec![
        // Pinned, not inherited: `-l auto` is byte-identical on English audio and 20% slower.
        "-l".into(),
        "en".into(),
        // The decode is Metal-bound; 8 threads measured byte-identical at the same wall clock.
        "-t".into(),
        "4".into(),
        // Flash attention. whisper.cpp 1.9.1 defaults it ON and it is worth 1.57 WER points, which
        // is far too much to hold by inheritance from a default a formula bump can flip.
        "-fa".into(),
        "-np".into(), // no progress prints — this path reads the words off stdout
        "-nt".into(), // no timestamps — we want the words, nothing else
        "-mc".into(),
        if prompt.is_some() { MAX_CONTEXT_WITH_PROMPT.into() } else { MAX_CONTEXT_NO_PROMPT.into() },
    ];
    if let Some(p) = prompt {
        args.push("--prompt".into());
        args.push(p.to_string());
    }
    args
}

// -------------------------------------------------------------------------------------------
// Choosing the model — the measurement half. The RULE lives in `hardware.rs`.
// -------------------------------------------------------------------------------------------

/// Pick the model for THIS machine, measuring it if nobody has yet.
///
/// The split with [`crate::hardware`] is deliberate and it is what makes any of this testable:
/// that module holds the ladder, the gates and the reasoning as a pure function; this one owns
/// the two impure things it needs — synthesizing a probe utterance and timing a decode.
///
/// COST, STATED. On a machine that has been measured before this is one small file read. On a
/// machine that has not, it is one `say` render plus one decode per rung tried, stopping at the
/// first rung that fits — two decodes on the reference host, about 2 s, ONCE for that machine and
/// that whisper binary. It happens in `Recognizer::resolve()`, which already hashes the binary
/// and sometimes a 487 MB model, and which already exists so that nothing surprising happens
/// mid-sentence.
fn choose_model(bin: &Path) -> crate::hardware::Resolution {
    use crate::hardware::{self, Basis, Machine};

    let machine = Machine::read();

    // AN EXPLICIT ID WINS OUTRIGHT. An engineer who names a model is not asking to be second
    // guessed, and reproducing a measurement depends on it.
    if let Ok(id) = std::env::var("RICHOS_VOICE_WHISPER_MODEL_ID") {
        let id = id.trim().to_string();
        if !id.is_empty() {
            return overridden(id, machine);
        }
    }
    // SO DOES A PATH OVERRIDE, and for a sharper reason: `resolve_model` returns that one file
    // for EVERY id, so a ladder walk would time the same weights four times and report a
    // "resolution" that resolved nothing.
    for var in ["RICHOS_VOICE_WHISPER_MODEL", "RICHOS_WHISPER_MODEL"] {
        if std::env::var(var).map(|v| !v.trim().is_empty()).unwrap_or(false) {
            return overridden(FALLBACK_MODEL_ID.to_string(), machine);
        }
    }

    let mut costs = hardware::Costs::load();
    // A rung is only a rung if its weights are on this machine.
    costs.retain_installed(|id| resolve_model(id).is_ok());

    // The cache is keyed by binary AND machine: a `brew upgrade` can change decode cost, and a
    // speed attributed to the wrong build is the hole `toolchain.rs` exists to close.
    let bin_sha = crate::toolchain::hash_file(bin).unwrap_or_default();
    let key = hardware::cache_key(&bin_sha, &machine);
    let cached = hardware::load_speeds(&key);

    // The probe utterance, synthesized once for this whole walk and only if something is actually
    // unmeasured. `say -o` writes a file and plays nothing, so this is silent even mid-call.
    let probe_dir = std::env::temp_dir().join("richos-voice-calibration");
    let mut probe_wav: Option<Option<PathBuf>> = None;

    let resolution = hardware::resolve_live(&costs, &machine, |id| {
        if let Some(secs) = cached.get(id) {
            return Some(*secs);
        }
        let wav = probe_wav
            .get_or_insert_with(|| synthesize_probe(&costs.probe_text, &probe_dir))
            .clone()?;
        let model = resolve_model(id).ok()?;
        let secs = time_decode(bin, &model, &wav, costs.live_ceiling_secs)?;
        hardware::record_speed(&key, id, secs);
        Some(secs)
    });

    // Said out loud on stderr as well as carried in provenance — the same channel the toolchain
    // warnings use, and the one a headless voice loop shares with whoever started it.
    if resolution.basis != Basis::TopRung {
        eprintln!("richos-voice: {}", resolution.provenance());
    }
    resolution
}

/// The shape an override takes: a resolution that records what the machine looked like without
/// pretending a rule chose anything.
fn overridden(model_id: String, machine: crate::hardware::Machine) -> crate::hardware::Resolution {
    crate::hardware::Resolution {
        model_id,
        basis: crate::hardware::Basis::Override,
        rejected: None,
        measured_secs: None,
        ceiling_secs: crate::hardware::Costs::load().live_ceiling_secs,
        machine,
    }
}

/// Render the probe sentence to a 16 kHz mono WAV with macOS `say`. `None` if it cannot be done.
///
/// `-o` WRITES A FILE AND PLAYS NOTHING, which is the only reason calibrating at voice-mode start
/// is acceptable at all — the alternative would put a sentence through the speakers on first
/// launch. Same synthesizer `tts.rs` already depends on, so this adds no new requirement.
///
/// The render is NOT expected to be byte-identical to the one the reference figures came from —
/// `say` output drifts between renders and voices differ per machine. It does not need to be: the
/// gate is "under 1.000 s", and the ladder's rungs differ by 2.5x, so a few percent of drift in
/// the probe cannot move a verdict.
fn synthesize_probe(text: &str, dir: &Path) -> Option<PathBuf> {
    if text.trim().is_empty() {
        return None;
    }
    std::fs::create_dir_all(dir).ok()?;
    let out = dir.join("probe.wav");
    if out.exists() {
        return Some(out);
    }
    let status = Command::new("say")
        .arg("-o")
        .arg(&out)
        .arg("--data-format=LEI16@16000")
        .arg(text)
        .status()
        .ok()?;
    if status.success() && out.exists() {
        Some(out)
    } else {
        None
    }
}

/// How many reps a calibration may take before it is allowed to REJECT a rung.
///
/// THREE, AND ONLY WHEN REJECTING — see [`time_decode`] for why the asymmetry is sound rather
/// than a compromise. Three is what `utterance-sweep.sh` takes, and the spread it measured is
/// the reason more would be waste and fewer would be wrong.
const CALIBRATION_REJECT_REPS: usize = 3;

/// Wall-clock seconds for a decode of `wav` by `model`, at the argv this path really uses —
/// the BEST of up to [`CALIBRATION_REJECT_REPS`] reps, and usually just one.
///
/// # Why a single sample is not enough, measured rather than supposed
///
/// The first version of this took one sample, and running it caught its own defect on the CEO's
/// machine: `small.en` timed **1.005 s** against the 1.000 s ceiling — five milliseconds over —
/// and the machine was demoted to `base.en` and told so. The reference figures for that same
/// model are 0.512 s quiet and 0.800 s busy. Nothing was wrong with the machine; the sample was
/// taken while it was doing something else.
///
/// `docs/measurements/hardware-model-resolution-2026-09-10/` §3 predicted exactly this — the same
/// M4 measured ~50% slower under load, and that is why the cache keeps a MINIMUM. A single
/// sample is trivially its own minimum, so the cache's protection did nothing until the
/// measurement itself took more than one.
///
/// # Why the extra reps are only spent on a REJECTION
///
/// The minimum over reps only ever goes DOWN. So a rep that already clears the ceiling settles
/// the question — no number of further reps could overturn it — and the walk takes it and stops.
/// Only a rep that MISSES the ceiling is inconclusive, because it might be this one sample rather
/// than the machine, and only then are more reps bought.
///
/// That asymmetry is the right way round on cost as well as on logic: a rejection is the
/// expensive, sticky verdict — it takes a model away from the CEO and writes a sentence explaining
/// it — so a rejection is what deserves corroboration. On a quiet reference machine this is four
/// decodes in total (three to reject `q5_0`, one to accept `small.en`), about 4.4 s, ONCE for that
/// machine and that whisper binary.
///
/// [`decode_args`]`(None)` is passed VERBATIM, not an approximation. A calibration at different
/// settings from the shipping run measures a decode this product never performs — `-fa` alone is
/// worth 1.57 WER points and a measurable slice of the wall clock.
fn time_decode(bin: &Path, model: &Path, wav: &Path, ceiling_secs: f64) -> Option<f64> {
    let mut best: Option<f64> = None;
    for _ in 0..CALIBRATION_REJECT_REPS {
        let started = Instant::now();
        let out = Command::new(bin)
            .arg("-m")
            .arg(model)
            .arg("-f")
            .arg(wav)
            .args(decode_args(None))
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        let secs = started.elapsed().as_secs_f64();
        best = Some(best.map_or(secs, |b: f64| b.min(secs)));
        // Settled: the minimum cannot rise, so no further rep could turn this into a rejection.
        if secs <= ceiling_secs {
            break;
        }
    }
    best
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
    /// Which binary, which ggml backends and which weights — established ONCE, here, and carried
    /// so every utterance is attributed to what actually heard it.
    toolchain: crate::toolchain::Report,
    /// WHY those weights and not better ones. `toolchain` answers "which model heard this?";
    /// this answers "and why was that the model on this machine?", which is the question a
    /// transcript could not answer at all while the id was a compile-time constant.
    resolution: crate::hardware::Resolution,
}

impl Recognizer {
    /// Resolve the binary and the model, and CHECK THEM, before the mic is ever opened.
    ///
    /// Resolution has always happened once here rather than per utterance, so that a missing model
    /// is a calm message at the toggle instead of a failure in the middle of a sentence. A
    /// SUBSTITUTED one now gets the same treatment, which is the point of doing the check in this
    /// function and not in `transcribe`: at 0.47–0.74 s per utterance there is no room to hash a
    /// 487 MB model on each one, and there is no need to — the binary cannot change between two
    /// sentences of one conversation, and the lock's cache means even this once is usually free.
    ///
    /// Weights that are not the pinned weights REFUSE. A binary or backend that is not the one
    /// this machine locked WARNS, loudly, naming both identities — see `toolchain.rs` for why the
    /// two differ. `RICHOS_WHISPER_STRICT_TOOLCHAIN=1` makes every warning a refusal.
    pub fn resolve() -> Result<Recognizer, SttError> {
        let bin = resolve_whisper_bin()?;
        let resolution = choose_model(&bin);
        let model_id = resolution.model_id.clone();
        let model = resolve_model(&model_id)?;
        let toolchain = crate::toolchain::check(&bin, &model, &model_id);
        // Said out loud on stderr, not only stored. A warning nobody meets is not a warning, and
        // this is the one channel a headless voice loop shares with whoever started it.
        for w in toolchain.warnings() {
            eprintln!("richos-voice: {w}");
        }
        if toolchain.verdict() == crate::toolchain::Severity::Refuse {
            return Err(SttError::ToolchainRefused(toolchain.refusals().join(" ")));
        }
        Ok(Recognizer {
            bin,
            model,
            model_id,
            prompt: std::env::var("RICHOS_WHISPER_PROMPT").ok().filter(|s| !s.trim().is_empty()),
            toolchain,
            resolution,
        })
    }

    /// One line naming the binary and the weights that heard this conversation. The answer to
    /// "which binary and which weights produced this?" for every turn this recognizer serves.
    ///
    /// UNCHANGED, AND STILL A `&str`. The resolution rides in [`Recognizer::provenance_full`]
    /// beside it rather than being spliced in here: this string is compared verbatim by
    /// `toolchain.rs`'s own test and is what existing readers already parse, and widening a
    /// stable identity line to carry a second, machine-dependent fact is how a record stops
    /// being comparable between two runs.
    pub fn provenance(&self) -> &str {
        &self.toolchain.provenance
    }

    /// The identity line PLUS why this model and not a better one — the whole answer, for a
    /// turn record or a support question.
    ///
    /// Example from the CEO's own M4, where the better rung exists and does not fit the budget:
    ///
    /// ```text
    /// whisper.cpp 1.9.1 bin:7dc20e3106d7 [BLAS/MTL/CPU] model:small.en@c6138d6d58ec
    ///   | model:small.en (hw-resolved, large-v3-turbo-q5_0 too slow here at 1.302s/utt > 1.000s;
    ///     this 0.512s/utt) mem:5873516544B/25769803776B pressure:warn
    /// ```
    pub fn provenance_full(&self) -> String {
        format!("{} | {}", self.toolchain.provenance, self.resolution.provenance())
    }

    /// Why this machine got this model. Carries the CEO-facing sentence when there is one.
    pub fn resolution(&self) -> &crate::hardware::Resolution {
        &self.resolution
    }

    /// The full identity report, for a caller that wants to record more than the line.
    pub fn toolchain(&self) -> &crate::toolchain::Report {
        &self.toolchain
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
        cmd.arg("-m").arg(&self.model).arg("-f").arg(&wav_path);
        cmd.args(decode_args(self.prompt.as_deref()));
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

    /// INVARIANT: this path never decodes at whisper.cpp's own text-context default.
    ///
    /// It did until 2026-09-10 — `-mc` was simply absent, so every dictation ran at `-1`, the
    /// setting that filled 7.8% of a 92-minute channel with one fabricated sentence in the sibling
    /// service. The whole point of the settings table is that a value nobody chose is not a value.
    #[test]
    fn decode_context_is_never_the_vendor_default() {
        for prompt in [None, Some("Halden Freight, Priya Sandoval")] {
            let args = decode_args(prompt);
            let i = args.iter().rposition(|a| a == "-mc").expect("-mc must be emitted");
            assert_ne!(args[i + 1], "-1", "the vendor default must never be what this path decodes at");
            assert!(args[i + 1].parse::<i32>().unwrap() >= 0);
        }
    }

    /// INVARIANT: a configured prompt is a prompt that WORKS.
    ///
    /// At `-mc 0` whisper accepts `--prompt` and ignores it — measured byte-identical to passing no
    /// prompt at all. So the two must never be shipped together: entity biasing that silently does
    /// nothing is worse than no entity biasing, because it reports success.
    #[test]
    fn a_configured_prompt_gets_a_context_budget_to_live_in() {
        let with = decode_args(Some("Halden Freight"));
        let i = with.iter().rposition(|a| a == "-mc").unwrap();
        assert!(
            with[i + 1].parse::<i32>().unwrap() >= 64,
            "a prompt needs room in the text context or it is inert; got -mc {}",
            with[i + 1]
        );
        assert!(with.iter().any(|a| a == "--prompt"));
        assert!(with.iter().any(|a| a == "Halden Freight"));

        // And without a prompt there is nothing to make room for, so the invariant is 0.
        let without = decode_args(None);
        let j = without.iter().rposition(|a| a == "-mc").unwrap();
        assert_eq!(without[j + 1], "0");
        assert!(!without.iter().any(|a| a == "--prompt"));
    }

    /// INVARIANT: flash attention is PASSED here too, for the same measured reason as the service —
    /// `-nfa` costs 1.57 WER points, and a default that valuable is not left to the vendor.
    #[test]
    fn flash_attention_is_passed_not_inherited() {
        assert!(decode_args(None).iter().any(|a| a == "-fa"));
    }

    /// INVARIANT: every flag this path passes is one the settings table decided. Adding a flag
    /// without deciding it fails here, which is the point.
    #[test]
    fn no_flag_ships_without_a_row_in_the_settings_table() {
        const DECIDED: &[&str] = &["-l", "-t", "-fa", "-np", "-nt", "-mc", "--prompt"];
        const TAKES_VALUE: &[&str] = &["-l", "-t", "-mc", "--prompt"];
        let args = decode_args(Some("Halden Freight"));
        let mut i = 0;
        while i < args.len() {
            assert!(
                DECIDED.contains(&args[i].as_str()),
                "{} reaches whisper-cli but is not in the settings decision table",
                args[i]
            );
            if TAKES_VALUE.contains(&args[i].as_str()) {
                i += 1;
            }
            i += 1;
        }
    }

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

    /// INVARIANT: **the conversational model is whatever THIS MACHINE can decode inside the
    /// conversational budget** — the RULE, not a string.
    ///
    /// # What this replaced, and why it had to go
    ///
    /// It used to be `the_conversational_default_model_is_small_en_for_latency`, and it read:
    ///
    /// ```text
    /// assert_eq!(DEFAULT_MODEL_ID, "small.en");
    /// assert_ne!(DEFAULT_MODEL_ID, "large-v3-turbo");
    /// assert_ne!(DEFAULT_MODEL_ID, "large-v3-turbo-q5_0");
    /// ```
    ///
    /// That test was careful about the wrong thing. Its own comment worried that pinning one
    /// turbo id would let the assertion pass while no longer testing what it was written to test —
    /// a real hazard, correctly spotted — and it answered by naming BOTH turbo ids. But the defect
    /// was a level up: **it asserted a constant, so it passed identically on every machine in the
    /// world and would have gone on passing if `small.en` had been the wrong choice for all of
    /// them.** A test that cannot fail on a bad machine is not testing the choice; it is
    /// testifying that somebody typed a string.
    ///
    /// The CEO named the same defect from the outside: *"WHY IS THE SHITTIEST POSSIBLE HARDWARE
    /// HARDCODED INTO THE APP???"*
    ///
    /// # What is pinned now
    ///
    /// The property that actually matters, over machines the CI runner will never be:
    ///
    /// - a machine fast enough for the better rung is GIVEN the better rung, and is told nothing,
    ///   because that is the product working;
    /// - a machine that is not is stepped DOWN and is TOLD, in words with no path and no model
    ///   filename in them;
    /// - the ceiling those verdicts turn on is the one this module's own docs state.
    ///
    /// Not one assertion below names `small.en`. Change the ladder, add a rung, re-measure a
    /// model, and this test goes on being the thing it was written to be — which is exactly what
    /// the old one could not do.
    #[test]
    fn the_conversational_model_is_the_one_this_machine_can_decode_in_time() {
        use crate::hardware::{resolve_live, Basis, Costs, Machine, Pressure};
        let costs = Costs::load();
        let machine = Machine {
            total_bytes: 25_769_803_776,
            available_bytes: 5_873_516_544,
            pressure: Pressure::Warn,
            cores: 10,
        };

        // The ceiling is this module's stated failure point, carried in the registry rather than
        // restated. If that sentence in the module docs ever changes, this is where it bites.
        assert_eq!(costs.live_ceiling_secs, 1.0, "a second of dead air is the stated failure point");

        // A machine that clears the ceiling on the top rung gets the top rung — whatever it is
        // called — and is told nothing.
        let fast = resolve_live(&costs, &machine, |_| Some(costs.live_ceiling_secs - 0.5));
        assert_eq!(fast.model_id, costs.live_ladder[0], "the best rung this machine can afford");
        assert_eq!(fast.basis, Basis::TopRung);
        assert_eq!(fast.ceo_message(), None, "the product working is not a notification");

        // A machine that does not clear it on the top rung is stepped down, and is told.
        let slow = resolve_live(&costs, &machine, |id| {
            if id == costs.live_ladder[0] {
                Some(costs.live_ceiling_secs + 0.302)
            } else {
                Some(costs.live_ceiling_secs - 0.488)
            }
        });
        assert_ne!(slow.model_id, costs.live_ladder[0], "the rung it could not afford");
        assert_eq!(slow.basis, Basis::TooSlow);
        let told = slow.ceo_message().expect("a machine that lost the better model is told so");
        assert!(!told.contains('/'), "no paths reach him: {told}");
        assert!(!told.contains(".en") && !told.contains("q5_0"), "no model filenames reach him: {told}");
    }

    /// INVARIANT: the two env overrides still win outright, and they win in the two different
    /// ways they always have — an ID names a model, a PATH pins the weights.
    ///
    /// The path form is the sharper case: `resolve_model` returns that one file for EVERY id, so
    /// a ladder walk under it would time the same weights on every rung and report a resolution
    /// that resolved nothing. It short-circuits to `Override` instead, and `FALLBACK_MODEL_ID`
    /// supplies the id `toolchain.rs` looks the pin up by — preserving exactly the behavior that
    /// override has always had, including refusing when the file is not what the pin says.
    #[test]
    fn an_engineer_who_names_a_model_or_a_path_is_not_second_guessed() {
        assert_eq!(FALLBACK_MODEL_ID, "small.en", "the id a path override is attributed to");
        // The resolver is never consulted for an override, so the basis is the whole assertion:
        // it records that no rule ran, rather than a rung that was never chosen.
        let m = crate::hardware::Machine::read();
        let r = overridden("large-v3-turbo".into(), m);
        assert_eq!(r.basis, crate::hardware::Basis::Override);
        assert_eq!(r.model_id, "large-v3-turbo");
        assert_eq!(r.ceo_message(), None, "an engineer's own choice is not explained back to him");
        assert!(r.provenance().contains("env-override"), "{}", r.provenance());
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
