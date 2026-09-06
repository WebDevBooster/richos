//! The controller — the only stateful thing in the crate, and the only place threads live.
//!
//! Four threads, each with one job:
//!
//! | thread | job | must not |
//! |---|---|---|
//! | audio capture callback | VAD, barge-in monitor, utterance buffering | allocate much, block, or emit UI events |
//! | supervisor (40 Hz tick) | own the state machine, emit every UI event, dispatch work | do audio work |
//! | recognizer | whisper.cpp per finished utterance | block the mic |
//! | speaker | synthesize sentences and queue them for playout | block the turn |
//!
//! The capture callback owns its VAD/recorder/monitor outright — no locks — and talks to the
//! supervisor over a channel plus two atomics. That is deliberate: a `Mutex` on the audio
//! thread is how a voice pipeline starts clicking.
//!
//! ## The half-duplex TAINT rule — now conditional, and why
//!
//! While Rich is audible the microphone stays open (barge-in needs it), but any utterance that
//! BEGINS during his playout used to be marked **tainted** and discarded unless barge-in
//! actually fired during it. Without that rule, on speakers Rich hears himself, transcribes his
//! own sentence and answers it — the pilot's echo failure, one step worse.
//!
//! The rule's cost was stated plainly here: on speakers, the CEO could not start a new thought
//! while Rich was talking. He had to talk over him for the full 5.008 s debounce or tap "stop".
//! These docs said **"Real AEC deletes this rule. It is interim, and it is named as interim."**
//!
//! It is now deleted, conditionally and honestly. When [`crate::aec::EchoCanceller::confident`]
//! is true — the canceller has MEASURED its residual echo 6 dB below the VAD's speech floor and
//! held it there for 2.000 s — Rich's voice is no longer meaningfully present in the frames the
//! recorder buffers, so an utterance beginning while he speaks is not echo, it is the CEO
//! starting a sentence. It is kept.
//!
//! Whenever the canceller is NOT confident, the taint rule is exactly what it was. That is not
//! a hedge; it is the same fallback the barge-in debounce uses, driven by the same measurement.

use crate::aec::EchoCanceller;
use crate::bargein::{BargeInMonitor, BargeInMode, BARGE_IN_DEBOUNCE_FRAMES};
use crate::capture::{self, AudioSource, Capture};
use crate::chunk::SentenceChunker;
use crate::endpoint::{UtteranceRecorder, Utterance};
use crate::event::{VoiceEvent, VoiceObserver};
use crate::noaudio::{no_audio_window_secs, NoAudioDetector};
use crate::playout::Playout;
use crate::state::{VoiceState, VoiceStateMachine};
use crate::stt::{self, Recognizer};
use crate::tts::{MacSay, SpeechSynth};
use crate::vad::{frames_to_secs, Vad};
use crate::voiced::VoiceEvidence;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Supervisor tick. 25 ms is faster than the eye notices and far slower than the 16.000 ms
/// audio frame, so the UI never lags the mic and the tick never competes with audio.
const TICK: Duration = Duration::from_millis(25);

/// Emit a level update at most this often — a 62.5 Hz meter is wasted work in a webview.
const LEVEL_EMIT_EVERY: Duration = Duration::from_millis(100);

pub fn now_millis() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

#[derive(Debug)]
pub enum VoiceStartError {
    Capture(capture::CaptureError),
    Playout(crate::playout::PlayoutError),
    Stt(stt::SttError),
}

impl VoiceStartError {
    /// The calm line the CEO sees when the `◉` toggle cannot come up.
    pub fn ceo_message(&self) -> String {
        match self {
            VoiceStartError::Capture(e) => e.ceo_message(),
            VoiceStartError::Playout(e) => e.ceo_message(),
            VoiceStartError::Stt(e) => e.ceo_message(),
        }
    }
}

impl std::fmt::Display for VoiceStartError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            VoiceStartError::Capture(e) => write!(f, "{e}"),
            VoiceStartError::Playout(e) => write!(f, "{e}"),
            VoiceStartError::Stt(e) => write!(f, "{e}"),
        }
    }
}

/// How voice mode was configured — every field is a fact worth reporting, never a guess.
#[derive(Debug, Clone)]
pub struct Diagnostics {
    pub input_source: String,
    pub input_rate: u32,
    pub input_channels: u16,
    pub output_device: String,
    pub output_rate: u32,
    pub output_channels: u16,
    pub stt_model: String,
    pub stt_binary: String,
    pub tts_voice: String,
    pub echo_gate: String,
    pub echo_cancellation: bool,
    pub barge_in_frames: u32,
    pub barge_in_secs: f32,
}

impl Diagnostics {
    /// One line for stderr at voice-mode start. Developer-facing only — never the CEO's view.
    pub fn summary(&self) -> String {
        format!(
            "in={} {} Hz/{} ch · out={} {} Hz/{} ch · stt={} · tts={} · aec={} · barge-in={} frames ({:.3} s)",
            self.input_source,
            self.input_rate,
            self.input_channels,
            self.output_device,
            self.output_rate,
            self.output_channels,
            self.stt_model,
            self.tts_voice,
            self.echo_gate,
            self.barge_in_frames,
            self.barge_in_secs,
        )
    }
}

#[derive(Debug, Clone)]
pub struct VoiceOptions {
    pub source: AudioSource,
    /// Where the utterance WAVs and synthesis WAVs live. Under the app data dir in the shell.
    pub scratch_dir: PathBuf,
}

impl Default for VoiceOptions {
    fn default() -> Self {
        VoiceOptions {
            source: AudioSource::from_env(),
            scratch_dir: std::env::temp_dir().join("richos-voice"),
        }
    }
}

/// Messages from the audio callback to the supervisor. Small and allocation-light except for
/// `Utterance`, which is the whole point and happens once per sentence the CEO speaks.
#[derive(Debug)]
pub enum CapMsg {
    /// The CEO started talking. `tainted` = it began while Rich was audible.
    Started { tainted: bool },
    /// An utterance completed and is worth recognizing.
    Utterance(Box<Utterance>),
    /// An utterance completed but was discarded (too short, or tainted echo).
    Discarded { tainted: bool },
    /// The post-open silent-input verdict CHANGED (`noaudio.rs`). `silent` = the stream is
    /// open and healthy but has delivered nothing above -80.00 dBFS for 3.008 s. Sent once
    /// per transition, never once per frame.
    NoAudio { silent: bool },
    /// Rich was cut off — either by the full debounce, or by "tap to stop".
    ///
    /// `mid_utterance` says whether the CEO is actually talking at that instant. A debounce
    /// barge-in always is (that is what fired it); a "tap to stop" often is NOT — he can hit
    /// the button in silence. Without this the state machine would be told "he is talking"
    /// and, with no utterance to end, would sit in `Hearing` forever.
    BargeIn { mid_utterance: bool },
}

/// Everything the audio callback decides, in one place, with no I/O and no locks.
///
/// The callback is a THIN adapter over this: it hands over a frame plus two booleans and
/// forwards whatever comes back. That split exists so the barge-in/taint/endpointing
/// COMPOSITION is unit-testable — testing the monitor and the recorder separately would
/// leave the wiring between them (which is where the bugs live) untested.
pub struct CaptureBrain {
    vad: Vad,
    recorder: UtteranceRecorder,
    monitor: BargeInMonitor,
    /// Post-open silent-input watch. Fed the RMS of the SAME frame the recorder buffers —
    /// collector-path parity, so what the CEO is warned about cannot drift from what STT
    /// would actually have received.
    noaudio: NoAudioDetector,
    /// The echo canceller, if one could be started. `None` is the honest fallback and puts
    /// the 5.008 s debounce and the taint rule permanently in force.
    aec: Option<EchoCanceller>,
    /// Scratch for the residual. Preallocated: this runs on the audio callback thread.
    residual: Vec<f32>,
    was_recording: bool,
    /// This utterance began while Rich was audible: echo until proven otherwise.
    tainted: bool,
    /// A barge-in fired during the current utterance, which proves it is NOT echo.
    barged: bool,
}

impl Default for CaptureBrain {
    fn default() -> Self {
        CaptureBrain::new()
    }
}

impl CaptureBrain {
    /// A brain with NO echo cancellation: the 5.008 s consecutive debounce and the taint rule,
    /// exactly as they were before `aec.rs` existed.
    pub fn new() -> Self {
        CaptureBrain {
            vad: Vad::default(),
            recorder: UtteranceRecorder::new(),
            monitor: BargeInMonitor::default(),
            noaudio: NoAudioDetector::default(),
            aec: None,
            residual: vec![0.0; crate::vad::VAD_FRAME_SAMPLES],
            was_recording: false,
            tainted: false,
            barged: false,
        }
    }

    /// A brain with a real echo canceller. The canceller lives HERE, owned outright by the
    /// capture path, so there is no lock on the audio thread — the only thing shared with the
    /// playout thread is the lock-free reference ring the canceller was built with.
    pub fn with_aec(aec: EchoCanceller) -> Self {
        CaptureBrain { aec: Some(aec), ..CaptureBrain::new() }
    }

    /// The canceller's live figures, for the diagnostics line and the UI.
    pub fn aec_metrics(&self) -> Option<crate::aec::AecMetrics> {
        self.aec.as_ref().map(|a| a.metrics())
    }

    /// Has the canceller measured itself into a position to be believed? This is what
    /// shortens the barge-in debounce and what relaxes the taint rule — nothing else does.
    pub fn aec_confident(&self) -> bool {
        self.aec.as_ref().is_some_and(|a| a.confident())
    }

    /// Which barge-in rule is in force right now.
    pub fn barge_in_mode(&self) -> BargeInMode {
        self.monitor.mode()
    }

    /// Live input level 0..1 for the UI meter.
    pub fn level(&self) -> f32 {
        self.vad.level()
    }

    /// Consecutive speech frames counted toward an interruption — the diagnostic that makes
    /// "why didn't it barge in" answerable.
    pub fn barge_run_frames(&self) -> u32 {
        self.monitor.run_frames()
    }

    /// Is the open stream currently delivering nothing at all?
    pub fn no_audio(&self) -> bool {
        self.noaudio.no_audio()
    }

    /// Consecutive dead frames counted so far — the "why did/didn't it warn" diagnostic.
    pub fn dead_run_frames(&self) -> u32 {
        self.noaudio.dead_run_frames()
    }

    /// One exact VAD frame. `speaking` = Rich currently has audio playing. `forced` = the UI's
    /// "tap to stop" was pressed since the last frame.
    pub fn push_frame(&mut self, frame: &[f32], speaking: bool, forced: bool) -> Vec<CapMsg> {
        let mut out = Vec::new();

        // ---- ECHO CANCELLATION, first and once ------------------------------------------
        // Everything downstream — the VAD, the endpointer, the recorder, the silent-input
        // watch, and therefore whisper — sees the RESIDUAL, not the raw microphone. That is
        // what "collector-path parity" has to mean once a canceller exists: there is exactly
        // one version of the audio and it is the one that becomes the transcript.
        //
        // While Rich is silent the residual is BIT-IDENTICAL to the raw frame (see
        // `aec::tests::silence_from_rich_leaves_the_microphone_bit_identical`), so dictation
        // and call transcription are provably unaffected by this line.
        let mut buf = std::mem::take(&mut self.residual);
        buf.clear();
        buf.extend_from_slice(frame);
        let near_end = match self.aec.as_mut() {
            Some(aec) if buf.len() == crate::aec::AEC_BLOCK => Some(aec.process_block(&mut buf)),
            _ => None,
        };
        let confident = self.aec.as_ref().is_some_and(|a| a.confident());
        let msgs = self.push_residual(&buf, speaking, forced, near_end, confident, &mut out);
        self.residual = buf;
        let _ = msgs;
        out
    }

    /// The decision half, over the post-cancellation frame. Split out so the borrow of the
    /// scratch buffer is obvious and so tests can drive it directly.
    #[allow(clippy::too_many_arguments)]
    fn push_residual(
        &mut self,
        frame: &[f32],
        speaking: bool,
        forced: bool,
        near_end: Option<bool>,
        confident: bool,
        out: &mut Vec<CapMsg>,
    ) {
        let is_speech = self.vad.push_frame(frame);

        // COLLECTOR-PATH PARITY: `self.vad.last_rms()` is the RMS of THIS frame — the very
        // buffer handed to `self.recorder.push_frame` below and, from there, to whisper. The
        // silent-input verdict is therefore computed on the recorded audio itself and cannot
        // drift from what a real capture receives. (The echo gate has already run on it in
        // the callback, so it also reflects what STT actually gets, not what the device
        // handed over.) One transition, one message — never one per 16.000 ms frame.
        if self.noaudio.observe(self.vad.last_rms(), speaking) {
            out.push(CapMsg::NoAudio { silent: self.noaudio.no_audio() });
        }

        // The monitor only counts while Rich is audible: speech during his silence is an
        // ordinary utterance, not an interruption.
        if speaking != self.monitor.is_armed() {
            if speaking {
                self.monitor.arm();
            } else {
                self.monitor.disarm();
            }
        }

        // "Tap to stop" is AUTHORITATIVE and bypasses the debounce entirely. Routing it
        // through here (rather than only through the playout queue) is what clears the taint,
        // so the words the CEO is saying right now become the next turn instead of being
        // thrown away as echo.
        if forced {
            self.monitor.disarm();
        }

        // WHICH RULE IS IN FORCE. Driven by the canceller's own measurement of its residual
        // echo and by nothing else — never a setting, never a guess about headphones.
        self.monitor.set_aec_confident(confident);

        // WHAT COUNTS AS AN INTERRUPTION. With a confident canceller, require BOTH: the VAD
        // (which knows the room's adaptive noise floor) and the canceller's near-end verdict
        // (which knows how much residual echo to expect at this reference level). Requiring
        // both is what lets the debounce drop from 5.008 s to 0.400 s without Rich cutting
        // himself off. Without a confident canceller this is exactly the old behavior.
        let interrupting = match near_end {
            Some(n) if confident => is_speech && n,
            _ => is_speech,
        };

        if forced || self.monitor.push(interrupting) {
            self.barged = true;
            self.tainted = false;
            out.push(CapMsg::BargeIn { mid_utterance: self.recorder.is_recording() });
        }

        let finished = self.recorder.push_frame(frame, is_speech);
        let recording = self.recorder.is_recording();
        let started = recording && !self.was_recording;
        let stopped = !recording && self.was_recording;
        self.was_recording = recording;

        if started {
            // **THE TAINT RULE, now conditional.** With a confident canceller Rich's voice is
            // no longer meaningfully present in `frame` — it has been subtracted, and the
            // residual has been MEASURED 6 dB below the VAD's speech floor for 2.000 s. An
            // utterance beginning while he speaks is therefore the CEO starting a sentence,
            // not an echo of Rich's, and throwing it away is the bug rather than the fix.
            //
            // Whenever the canceller is not confident, this is byte-for-byte the old rule.
            self.tainted = speaking && !self.barged && !confident;
            out.push(CapMsg::Started { tainted: self.tainted });
        }

        if let Some(utterance) = finished {
            if self.tainted && !self.barged {
                out.push(CapMsg::Discarded { tainted: true });
            } else {
                out.push(CapMsg::Utterance(Box::new(utterance)));
            }
            self.tainted = false;
            self.barged = false;
        } else if stopped {
            // Recording ended without an utterance: too short to be a sentence (a cough, a
            // chair). Never reaches whisper, never reaches the CEO.
            out.push(CapMsg::Discarded { tainted: self.tainted });
            self.tainted = false;
            self.barged = false;
        } else if !speaking && !recording {
            // Rich has fallen silent and nothing is in flight: forget the interruption.
            self.barged = false;
        }
    }
}

/// A sentence handed to the speaker thread, tagged with the generation it belongs to so a
/// barge-in can invalidate work already in flight.
struct SpeakMsg {
    generation: u64,
    text: String,
}

struct Shared {
    /// Live input level 0..1, f32 bits. Written per frame by the audio thread.
    level: AtomicU32,
    /// True while Rich has audio queued — read by the audio thread to arm barge-in.
    speaking: AtomicBool,
    /// Bumped on every barge-in/stop. Synthesis for an older generation is discarded.
    generation: AtomicU64,
    /// The open stream is delivering nothing (see `noaudio.rs`). Owned by the supervisor,
    /// readable by the shell/tests without touching the audio thread.
    no_audio: AtomicBool,
    running: AtomicBool,
}

impl Shared {
    fn set_level(&self, v: f32) {
        self.level.store(v.to_bits(), Ordering::Relaxed);
    }
    fn level(&self) -> f32 {
        f32::from_bits(self.level.load(Ordering::Relaxed))
    }
}

/// Voice mode, running. Dropping it closes the microphone and silences Rich.
pub struct VoiceController {
    shared: Arc<Shared>,
    machine: Arc<Mutex<VoiceStateMachine>>,
    chunker: Mutex<SentenceChunker>,
    /// `Option` so `Drop` can close the channel BEFORE joining the speaker thread —
    /// joining first would deadlock on a `recv()` that can never fail.
    speak_tx: Option<Sender<SpeakMsg>>,
    playout: Arc<Playout>,
    force_barge: Arc<AtomicBool>,
    /// Bit 0: the echo canceller is confident. Bits 1..: whole-dB ERLE. Written once per
    /// audio frame by the capture thread.
    aec_state: Arc<AtomicU32>,
    diagnostics: Diagnostics,
    _capture: Capture,
    threads: Vec<std::thread::JoinHandle<()>>,
}

/// Consecutive utterances that come back as whisper noise before the CEO is told.
///
/// **THE FLOOR THIS PUTS UNDER THE NOTICE, derived rather than felt.** An utterance only
/// reaches whisper at all after [`crate::endpoint::MIN_SPEECH_FRAMES`] of speech and
/// [`crate::endpoint::SILENCE_HANGOVER_FRAMES`] of silence to close it:
///
/// ```text
///   minimum speech   19 x 256 / 16000 = 0.304 s
///   silence hangover 50 x 256 / 16000 = 0.800 s
///   one utterance                    >= 1.104 s
///   three in a row                   >= 3.312 s   (+ whisper, measured 0.47-0.74 s each)
/// ```
///
/// So this cannot fire on a cough, a chair or a single stray word, and it CAN fire well
/// inside the 25+ seconds of silent "listening…" measured on published v1.0.0 on
/// 2026-09-04 — roughly seven times over. Three is the smallest number with both
/// properties; `endpoint.rs`'s own test asserts the two frame counts it rests on.
pub const SILENT_DISCARD_RUN: u32 = 3;

/// **WHAT VOICE MODE REPORTS THAT IS NOT AN ERROR.**
///
/// `SttError`, `CaptureError` and `PlayoutError` all carry a `ceo_message`, and every one of
/// them is a thing that FAILED. This is the other kind: nothing failed, the pipeline is
/// working exactly as specified, and the CEO still needs to be told something — which is
/// precisely the condition that shipped silent.
///
/// **The method is called `ceo_message` for a second reason, and it is not decoration.**
/// `app/ui/tests/lib/state-strings.js` scrapes the product's CEO-facing sentences out of
/// source, and under `app/crates` the only shape it can see is a literal inside a function
/// with that name (`state-strings.js:469`). A sentence the state registry cannot see is a
/// sentence nobody has said whether the CEO can act on — the exact defect that left
/// `LORO_DESK_ABSENT_MESSAGE` invisible and two suites red for a day.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VoiceNotice {
    /// Three utterances in a row came back as whisper's documented silence noise. The
    /// microphone is open, the level meter is moving and `noaudio.rs` is satisfied that
    /// signal is arriving, so nothing else in this pipeline has anything to report.
    ///
    /// **Its meaning NARROWED on 2026-09-05 and is better for it.** Since
    /// [`crate::voiced::VoiceEvidence`] now refuses voiceless audio before whisper is ever
    /// called, an utterance that reaches this notice has already been measured to contain a
    /// human voice. So it no longer means "the room is noisy"; it means the CEO really did
    /// speak and the recognizer still got no words out of it.
    SoundButNoWords,
    /// **The recording carried no voice, so nothing was sent.** Raised by the audio-grounded
    /// gate in [`crate::voiced`], before the recognizer runs — see [`RecognizerDesk`].
    ///
    /// This is the refusal that the CEO has to be told about, because a silent drop is its
    /// own kind of lying: he tapped the talk button, something happened, and if the app says
    /// nothing he cannot tell "it ignored me" from "it is still listening".
    ///
    /// **It is latched per RUN of refusals, and that is a judgment worth stating.** An open
    /// mic in a quiet room can produce one voiceless utterance every ~1.104 s, and a line
    /// per refusal would be a drip that trains him to ignore the one that matters. So the
    /// first refusal says it, consecutive refusals are stderr only, and the latch clears the
    /// moment an utterance is admitted — because that proves the input recovered.
    HeardNoVoice,
    /// **RICH WAS CUT OFF MID-ANSWER AND STOPPED, and until 2026-09-05 nothing said so.**
    ///
    /// `open-items.md` row 3.30: *"A voice turn cut mid-sentence needs to say so audibly,
    /// not fail silent. The CEO is speaking to a system that has stopped listening and does
    /// not know it."*
    ///
    /// **The failure is precise, and it is worse than silence.** On `rich://turn-error` the
    /// shell called `voice_speak_end`, which FLUSHES the chunker's tail — so a turn that
    /// died mid-sentence spoke its half-sentence aloud, trailed off, and then said nothing
    /// at all. The CEO hears Rich stop in the middle of a word and has no way to tell that
    /// from thinking.
    ///
    /// **It is the only notice in this enum that is SPOKEN as well as shown**, and that is
    /// the whole requirement rather than a flourish: in voice mode his eyes are not on the
    /// panel. `SoundButNoWords` and `HeardNoVoice` both describe the microphone, which he
    /// discovers by the app not answering; this one describes the ANSWER, which he is in
    /// the middle of listening to.
    ///
    /// **It names no control and offers no retry**, for the reason the other two give: the
    /// affordance for asking again is the open microphone, there is no button to point at,
    /// and an imperative with no control is a request wearing a status's clothes.
    ReplyCutOff,
}

impl VoiceNotice {
    /// The CEO-facing line. No path, no device name, no decibel figure — the operator's
    /// `eprintln` beside the discard carries the transcript that was thrown away, and this
    /// carries the sentence.
    ///
    /// It states what is true, names the thing that is usually wrong, and INVENTS NO
    /// CONTROL: the ◉ that ends voice is already on screen with its own footnote two lines
    /// below this notice, so a sentence pointing at it would be a request wearing a status's
    /// clothes. It does not offer to switch voice off either — doing that to the CEO
    /// mid-sentence is not a decision this file gets to make.
    pub fn ceo_message(&self) -> &'static str {
        match self {
            VoiceNotice::SoundButNoWords => {
                "I can hear sound, but I'm not getting words out of it — the microphone may \
                 be picking up the room rather than you. Voice is still on."
            }
            // STATES THE CONSEQUENCE, not just the observation. "I didn't catch that"
            // leaves open whether something was sent anyway, and the whole defect being
            // fixed here is the app sending a sentence he never said — so the line has to
            // close that question, in his own words, before anything else.
            //
            // IT ENDS WITH A STATUS AND NOT AN INSTRUCTION, deliberately. "Say it again"
            // is an imperative aimed at the reader, which makes it a request wearing a
            // status's clothes: the affordance for saying it again is the open microphone,
            // and there is no button to point at. So it says the mic is still open and
            // leaves the next move where it belongs. Same discipline as `SoundButNoWords`
            // above, whose last three words are "Voice is still on."
            VoiceNotice::HeardNoVoice => {
                "That didn't come through as speech, so I haven't sent anything. I'm still \
                 listening."
            }
            // IT SAYS THE ANSWER STOPPED, not that "something went wrong". The CEO is
            // listening, not reading, and the fact he needs first is that what he heard is
            // all there is — otherwise he waits for a sentence that is never coming.
            //
            // IT ENDS WITH A STATUS, like the two above: the microphone is still open, and
            // saying so is what tells him he can simply ask again. The REASON is a separate
            // sentence supplied by the caller, because voice does not know a 529 from a
            // broken pipe and inventing a cause here would be worse than naming none.
            VoiceNotice::ReplyCutOff => {
                "I was cut off partway through that answer, so what you heard is all I got \
                 out. I'm still listening."
            }
        }
    }
}

/// **WHAT VOICE MODE DOES WHEN THE ANSWER IT IS SPEAKING DIES** — row 3.30's first answer.
///
/// A struct, not three lines inside [`VoiceController::turn_cut_off`], for exactly the
/// reason [`RecognizerDesk`] is one: the thing that has to be provable here is not *what*
/// is said but *where it goes*. The defect is that the notice reaches the panel and not the
/// speaker, and a test that only inspected a `VoiceEvent` would pass over it forever. So
/// `handle` takes the SPEAK sink as a parameter and `controller::tests` asserts the sentence
/// arrived in both.
///
/// ## THE ORDER IS THE DESIGN, AND IT IS NOT INTERCHANGEABLE
///
/// 1. **Drop the dangling fragment.** The chunker holds whatever arrived after the last
///    sentence boundary — half a sentence that will never be completed, because the lease
///    that was writing it is gone. Until 2026-09-05 the shell called `voice_speak_end` here,
///    which FLUSHES that fragment: Rich spoke half a sentence aloud, trailed off, and said
///    nothing else. That is worse than silence, because trailing off is what a person does
///    while thinking.
/// 2. **Then say the notice**, appended AFTER whatever is already queued rather than
///    replacing it. The sentences Rich already completed are real answer and the CEO is
///    entitled to hear them finish; the generation counter is deliberately NOT bumped and
///    playout is deliberately NOT stopped. Silencing them in order to announce a cut-off
///    would destroy the thing being announced.
/// 3. **Then the reason, if the caller has one.** Voice cannot tell a `529` from a broken
///    pipe and does not try: `richos-core`'s `upstream.rs` classifies, and whatever sentence
///    it authored is spoken after this one. A `None` reason costs nothing — the notice
///    already carries the fact that matters.
///
/// It is latched per turn by the caller holding it, so a turn that produces two terminal
/// events cannot say this twice.
pub struct CutOffDesk;

impl CutOffDesk {
    /// Announce one cut-off. `speak` queues a sentence for the speaker thread; `observer`
    /// gets the same words for the panel.
    ///
    /// **Both, always, and neither is optional.** The panel alone is the defect this exists
    /// to end — in voice mode his eyes are not on it. The speaker alone would leave nothing
    /// on screen for him to read back afterwards, and the screen is where the REASON is
    /// legible (a request id is unspeakable).
    pub fn handle<S>(reason: Option<&str>, observer: &dyn VoiceObserver, mut speak: S)
    where
        S: FnMut(&str),
    {
        let notice = VoiceNotice::ReplyCutOff.ceo_message();
        speak(notice);
        // The reason is SPOKEN too, after the notice, when there is one. It is one sentence
        // of plain English authored by `upstream.rs` for exactly this purpose; the operator
        // detail (request ids, HTTP statuses) never travels on this path, because a spoken
        // `req_011Cegb417YK6i1BEVDFmzU1` is noise with a syllable count.
        if let Some(r) = reason.map(str::trim).filter(|r| !r.is_empty()) {
            speak(r);
        }
        // The panel gets the whole statement in one line, because a screen reads at once.
        let shown = match reason.map(str::trim).filter(|r| !r.is_empty()) {
            Some(r) => format!("{notice} {r}"),
            None => notice.to_string(),
        };
        observer.on_voice_event(&VoiceEvent::Error { message: shown, at: now_millis() });
    }
}

/// **THE ONE PLACE A RECOGNIZED UTTERANCE CAN BECOME A TURN — and the order it happens in.**
///
/// The recognizer thread used to be a `while let` with the whole decision inlined, and the
/// decision was: run whisper, then ask [`stt::is_meaningful`] whether the TEXT looked like
/// something. That is a text heuristic over a ten-phrase list, and on 2026-09-04 it let
/// *"1, 2, 3, testing."* through from a silent room on the CEO's own Mac, into his own
/// ledger, under his own name (`ray-opus-a2`, published v1.0.1). No list of phrases can fix
/// that, because the sentence is indistinguishable AS TEXT from one a person would say.
///
/// So the decision is now made on the AUDIO, and it is made FIRST:
///
/// 1. [`VoiceEvidence::measure`] asks whether the recording carried a voice.
/// 2. If it did not, this returns. **Whisper is never called**, so no transcript exists to
///    be submitted, mis-filtered or logged. The failure direction is silence by construction
///    rather than by care.
/// 3. Only then does the recognizer run, and only then can `submit` be reached.
///
/// It is a struct rather than a closure so the ORDER is something a test can hold: `handle`
/// takes the transcriber as a parameter, and `controller::tests` passes one that PANICS if
/// it is ever called. "Refused audio never reaches whisper" is therefore proven, not
/// asserted — the same reason [`CaptureBrain`] was split out of the audio callback.
pub struct RecognizerDesk {
    /// Consecutive transcripts rejected by [`stt::is_meaningful`] — see [`SILENT_DISCARD_RUN`].
    discards: u32,
    /// [`VoiceNotice::SoundButNoWords`] has been said this run.
    said_sound_but_no_words: bool,
    /// [`VoiceNotice::HeardNoVoice`] has been said this run.
    said_heard_no_voice: bool,
}

impl Default for RecognizerDesk {
    fn default() -> Self {
        RecognizerDesk::new()
    }
}

impl RecognizerDesk {
    pub fn new() -> RecognizerDesk {
        RecognizerDesk { discards: 0, said_sound_but_no_words: false, said_heard_no_voice: false }
    }

    /// Decide one finished utterance.
    ///
    /// `transcribe` is only ever called for audio that has already been measured to carry a
    /// voice. `submit` is only ever called for a transcript that survived both that gate and
    /// the narrow noise-phrase filter, and it is the SAME path typed text takes.
    pub fn handle<T, S>(
        &mut self,
        utterance: &Utterance,
        observer: &dyn VoiceObserver,
        transcribe: T,
        submit: S,
    ) where
        T: FnOnce(&[f32]) -> Result<(String, u64), stt::SttError>,
        S: FnOnce(String),
    {
        let duration_ms = (utterance.duration_secs() * 1000.0) as u64;

        // ---- 1. THE AUDIO, BEFORE ANY TRANSCRIPT EXISTS ---------------------------------
        let evidence = VoiceEvidence::measure(&utterance.samples);
        if !evidence.carried_speech() {
            // The operator gets the measurement; the CEO gets the sentence. Neither gets a
            // transcript, because none was produced.
            eprintln!(
                "[richos-voice] refused before recognition — the audio carried no voice: {}",
                evidence.summary()
            );
            if !self.said_heard_no_voice {
                self.said_heard_no_voice = true;
                observer.on_voice_event(&VoiceEvent::Error {
                    message: VoiceNotice::HeardNoVoice.ceo_message().to_string(),
                    at: now_millis(),
                });
            }
            return;
        }
        // A voice was measured. Whatever happens to the words, the room is working.
        self.said_heard_no_voice = false;

        // ---- 2. ONLY NOW DOES WHISPER EXIST ----------------------------------------------
        match transcribe(&utterance.samples) {
            Ok((text, latency_ms)) => {
                if !stt::is_meaningful(&text) {
                    eprintln!("[richos-voice] discarded non-speech transcript: {text:?}");
                    self.discards += 1;
                    if self.discards >= SILENT_DISCARD_RUN && !self.said_sound_but_no_words {
                        self.said_sound_but_no_words = true;
                        observer.on_voice_event(&VoiceEvent::Error {
                            message: VoiceNotice::SoundButNoWords.ceo_message().to_string(),
                            at: now_millis(),
                        });
                    }
                    return;
                }
                self.discards = 0;
                self.said_sound_but_no_words = false;
                observer.on_voice_event(&VoiceEvent::Transcript {
                    text: text.clone(),
                    duration_ms,
                    latency_ms,
                    at: now_millis(),
                });
                submit(text);
            }
            Err(e) => {
                eprintln!("[richos-voice] stt failed: {e}");
                observer.on_voice_event(&VoiceEvent::Error {
                    message: e.ceo_message(),
                    at: now_millis(),
                });
            }
        }
    }
}

impl VoiceController {
    /// Bring voice mode up. Every external dependency is resolved HERE, so a missing model or
    /// a missing microphone is one calm message at the toggle rather than a failure in the
    /// middle of a sentence.
    ///
    /// `submit` receives each recognized utterance and is expected to run a spine turn with
    /// it — the SAME path typed text takes. It is called on a dedicated thread and may block
    /// for the whole turn.
    pub fn start(
        opts: VoiceOptions,
        observer: Arc<dyn VoiceObserver>,
        submit: Arc<dyn Fn(String) + Send + Sync>,
    ) -> Result<VoiceController, VoiceStartError> {
        let recognizer = Recognizer::resolve().map_err(VoiceStartError::Stt)?;

        // The echo canceller and the lock-free ring that feeds it. The ring goes to the
        // OUTPUT callback; the canceller itself is owned outright by the capture path (inside
        // `CaptureBrain`), so neither audio thread ever takes a lock to move the reference.
        let (aec, reference_ring) = EchoCanceller::new();
        let playout =
            Arc::new(Playout::start(Some(reference_ring)).map_err(VoiceStartError::Playout)?);
        let synth: Arc<dyn SpeechSynth> = Arc::new(MacSay::new());

        let shared = Arc::new(Shared {
            level: AtomicU32::new(0),
            speaking: AtomicBool::new(false),
            generation: AtomicU64::new(0),
            no_audio: AtomicBool::new(false),
            running: AtomicBool::new(true),
        });
        let machine = Arc::new(Mutex::new(VoiceStateMachine::new()));
        machine.lock().unwrap().start();

        let (cap_tx, cap_rx) = channel::<CapMsg>();
        let (speak_tx, speak_rx) = channel::<SpeakMsg>();
        let (utt_tx, utt_rx) = channel::<Box<Utterance>>();
        let (submit_tx, submit_rx) = channel::<String>();
        let force_barge = Arc::new(AtomicBool::new(false));
        // Bit 0: the canceller is confident. Bits 1..: whole-dB ERLE. One relaxed store per
        // frame from the audio thread, readable by anyone without a lock.
        let aec_state_for_diagnostics = Arc::new(AtomicU32::new(0));
        let aec_state_read = aec_state_for_diagnostics.clone();

        // ---- the audio capture callback ------------------------------------------------
        // A THIN adapter over CaptureBrain: no locks, no allocation beyond the frame copy the
        // echo gate needs, and no UI events. All the decisions live in CaptureBrain, which is
        // unit-tested as a whole (tests/barge_in_composition.rs).
        let cb_shared = shared.clone();
        let cb_force = force_barge.clone();
        // The canceller moves INTO the brain, which moves into the callback closure. No locks
        // on the audio thread, and the echo cancellation, the VAD, the barge-in monitor and
        // the endpointer are one composed unit that `tests/barge_in_composition.rs` can drive.
        let mut brain = CaptureBrain::with_aec(aec);
        let aec_state = aec_state_for_diagnostics.clone();

        let capture = capture::start(&opts.source, move |frame| {
            let speaking = cb_shared.speaking.load(Ordering::Relaxed);
            let forced = cb_force.swap(false, Ordering::Relaxed);
            for msg in brain.push_frame(frame, speaking, forced) {
                let _ = cap_tx.send(msg);
            }
            cb_shared.set_level(brain.level());
            // Publish the canceller's live state for the supervisor and the UI without ever
            // touching the audio thread from outside it.
            aec_state.store(
                (brain.aec_confident() as u32) | ((brain.aec_metrics().map(|m| m.erle_db).unwrap_or(0.0).max(0.0) as u32) << 1),
                Ordering::Relaxed,
            );
        })
        .map_err(VoiceStartError::Capture)?;

        let diagnostics = Diagnostics {
            input_source: capture.source_label.clone(),
            input_rate: capture.input_rate,
            input_channels: capture.input_channels,
            output_device: playout.device_label.clone(),
            output_rate: playout.device_rate,
            output_channels: playout.channels,
            stt_model: recognizer.model_id().to_string(),
            stt_binary: recognizer.binary_path().display().to_string(),
            tts_voice: synth.voice_label(),
            echo_gate: format!(
                "PBFDAF {} taps ({:.0} ms tail)",
                crate::aec::AEC_TAPS,
                1000.0 * crate::aec::filter_tail_secs()
            ),
            echo_cancellation: true,
            // The debounce reported here is the one in force AT START — the fallback. It
            // shortens to 0.400 s only once the canceller earns it, which cannot have happened
            // yet: `confident()` needs 2.000 s of Rich actually speaking plus a 2.000 s hold.
            barge_in_frames: BARGE_IN_DEBOUNCE_FRAMES,
            barge_in_secs: frames_to_secs(BARGE_IN_DEBOUNCE_FRAMES),
        };
        eprintln!("[richos-voice] {}", diagnostics.summary());

        let mut threads = Vec::new();

        // ---- recognizer thread ----------------------------------------------------------
        {
            let observer = observer.clone();
            let scratch = opts.scratch_dir.clone();
            let submit_tx = submit_tx.clone();
            threads.push(std::thread::spawn(move || {
                // THE WHOLE DECISION LIVES IN `RecognizerDesk`, deliberately.
                //
                // This thread used to hold it inline: transcribe, then judge the TEXT. That
                // shape is what let *"1, 2, 3, testing."* be submitted as the CEO's own
                // message from a silent room on 2026-09-04. The desk asks the AUDIO first
                // and only reaches whisper if the recording earned it, and it is a separate
                // type so that ordering is testable rather than merely visible.
                let mut desk = RecognizerDesk::new();
                while let Ok(utterance) = utt_rx.recv() {
                    desk.handle(
                        &utterance,
                        observer.as_ref(),
                        |samples| recognizer.transcribe(samples, &scratch),
                        |text| {
                            let _ = submit_tx.send(text);
                        },
                    );
                }
            }));
        }

        // ---- submit thread (one turn at a time, in order) --------------------------------
        threads.push(std::thread::spawn(move || {
            while let Ok(text) = submit_rx.recv() {
                submit(text);
            }
        }));

        // ---- speaker thread --------------------------------------------------------------
        {
            let shared = shared.clone();
            let playout = playout.clone();
            let scratch = opts.scratch_dir.clone();
            let observer = observer.clone();
            threads.push(std::thread::spawn(move || {
                while let Ok(msg) = speak_rx.recv() {
                    // Dropped before we start: a barge-in already invalidated this sentence.
                    if msg.generation != shared.generation.load(Ordering::Relaxed) {
                        continue;
                    }
                    match synth.synthesize(&msg.text, playout.device_rate, &scratch) {
                        Ok(speech) => {
                            // Synthesis took real time; check again before making a sound.
                            if msg.generation != shared.generation.load(Ordering::Relaxed) {
                                continue;
                            }
                            playout.queue(&speech.samples);
                        }
                        Err(e) => {
                            eprintln!("[richos-voice] tts failed: {e}");
                            observer.on_voice_event(&VoiceEvent::Error {
                                message: e.ceo_message(),
                                at: now_millis(),
                            });
                        }
                    }
                }
            }));
        }

        // ---- supervisor: the ONLY place UI events are emitted -----------------------------
        {
            let shared = shared.clone();
            let machine = machine.clone();
            let playout = playout.clone();
            let observer = observer.clone();
            threads.push(std::thread::spawn(move || {
                supervise(shared, machine, playout, observer, cap_rx, utt_tx);
            }));
        }

        Ok(VoiceController {
            shared,
            machine,
            chunker: Mutex::new(SentenceChunker::new()),
            speak_tx: Some(speak_tx),
            playout,
            force_barge,
            aec_state: aec_state_read,
            diagnostics,
            _capture: capture,
            threads,
        })
    }

    pub fn state(&self) -> VoiceState {
        self.machine.lock().map(|m| m.state()).unwrap_or(VoiceState::Off)
    }

    pub fn diagnostics(&self) -> &Diagnostics {
        &self.diagnostics
    }

    /// **Has the echo canceller earned the short barge-in window yet?**
    ///
    /// False at start-up and for the first few seconds of Rich actually speaking, because
    /// `EchoCanceller::confident` requires 2.000 s of far-end audio to learn the path plus a
    /// 2.000 s hold. While it is false the CEO needs the 5.008 s talk-over or the "tap to
    /// stop" control, exactly as before; once it is true a 0.400 s interruption registers.
    ///
    /// The UI's "headphones recommended" note should follow THIS, not `Diagnostics`.
    pub fn echo_cancellation_confident(&self) -> bool {
        self.aec_state.load(Ordering::Relaxed) & 1 == 1
    }

    /// Live Echo Return Loss Enhancement in whole dB — how much of Rich's own voice the
    /// canceller is currently removing from the microphone. 0 until it has something to
    /// report. Measured, never estimated.
    pub fn echo_return_loss_enhancement_db(&self) -> u32 {
        self.aec_state.load(Ordering::Relaxed) >> 1
    }

    /// The barge-in debounce actually in force right now, in seconds: 5.008 while the
    /// canceller is unconfident, 0.400 once it is.
    pub fn barge_in_secs_now(&self) -> f32 {
        if self.echo_cancellation_confident() {
            crate::bargein::aec_barge_in_window_secs()
        } else {
            crate::bargein::barge_in_debounce_secs()
        }
    }

    /// The mic is open and healthy but has delivered nothing above -80.00 dBFS for 3.008 s.
    /// The UI reads this off `rich://voice-state`; this accessor exists for the live
    /// hardware check and for the shell's diagnostics.
    pub fn no_audio(&self) -> bool {
        self.shared.no_audio.load(Ordering::Relaxed)
    }

    /// A `rich://chunk` delta arrived. Accumulate, and hand every completed sentence to the
    /// speaker thread immediately — this is the pipelining.
    pub fn speak_delta(&self, delta: &str) {
        let generation = self.shared.generation.load(Ordering::Relaxed);
        let sentences = match self.chunker.lock() {
            Ok(mut c) => c.push(delta),
            Err(_) => return,
        };
        if let Some(tx) = &self.speak_tx {
            for text in sentences {
                let _ = tx.send(SpeakMsg { generation, text });
            }
        }
    }

    /// The turn's terminal event arrived: speak whatever is left.
    pub fn speak_end(&self) {
        let generation = self.shared.generation.load(Ordering::Relaxed);
        let tail = match self.chunker.lock() {
            Ok(mut c) => c.flush(),
            Err(_) => None,
        };
        if let (Some(tx), Some(text)) = (&self.speak_tx, tail) {
            let _ = tx.send(SpeakMsg { generation, text });
        }
    }

    /// **The turn DIED. Say so out loud** (row 3.30, answer 1).
    ///
    /// The counterpart to [`VoiceController::speak_end`], and it must never be that
    /// function: `speak_end` FLUSHES the chunker's tail, so calling it on a turn that died
    /// mid-sentence speaks the half-sentence and then falls silent. This drops the fragment
    /// and speaks [`VoiceNotice::ReplyCutOff`] instead.
    ///
    /// `reason` is one plain sentence from whoever knows why — `richos-core`'s
    /// `upstream::UpstreamFault::ceo_message` for a `529` or a `429`. `None` is fine and
    /// common; voice never invents one.
    ///
    /// **Nothing already queued is stopped.** The generation counter is not bumped and
    /// `playout.stop_now()` is not called, so completed sentences finish and the notice
    /// follows them. See [`CutOffDesk`] for why that order is the design.
    pub fn turn_cut_off(&self, reason: Option<&str>, observer: &dyn VoiceObserver) {
        // 1. The fragment that will never be finished.
        if let Ok(mut c) = self.chunker.lock() {
            c.reset();
        }
        // 2. and 3. — the decision itself, in the unit-tested desk.
        let generation = self.shared.generation.load(Ordering::Relaxed);
        let tx = self.speak_tx.clone();
        CutOffDesk::handle(reason, observer, |text| {
            if let Some(tx) = &tx {
                let _ = tx.send(SpeakMsg { generation, text: text.to_string() });
            }
        });
        // 4. The state machine last: the turn is over whatever the speaker does with the
        //    sentences, and `turn_ended` is what puts the panel back to listening.
        if let Ok(mut m) = self.machine.lock() {
            m.turn_ended();
        }
    }

    /// `rich://turn-started` — Rich has the turn.
    pub fn turn_started(&self) {
        if let Ok(mut m) = self.machine.lock() {
            m.turn_started();
        }
        if let Ok(mut c) = self.chunker.lock() {
            c.reset();
        }
    }

    /// A terminal turn event. Rich may still be speaking the tail.
    pub fn turn_ended(&self) {
        if let Ok(mut m) = self.machine.lock() {
            m.turn_ended();
        }
    }

    /// The UI's "tap to stop": interrupt Rich right now, no debounce. Returns the number of
    /// mono samples dropped — real units, not an adjective.
    pub fn force_barge_in(&self) -> usize {
        self.force_barge.store(true, Ordering::Relaxed);
        self.shared.generation.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut c) = self.chunker.lock() {
            c.reset();
        }
        let dropped = self.playout.stop_now();
        if let Ok(mut m) = self.machine.lock() {
            m.barge_in();
        }
        dropped
    }

    /// Worst-case delay between an interruption and silence: one device callback period.
    pub fn stop_latency_secs(&self) -> f32 {
        self.playout.stop_latency_secs()
    }

    pub fn queued_speech_secs(&self) -> f32 {
        self.playout.queued_secs()
    }
}

impl Drop for VoiceController {
    fn drop(&mut self) {
        self.shared.running.store(false, Ordering::SeqCst);
        // Silence Rich immediately, then let the channels close and the threads finish.
        self.playout.stop_now();
        self.shared.generation.fetch_add(1, Ordering::SeqCst);
        if let Ok(mut m) = self.machine.lock() {
            m.stop();
        }
        // Close the speaker channel first: the speaker thread blocks on recv() and can only
        // exit when every sender is gone. Joining before this would deadlock.
        self.speak_tx.take();
        for t in self.threads.drain(..) {
            let _ = t.join();
        }
    }
}

/// The supervisor loop: owns the state machine, emits every UI event, dispatches work.
fn supervise(
    shared: Arc<Shared>,
    machine: Arc<Mutex<VoiceStateMachine>>,
    playout: Arc<Playout>,
    observer: Arc<dyn VoiceObserver>,
    cap_rx: Receiver<CapMsg>,
    utt_tx: Sender<Box<Utterance>>,
) {
    let mut last_state = VoiceState::Off;
    let mut last_level_emit = Instant::now() - LEVEL_EMIT_EVERY;
    let mut last_level = -1.0f32;
    let mut no_audio = false;
    let mut no_audio_changed = false;

    while shared.running.load(Ordering::SeqCst) {
        // 1. Drain the audio thread's messages.
        loop {
            match cap_rx.try_recv() {
                Ok(CapMsg::Started { tainted }) => {
                    if !tainted {
                        if let Ok(mut m) = machine.lock() {
                            m.utterance_started();
                        }
                    }
                }
                Ok(CapMsg::Utterance(u)) => {
                    if let Ok(mut m) = machine.lock() {
                        m.utterance_ended();
                    }
                    let _ = utt_tx.send(u);
                }
                Ok(CapMsg::Discarded { tainted }) => {
                    if let Ok(mut m) = machine.lock() {
                        m.utterance_ended();
                    }
                    if tainted {
                        eprintln!("[richos-voice] discarded audio captured while Rich was speaking (no AEC)");
                    }
                }
                Ok(CapMsg::NoAudio { silent }) => {
                    shared.no_audio.store(silent, Ordering::Relaxed);
                    no_audio = silent;
                    no_audio_changed = true;
                    if silent {
                        eprintln!(
                            "[richos-voice] input silent: nothing above {:.2} dBFS for {:.3} s on an OPEN stream - muted mic, gain at zero, or a denied permission",
                            crate::noaudio::dbfs(crate::noaudio::SILENCE_RMS),
                            no_audio_window_secs()
                        );
                    } else {
                        eprintln!("[richos-voice] input is live again");
                    }
                }
                Ok(CapMsg::BargeIn { mid_utterance }) => {
                    let dropped = playout.stop_now();
                    shared.generation.fetch_add(1, Ordering::Relaxed);
                    shared.speaking.store(false, Ordering::Relaxed);
                    if let Ok(mut m) = machine.lock() {
                        m.barge_in();
                        if !mid_utterance {
                            // He cut Rich off without saying anything — there is no utterance
                            // to end, so clear `hearing` now or the panel sits in it forever.
                            m.utterance_ended();
                        }
                    }
                    eprintln!(
                        "[richos-voice] barge-in: cut Rich, dropped {dropped} samples ({:.3} s of queued speech)",
                        dropped as f32 / playout.device_rate.max(1) as f32
                    );
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => return,
            }
        }

        // 2. Reconcile playout with the state machine. The queue is the ground truth for
        //    "is Rich audible", not the turn state.
        let playing = playout.is_playing();
        shared.speaking.store(playing, Ordering::Relaxed);
        if let Ok(mut m) = machine.lock() {
            if playing {
                m.playout_started();
            } else {
                m.playout_drained();
            }
        }

        // 3. Emit. State changes always; level at most 10 Hz and only when it moved.
        let state = machine.lock().map(|m| m.state()).unwrap_or(VoiceState::Off);
        let armed = machine.lock().map(|m| m.barge_in_armed()).unwrap_or(false);
        let level = if state.mic_is_hot() { shared.level() } else { 0.0 };
        let state_changed = state != last_state;
        let level_due = last_level_emit.elapsed() >= LEVEL_EMIT_EVERY && (level - last_level).abs() > 0.02;
        // A dead input holds the level at 0.0 and the state at Listening, so NEITHER of the
        // two existing emit triggers would ever fire - the warning would be computed and
        // never delivered. The transition is its own trigger.
        if state_changed || level_due || no_audio_changed {
            observer.on_voice_event(&VoiceEvent::State {
                state,
                level,
                barge_in_armed: armed,
                no_audio,
                at: now_millis(),
            });
            last_state = state;
            last_level = level;
            last_level_emit = Instant::now();
            no_audio_changed = false;
        }

        std::thread::sleep(TICK);
    }

    // Voice mode is off: say so once, unambiguously. A stale "listening" left on screen
    // would be a lie about a hot mic.
    observer.on_voice_event(&VoiceEvent::State {
        state: VoiceState::Off,
        level: 0.0,
        barge_in_armed: false,
        no_audio: false,
        at: now_millis(),
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::endpoint::EndReason;
    use crate::voiced::fixtures::{framed, hiss, silence, steady_tone, synthetic_voice};

    /// Wrap a buffer as a finished utterance. `speech_frames`/`total_frames` are set to what
    /// the endpointer WOULD have counted — deliberately generous, because the point of these
    /// tests is that the desk does not trust that count. It was the count being wrong that
    /// put words in the CEO's mouth.
    fn utterance(samples: Vec<f32>) -> Utterance {
        let total = (samples.len() / crate::vad::VAD_FRAME_SAMPLES) as u32;
        Utterance {
            samples,
            reason: EndReason::Silence,
            speech_frames: total,
            total_frames: total,
        }
    }

    fn messages(rec: &Recorder) -> Vec<String> {
        rec.events
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| match e {
                VoiceEvent::Error { message, .. } => Some(message.clone()),
                _ => None,
            })
            .collect()
    }

    fn transcripts(rec: &Recorder) -> Vec<String> {
        rec.events
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| match e {
                VoiceEvent::Transcript { text, .. } => Some(text.clone()),
                _ => None,
            })
            .collect()
    }

    /// INVARIANT — **THE ONE THIS WHOLE CHANGE EXISTS FOR.** Audio that carried no voice
    /// never reaches the recognizer, so there is no transcript to submit, however plausible
    /// whisper would have made it sound. The transcriber PANICS if it is called: this is a
    /// proof of ordering, not an assertion about it.
    #[test]
    fn audio_that_carried_no_voice_never_reaches_whisper_and_never_becomes_a_turn() {
        for (what, audio) in [
            ("digital silence", silence(3.0)),
            ("a quiet room at the VAD's own floor", hiss(3.0, -46.0, 7)),
            ("a room 18 dB above it", hiss(3.0, -28.0, 9)),
            ("a fan", steady_tone(3.0, -40.0)),
        ] {
            let rec = Recorder::default();
            let mut desk = RecognizerDesk::new();
            desk.handle(
                &utterance(audio),
                &rec,
                |_| panic!("{what} reached whisper — the gate is not in front of it"),
                |t| panic!("{what} was submitted as the CEO's message: {t:?}"),
            );
            assert!(transcripts(&rec).is_empty(), "{what} produced a transcript event");
            assert_eq!(
                messages(&rec),
                vec![VoiceNotice::HeardNoVoice.ceo_message().to_string()],
                "{what} was dropped silently — a silent drop is its own kind of lying"
            );
        }
    }

    /// INVARIANT: a voice DOES get through, all the way to `submit`. Without this the suite
    /// above would pass by refusing everything, which is the false green this repository has
    /// been bitten by repeatedly.
    #[test]
    fn a_voice_reaches_whisper_and_is_submitted_as_a_turn() {
        let rec = Recorder::default();
        let mut desk = RecognizerDesk::new();
        let sent = Mutex::new(Vec::<String>::new());
        let saw_whisper = std::sync::atomic::AtomicBool::new(false);
        desk.handle(
            &utterance(framed(synthetic_voice(1.5, 190.0, 130.0, -26.0), -55.0, 3)),
            &rec,
            |samples| {
                saw_whisper.store(true, Ordering::Relaxed);
                assert!(!samples.is_empty(), "whisper was handed nothing");
                Ok(("Renegotiate Acme and get me the number by Thursday.".to_string(), 470))
            },
            |t| sent.lock().unwrap().push(t),
        );
        assert!(saw_whisper.load(Ordering::Relaxed), "a real voice never reached whisper");
        assert_eq!(
            sent.into_inner().unwrap(),
            vec!["Renegotiate Acme and get me the number by Thursday.".to_string()]
        );
        assert_eq!(transcripts(&rec).len(), 1, "the CEO's own words must appear in the thread");
        assert!(messages(&rec).is_empty(), "a working turn raised a notice");
    }

    /// INVARIANT: a ONE-WORD decision still gets through. `stt.rs` keeps its noise list
    /// narrow precisely so "Yes." survives; an audio gate that swallowed it would have
    /// undone that from the other side.
    #[test]
    fn a_one_word_decision_still_reaches_the_spine() {
        let rec = Recorder::default();
        let mut desk = RecognizerDesk::new();
        let sent = Mutex::new(Vec::<String>::new());
        desk.handle(
            &utterance(framed(synthetic_voice(0.30, 210.0, 150.0, -26.0), -55.0, 5)),
            &rec,
            |_| Ok(("Yes.".to_string(), 320)),
            |t| sent.lock().unwrap().push(t),
        );
        assert_eq!(sent.into_inner().unwrap(), vec!["Yes.".to_string()]);
    }

    /// INVARIANT: the audio gate is added IN FRONT of the noise-phrase filter, not instead
    /// of it. A real voice whose transcript comes back as whisper's silence noise is still
    /// discarded, and still never submitted.
    #[test]
    fn the_noise_phrase_filter_still_applies_to_audio_that_did_carry_a_voice() {
        let rec = Recorder::default();
        let mut desk = RecognizerDesk::new();
        desk.handle(
            &utterance(framed(synthetic_voice(1.2, 190.0, 130.0, -26.0), -55.0, 11)),
            &rec,
            |_| Ok(("Thank you.".to_string(), 300)),
            |t| panic!("whisper's silence noise was submitted: {t:?}"),
        );
        assert!(transcripts(&rec).is_empty());
    }

    /// INVARIANT: the refusal is said ONCE per run and again after a recovery. A line per
    /// refusal would arrive every ~1.104 s from an open mic in a quiet room, and a notice
    /// that repeats forever trains him to ignore the one that matters.
    #[test]
    fn the_refusal_is_said_once_per_run_and_again_after_the_room_recovers() {
        let rec = Recorder::default();
        let mut desk = RecognizerDesk::new();
        let refuse = |desk: &mut RecognizerDesk, rec: &Recorder| {
            desk.handle(&utterance(hiss(2.0, -40.0, 13)), rec, |_| panic!("reached whisper"), |_| {});
        };
        refuse(&mut desk, &rec);
        refuse(&mut desk, &rec);
        refuse(&mut desk, &rec);
        assert_eq!(messages(&rec).len(), 1, "the notice became a drip");

        // He speaks; the room is proven to work; the latch clears.
        desk.handle(
            &utterance(framed(synthetic_voice(1.2, 190.0, 130.0, -26.0), -55.0, 17)),
            &rec,
            |_| Ok(("Approved.".to_string(), 300)),
            |_| {},
        );
        refuse(&mut desk, &rec);
        assert_eq!(messages(&rec).len(), 2, "the refusal went silent after a good turn");
    }

    /// INVARIANT: the two CEO-facing voice notices are different sentences answering
    /// different questions — "nothing was sent" versus "I heard you and got no words". A
    /// single shared line would tell him the wrong thing in one of the two cases.
    #[test]
    fn the_two_voice_notices_say_different_things() {
        let a = VoiceNotice::HeardNoVoice.ceo_message();
        let b = VoiceNotice::SoundButNoWords.ceo_message();
        assert_ne!(a, b);
        assert!(a.contains("haven't sent anything"), "the refusal must close the send question: {a}");
        assert!(!a.contains('/') && !a.contains("dBFS"), "machinery leaked to the CEO: {a}");
        assert!(!b.contains('/') && !b.contains("dBFS"), "machinery leaked to the CEO: {b}");
    }


    // =====================================================================================
    // ROW 3.30, ANSWER 1 — A VOICE TURN CUT MID-SENTENCE SAYS SO AUDIBLY
    // =====================================================================================

    /// **THE TEST THIS ROW EXISTS FOR.** The notice reaches the SPEAKER, not only the panel.
    ///
    /// In voice mode the CEO's eyes are not on the screen — that is what voice mode is. A
    /// notice that only raises a `VoiceEvent` leaves him listening to silence and deciding
    /// for himself whether Rich is thinking or gone, which is the failure the row describes
    /// in its own words: *"the CEO is speaking to a system that has stopped listening and
    /// does not know it."*
    ///
    /// The speak sink is a parameter precisely so this can be asserted. A test over
    /// `VoiceEvent` alone would stay green through the entire defect.
    #[test]
    fn a_cut_off_answer_is_spoken_aloud_and_not_only_shown() {
        let rec = Recorder::default();
        let spoken = Mutex::new(Vec::<String>::new());
        CutOffDesk::handle(None, &rec, |t| spoken.lock().unwrap().push(t.to_string()));

        let said = spoken.into_inner().unwrap();
        assert_eq!(
            said,
            vec![VoiceNotice::ReplyCutOff.ceo_message().to_string()],
            "the sentence has to be QUEUED FOR THE SPEAKER, not merely raised as an event"
        );
        assert_eq!(messages(&rec), vec![VoiceNotice::ReplyCutOff.ceo_message().to_string()]);
    }

    /// INVARIANT: the reason is spoken as its OWN sentence after the notice, and the panel
    /// gets both in one line.
    ///
    /// Two sinks, two shapes, on purpose: the ear takes sentences one at a time and the eye
    /// takes a paragraph at once.
    #[test]
    fn the_reason_is_spoken_after_the_notice_and_shown_beside_it() {
        let rec = Recorder::default();
        let spoken = Mutex::new(Vec::<String>::new());
        // The exact sentence `richos-core`'s `UpstreamFault::Overloaded.ceo_message()`
        // authors. Voice does not know where it came from and does not parse it.
        let reason = "Anthropic's servers are at capacity, so that request never reached \
                      Claude. This one ends when their capacity frees up, and nothing on this \
                      machine brings it back sooner.";
        CutOffDesk::handle(Some(reason), &rec, |t| spoken.lock().unwrap().push(t.to_string()));

        let said = spoken.into_inner().unwrap();
        assert_eq!(said.len(), 2, "notice first, reason second: {said:?}");
        assert_eq!(said[0], VoiceNotice::ReplyCutOff.ceo_message());
        assert_eq!(said[1], reason);

        let shown = messages(&rec);
        assert_eq!(shown.len(), 1, "the panel gets ONE line");
        assert!(shown[0].starts_with(VoiceNotice::ReplyCutOff.ceo_message()));
        assert!(shown[0].contains("at capacity"));
    }

    /// POSITIVE CONTROL for the reason path: an ABSENT or blank reason produces exactly one
    /// spoken sentence and no empty utterance.
    ///
    /// Without this, `speak("")` would hand the synthesizer nothing and the CEO would hear a
    /// pause where a sentence should be — a silent failure inside the fix for a silent
    /// failure.
    #[test]
    fn a_missing_or_blank_reason_never_becomes_an_empty_utterance() {
        for reason in [None, Some(""), Some("   "), Some("\n")] {
            let rec = Recorder::default();
            let spoken = Mutex::new(Vec::<String>::new());
            CutOffDesk::handle(reason, &rec, |t| spoken.lock().unwrap().push(t.to_string()));
            let said = spoken.into_inner().unwrap();
            assert_eq!(said.len(), 1, "reason {reason:?} produced {said:?}");
            assert!(!said[0].trim().is_empty());
            assert_eq!(messages(&rec).len(), 1);
        }
    }

    /// INVARIANT: the cut-off notice is its own sentence, different from every other voice
    /// notice, and it carries no machinery.
    ///
    /// The three notices answer three different questions — "I got no words out of your
    /// audio", "nothing was sent", "the answer stopped". One shared line would tell him the
    /// wrong thing in two of the three cases.
    #[test]
    fn the_cut_off_notice_is_its_own_sentence_and_carries_no_machinery() {
        let cut = VoiceNotice::ReplyCutOff.ceo_message();
        for other in [VoiceNotice::SoundButNoWords.ceo_message(), VoiceNotice::HeardNoVoice.ceo_message()] {
            assert_ne!(cut, other);
        }
        // It states the CONSEQUENCE — what he heard is all there is — because the alternative
        // leaves him waiting for a sentence that is never coming.
        assert!(cut.contains("all I got out"), "the consequence is stated: {cut}");
        // And it ends on a status rather than an instruction, like the other two: the
        // affordance for asking again is the open microphone and there is no button.
        assert!(cut.contains("still listening"), "it ends with a status: {cut}");
        assert!(!cut.contains('/') && !cut.contains("dBFS"), "machinery leaked to the CEO: {cut}");
        assert!(!cut.contains("529") && !cut.contains("req_"), "operator detail is unspeakable: {cut}");
    }

    /// INVARIANT: an operator-shaped reason is spoken as it stands and NOT rewritten — but
    /// nothing in the product ever hands one here, and this test says which is which.
    ///
    /// `CutOffDesk` deliberately does not sanitize: a filter would be a second opinion about
    /// what is CEO-facing, and `upstream.rs` already owns that decision (its `summary()` is
    /// the operator's line and its `ceo_message()` is his). The guard that matters is on the
    /// CALLER, and it is asserted in `richos-core`'s own suites — `UpstreamRecord` keeps the
    /// request id in a field that the CEO view redacts, and `finish_upstream_failure` never
    /// puts `summary()` on a CEO path.
    #[test]
    fn the_desk_relays_the_reason_verbatim_and_owns_no_opinion_about_it() {
        let rec = Recorder::default();
        let spoken = Mutex::new(Vec::<String>::new());
        CutOffDesk::handle(Some("a sentence with EXACT wording"), &rec, |t| {
            spoken.lock().unwrap().push(t.to_string())
        });
        assert_eq!(spoken.into_inner().unwrap()[1], "a sentence with EXACT wording");
    }

    #[derive(Default)]
    struct Recorder {
        events: Mutex<Vec<VoiceEvent>>,
    }
    impl VoiceObserver for Recorder {
        fn on_voice_event(&self, event: &VoiceEvent) {
            self.events.lock().unwrap().push(event.clone());
        }
    }

    /// INVARIANT: three discarded utterances cannot happen faster than 3.312 s, so the
    /// silent-discard notice can never fire on a cough, a chair or one stray word — and it
    /// fires many times over inside the 25+ seconds of silent "listening…" that this notice
    /// exists to end.
    ///
    /// The two frame counts are `endpoint.rs`'s, and the arithmetic is redone here from the
    /// constants rather than quoted from its table: a comment that agrees with a number is
    /// not evidence that the number is right.
    #[test]
    fn three_silent_discards_take_at_least_three_and_a_third_seconds() {
        let min_speech = crate::endpoint::MIN_SPEECH_FRAMES as f32 * crate::vad::VAD_FRAME_SAMPLES as f32
            / crate::vad::SAMPLE_RATE as f32;
        let hangover = crate::endpoint::SILENCE_HANGOVER_FRAMES as f32 * crate::vad::VAD_FRAME_SAMPLES as f32
            / crate::vad::SAMPLE_RATE as f32;
        assert!((min_speech - 0.304).abs() < 1e-6, "19 x 256 / 16000 = 0.304, got {min_speech}");
        assert!((hangover - 0.800).abs() < 1e-6, "50 x 256 / 16000 = 0.800, got {hangover}");

        let one_utterance = min_speech + hangover;
        let floor = SILENT_DISCARD_RUN as f32 * one_utterance;
        assert!((one_utterance - 1.104).abs() < 1e-6, "one utterance floor: {one_utterance}");
        assert!((floor - 3.312).abs() < 1e-5, "three in a row: {floor}");

        // Below the run length it says nothing at all, which is the half that keeps a cough
        // quiet. Above it, one line — and 3.312 s fits inside the measured 25 s seven times.
        assert!(floor < 25.0);
        assert_eq!(SILENT_DISCARD_RUN, 3);
    }

    /// INVARIANT: the notice states a condition and invents no control. The ◉ that ends
    /// voice is already on screen with its own footnote, so a sentence pointing at a
    /// control would be a request wearing a status's clothes — and the affordance suite
    /// classifies this string INFORMATIONAL on exactly that reading.
    #[test]
    fn the_silent_discard_notice_names_no_control_and_no_machinery() {
        let m = VoiceNotice::SoundButNoWords.ceo_message();
        assert!(!m.contains('/'), "{m}");
        assert!(!m.chars().any(|c| c.is_ascii_digit()), "{m}");
        assert!(!m.to_lowercase().contains("whisper"), "{m}");
        assert!(!m.to_lowercase().contains("transcri"), "{m}");
        // What it DOES say: sound arrived, words did not, and voice was not switched off
        // behind his back.
        assert!(m.contains("hear sound"), "{m}");
        assert!(m.contains("Voice is still on"), "{m}");
    }

    /// INVARIANT: the diagnostics line reports MEASURED device facts and the exact barge-in
    /// frame math — it is the line that goes in the brief, so it must not contain estimates.
    #[test]
    fn the_diagnostics_line_carries_the_exact_frame_math() {
        let d = Diagnostics {
            input_source: "microphone".into(),
            input_rate: 48_000,
            input_channels: 2,
            output_device: "External Headphones".into(),
            output_rate: 48_000,
            output_channels: 2,
            stt_model: "small.en".into(),
            stt_binary: "/opt/homebrew/bin/whisper-cli".into(),
            tts_voice: "macOS say · Daniel · 180 wpm".into(),
            echo_gate: "none (5.008s debounce + headphones)".into(),
            echo_cancellation: false,
            barge_in_frames: BARGE_IN_DEBOUNCE_FRAMES,
            barge_in_secs: frames_to_secs(BARGE_IN_DEBOUNCE_FRAMES),
        };
        let s = d.summary();
        assert!(s.contains("313 frames"), "{s}");
        assert!(s.contains("5.008 s"), "{s}");
        assert!(!d.echo_cancellation, "v1 must never claim echo cancellation");
    }

    /// INVARIANT: a voice-start failure is a calm CEO line, whatever failed underneath.
    #[test]
    fn every_start_failure_has_a_calm_ceo_line() {
        let errs = [
            VoiceStartError::Capture(capture::CaptureError::NoInputDevice),
            VoiceStartError::Stt(stt::SttError::ModelNotFound("/x/ggml-small.en.bin".into())),
            VoiceStartError::Playout(crate::playout::PlayoutError::NoOutputDevice),
        ];
        for e in errs {
            let msg = e.ceo_message();
            assert!(!msg.is_empty());
            assert!(!msg.contains("ggml"), "machinery leaked: {msg}");
            assert!(!msg.contains('/'), "a path leaked to the CEO: {msg}");
        }
    }

    /// INVARIANT: the controller is `Send + Sync`, because it lives in Tauri managed state.
    /// cpal's macOS `Stream` is Send by construction in 0.17 (dedicated-thread architecture);
    /// if that ever changes this test fails at COMPILE time rather than at the toggle.
    #[test]
    fn the_controller_can_live_in_tauri_managed_state() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<VoiceController>();
        assert_send_sync::<Playout>();
    }

    /// INVARIANT: the generation counter is what makes a barge-in stick. A sentence
    /// synthesized across an interruption must be discarded, not played late.
    #[test]
    fn a_sentence_synthesised_across_a_barge_in_is_discarded() {
        let gen = AtomicU64::new(7);
        let queued_at = gen.load(Ordering::Relaxed);
        // …the CEO interrupts while `say` is running…
        gen.fetch_add(1, Ordering::Relaxed);
        assert_ne!(queued_at, gen.load(Ordering::Relaxed), "stale audio would have played");
    }

    /// LIVE (opt-in): a MEASURED barge-in on the real output device. Rich starts talking for
    /// real, gets cut, and the numbers are checked — dropped audio, an empty queue that stays
    /// empty, and a stop latency of one device callback period.
    ///
    /// Behind RICHOS_VOICE_LIVE_AUDIO=1 because this one is genuinely audible: about a second
    /// of Rich's voice comes out of the speakers before it is cut.
    ///
    /// **Reported `ignored`, never `ok`, when the opt-in is absent** — the gate used to be an
    /// early `return`, and a test that returns is reported `ok`. See `build.rs`.
    #[test]
    #[cfg(target_os = "macos")]
    #[cfg_attr(
        not(live_audio),
        ignore = "LIVE AUDIO: audible, ~1 s out of the speakers. RICHOS_VOICE_LIVE_AUDIO=1 to run."
    )]
    fn live_barge_in_actually_silences_the_real_output_device() {
        crate::live_audio::require_opt_in();
        let dir = std::env::temp_dir().join("richos-voice-barge-test");
        std::fs::create_dir_all(&dir).unwrap();
        // A silent "microphone": the capture path runs for real, it just hears nothing, so
        // this test isolates the INTERRUPTION from the recognition.
        let quiet = dir.join("quiet.wav");
        crate::wav::write_pcm16_mono(&quiet, &vec![0.0f32; 16_000], crate::vad::SAMPLE_RATE).unwrap();

        let observer = Arc::new(Recorder::default());
        let ctl = VoiceController::start(
            VoiceOptions { source: AudioSource::Wav(quiet), scratch_dir: dir.clone() },
            observer.clone(),
            Arc::new(|_t: String| {}),
        )
        .expect("voice mode should start");

        // Rich says something long enough to be worth interrupting.
        ctl.turn_started();
        ctl.speak_delta(
            "Three things this morning. Acme came back on the renegotiation and the number is \
             softer than it looks. Finance found a gap in the Q4 forecast. Partnerships want a \
             call about the economics before Thursday. ",
        );
        ctl.speak_end();
        ctl.turn_ended();

        // Wait until there is real audio worth interrupting. The FIRST sentence alone is only
        // ~1.3 s — the queue keeps growing behind it because synthesis outruns playback
        // (rtf ~0.074), which is the pipelining working, so wait for the depth rather than
        // for the first sample.
        let deadline = Instant::now() + Duration::from_secs(15);
        while ctl.queued_speech_secs() <= 2.0 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        let queued_before = ctl.queued_speech_secs();
        assert!(queued_before > 2.0, "Rich never got going: {queued_before:.3} s queued");

        // Let him actually be audible for a beat, then cut him.
        std::thread::sleep(Duration::from_millis(900));
        let cut_at = Instant::now();
        let dropped = ctl.force_barge_in();
        let cut_took = cut_at.elapsed();

        let rate = ctl.diagnostics().output_rate as f32;
        let dropped_secs = dropped as f32 / rate;
        let stop_latency = ctl.stop_latency_secs();
        println!(
            "barge-in: dropped {} samples = {:.3} s of Rich; call took {:.4} s; device stop latency {:.4} s ({} frames @ {} Hz)",
            dropped,
            dropped_secs,
            cut_took.as_secs_f32(),
            stop_latency,
            (stop_latency * rate).round() as u32,
            rate as u32
        );

        assert!(dropped_secs > 1.0, "nothing meaningful was cut: {dropped_secs:.3} s");
        assert!(
            stop_latency > 0.0 && stop_latency < 0.100,
            "stop latency implausible: {stop_latency:.4} s"
        );
        // The device must genuinely fall silent and STAY silent — a queue that refills would
        // mean a sentence synthesized across the cut still got through.
        std::thread::sleep(Duration::from_millis(600));
        assert_eq!(ctl.queued_speech_secs(), 0.0, "Rich started talking again after being cut");
        assert_eq!(ctl.state(), VoiceState::Listening, "state did not return to listening");

        drop(ctl);
        std::fs::remove_dir_all(&dir).ok();
    }

    /// LIVE: the full local loop with audio INJECTED at the capture source — real VAD, real
    /// endpointing, real whisper.cpp, real `say`, real output device. The only thing this
    /// does not exercise is the microphone driver, which this machine does not have (see
    /// capture.rs). Rich's "reply" here is a fixed string, so the Claude leg is out of
    /// scope for a unit test; `voice_loop` (the example) does that end of it.
    ///
    /// **Reported `ignored`, never `ok`, when the opt-in is absent** — the gate used to be an
    /// early `return`, and a test that returns is reported `ok`. See `build.rs`.
    #[test]
    #[cfg(target_os = "macos")]
    #[cfg_attr(
        not(live_audio),
        ignore = "LIVE AUDIO: needs an output device AND whisper.cpp. RICHOS_VOICE_LIVE_AUDIO=1 to run."
    )]
    fn live_injected_audio_completes_the_whole_local_loop() {
        crate::live_audio::require_opt_in();
        let dir = std::env::temp_dir().join("richos-voice-loop-test");
        std::fs::create_dir_all(&dir).unwrap();
        let wav_path = dir.join("ceo.wav");

        // Synthesize a "CEO" utterance with a DIFFERENT voice than Rich's, at 16 kHz.
        let out = std::process::Command::new("/usr/bin/say")
            .args(["-v", "Samantha", "-o"])
            .arg(&wav_path)
            .arg("--data-format=LEI16@16000")
            .arg("Rich, what is the status of the voice pipeline today?")
            .output()
            .expect("say");
        assert!(out.status.success());

        let observer = Arc::new(Recorder::default());
        let heard: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let heard2 = heard.clone();
        let ctl = VoiceController::start(
            VoiceOptions { source: AudioSource::Wav(wav_path), scratch_dir: dir.clone() },
            observer.clone(),
            Arc::new(move |text: String| {
                heard2.lock().unwrap().push(text);
            }),
        )
        .expect("voice mode should start with an injected source");

        // 3.1 s of audio + 0.800 s hangover + ~0.5 s whisper.
        std::thread::sleep(Duration::from_millis(6000));
        let said = heard.lock().unwrap().clone();
        assert!(!said.is_empty(), "the loop never produced a transcript");
        assert!(
            said[0].to_lowercase().contains("voice pipeline"),
            "transcript did not match what was spoken: {said:?}"
        );

        // Now Rich answers, streamed as deltas exactly as the spine does.
        ctl.turn_started();
        ctl.speak_delta("Good morning. ");
        ctl.speak_delta("The voice pipeline is up. ");
        ctl.speak_end();
        ctl.turn_ended();
        std::thread::sleep(Duration::from_millis(1500));
        assert!(ctl.queued_speech_secs() > 0.0 || ctl.state() == VoiceState::Speaking,
            "Rich never produced audio");
        drop(ctl);
        std::fs::remove_dir_all(&dir).ok();
    }

    /// **LIVE, END TO END: THE 2026-09-04 DEFECT, REPRODUCED AND THEN REFUSED.**
    ///
    /// Everything above proves a piece. This drives the WHOLE pipeline — real capture path,
    /// real VAD, real endpointer, real recognizer thread, real submit callback — and proves
    /// both directions on the same run:
    ///
    /// 1. **The failure, reproduced.** 12.000 s of -30 dBFS room hiss. That is 6.5 dB above
    ///    the VAD's initial threshold (`max(0.005 x 3, 0.005)` = 0.015 = -36.48 dBFS), so
    ///    every frame reads as speech until the 625-frame (10.000 s) stuck-floor escape lets
    ///    the floor learn the room — and then the 50-frame (0.800 s) hangover closes an
    ///    utterance of roughly 10.8 s. That utterance is EXACTLY what published v1.0.1 would
    ///    have handed to whisper and submitted under the CEO's name. It must produce no turn,
    ///    and it must say so.
    /// 2. **The fix not being a mute button.** A real `say` utterance through the identical
    ///    path must still land as a turn with the right words in it.
    ///
    /// Opt-in (`RICHOS_VOICE_LIVE_AUDIO=1`) because it opens a real output device and takes
    /// ~20 s of wall clock. It never plays anything: no `speak_delta` is called, so the test
    /// is silent even on a machine with speakers.
    ///
    /// **Reported `ignored`, never `ok`, when the opt-in is absent** — the gate used to be an
    /// early `return`, and a test that returns is reported `ok`. That mattered more here than
    /// anywhere else in the crate: this is the test that holds the 2026-09-04 defect shut, and
    /// it was printing `ok` without running on every machine but one. See `build.rs`.
    #[test]
    #[cfg(target_os = "macos")]
    #[cfg_attr(
        not(live_audio),
        ignore = "LIVE AUDIO: needs an output device AND whisper.cpp, ~20 s. RICHOS_VOICE_LIVE_AUDIO=1 to run."
    )]
    fn live_a_silent_channel_produces_no_turn_and_a_real_utterance_still_does() {
        crate::live_audio::require_opt_in();
        let dir = std::env::temp_dir().join("richos-voice-silent-channel-test");
        std::fs::create_dir_all(&dir).unwrap();

        // ---- 1. the quiet room that v1.0.1 spoke for him from -----------------------------
        let room = dir.join("quiet-room.wav");
        crate::wav::write_pcm16_mono(&room, &hiss(12.0, -30.0, 4_242), crate::vad::SAMPLE_RATE)
            .expect("write the room fixture");

        let observer = Arc::new(Recorder::default());
        let sent: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let sink = sent.clone();
        let ctl = VoiceController::start(
            VoiceOptions { source: AudioSource::Wav(room), scratch_dir: dir.clone() },
            observer.clone(),
            Arc::new(move |text: String| sink.lock().unwrap().push(text)),
        )
        .expect("voice mode should start with an injected source");
        // 12.000 s of audio + 0.800 s hangover + the gate; generous, because a false pass
        // here would be a test that agreed with the bug.
        std::thread::sleep(Duration::from_millis(16_000));
        let said = sent.lock().unwrap().clone();
        assert!(said.is_empty(), "a silent channel was submitted as the CEO's message: {said:?}");
        let notices = messages(&observer);
        assert!(
            notices.contains(&VoiceNotice::HeardNoVoice.ceo_message().to_string()),
            "the utterance either never reached the desk (so this test proves nothing) or was \
             dropped silently. Notices seen: {notices:?}"
        );
        drop(ctl);

        // ---- 2. and a real utterance still gets through ------------------------------------
        let spoken = dir.join("ceo.wav");
        let out = std::process::Command::new("/usr/bin/say")
            .args(["-v", "Samantha", "-o"])
            .arg(&spoken)
            .arg("--data-format=LEI16@16000")
            .arg("Rich, what is the status of the voice pipeline today?")
            .output()
            .expect("say");
        assert!(out.status.success());

        let observer2 = Arc::new(Recorder::default());
        let sent2: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let sink2 = sent2.clone();
        let ctl2 = VoiceController::start(
            VoiceOptions { source: AudioSource::Wav(spoken), scratch_dir: dir.clone() },
            observer2.clone(),
            Arc::new(move |text: String| sink2.lock().unwrap().push(text)),
        )
        .expect("voice mode should start with an injected source");
        std::thread::sleep(Duration::from_millis(8_000));
        let said2 = sent2.lock().unwrap().clone();
        assert!(!said2.is_empty(), "the gate swallowed a real utterance — it is a mute button");
        assert!(
            said2[0].to_lowercase().contains("voice pipeline"),
            "transcript did not match what was spoken: {said2:?}"
        );
        drop(ctl2);
        std::fs::remove_dir_all(&dir).ok();
    }
}
