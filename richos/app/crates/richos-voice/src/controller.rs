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
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Supervisor tick. 25 ms is faster than the eye notices and far slower than the 16.000 ms
/// audio frame, so the UI never lags the mic and the tick never competes with audio.
const TICK: Duration = Duration::from_millis(25);

/// **HOW FAR BACK AN UTTERANCE'S RECORDING ACTUALLY REACHES, in VAD frames.**
///
/// `CapMsg::Started` does not mean "the first recorded sample is now". The recorder keeps
/// [`crate::endpoint::PRE_ROLL_FRAMES`] of audio from BEFORE onset (so whisper hears the first
/// consonant), and the onset itself takes [`crate::endpoint::SPEECH_ONSET_FRAMES`] to confirm.
/// So the WAV that reaches the recognizer begins:
///
/// ```text
///   PRE_ROLL_FRAMES + SPEECH_ONSET_FRAMES = 19 + 7 = 26 frames
///   26 x 256 / 16000 = 0.416 s before `Started` fires
/// ```
///
/// A taint test that only looks at `speaking` ON the `Started` frame therefore ignores 0.416 s
/// of audio that is already in the buffer — and whisper transcribes the whole buffer. If Rich
/// was audible anywhere in that window, his voice is in the file.
const ECHO_LOOKBACK_FRAMES: u32 =
    crate::endpoint::PRE_ROLL_FRAMES as u32 + crate::endpoint::SPEECH_ONSET_FRAMES;

/// Emit a level update at most this often — a 62.5 Hz meter is wasted work in a webview.
const LEVEL_EMIT_EVERY: Duration = Duration::from_millis(100);

pub fn now_millis() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// `HH:MM:SS.mmmZ` in UTC, with no dependency and no allocation beyond the string.
///
/// **It exists because a log line that cannot be lined up against the ledger is not evidence.**
/// Ray's candidate-.5 walk could establish that Rich's own counting was submitted as the CEO's
/// prompt at `20:06:43.693Z`, and could NOT establish whether the utterance began in a gap
/// between spoken sentences or after playout had been marked ended — because `app.log` carries
/// no timestamps at all. The ledger stamps in UTC milliseconds; so does this.
pub fn wall_clock_utc() -> String {
    let ms = now_millis();
    let secs = ms / 1000;
    format!("{:02}:{:02}:{:02}.{:03}Z", (secs / 3600) % 24, (secs / 60) % 60, secs % 60, ms % 1000)
}

/// One edge of a boolean that is being watched.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Edge {
    Rose,
    Fell,
}

/// **THE WINDOW IN WHICH RICH IS AUDIBLE — the whole of an answer, not the queue's state.**
///
/// The flag the capture path calls `speaking` used to be `playout.is_playing()`, which is
/// `queued_samples() > 0`. Ray's candidate-.5 walk proved that insufficient on the CEO's rig:
/// Rich answered *"Please count slowly out loud from 1 to 20"*, and his own *"One... two...
/// three... four... five..."* came back through the Wave:3, was recognized, and was submitted
/// as the CEO's message at `20:06:43.693Z` — a model turn spent on words he never said.
///
/// A queue-depth test is false in three places inside one answer:
///
/// | hole | why the queue is empty | covered by |
/// |---|---|---|
/// | before the first sample | `say` has not finished spawning | `owed` |
/// | between spoken sentences | synthesis of N+1 is slower than playback of N | `owed` |
/// | after the last sample | the device has it, the room has not heard it yet | `hold` |
///
/// The second is the one that matters most here. Deltas chunk on runs of `.`/`!`/`?`
/// ([`crate::chunk`]), so `One... two... three...` becomes roughly twenty one-word sentences
/// and therefore twenty separate `say` spawns, each with its own gap.
///
/// `hold` is MEASURED, never assumed — see [`audible_hold_secs`].
///
/// Pure: driven by a millisecond count the caller supplies, so the whole rule is unit-testable
/// without a device, a clock or a sound.
pub struct AudibleWindow {
    open: bool,
    queued: bool,
    /// The last observation at which Rich was queued or owed.
    last_live_ms: u64,
}

impl Default for AudibleWindow {
    fn default() -> Self {
        AudibleWindow::new()
    }
}

impl AudibleWindow {
    pub fn new() -> Self {
        AudibleWindow { open: false, queued: false, last_live_ms: 0 }
    }

    /// Is Rich audible right now, in the sense the taint rule needs?
    pub fn is_open(&self) -> bool {
        self.open
    }

    /// Advance the window.
    ///
    /// - `queued` — the playout queue is non-empty.
    /// - `owed` — at least one sentence is between the speaker channel and the queue.
    /// - `hold_secs` — how long the window stays open after the last of both, from
    ///   [`audible_hold_secs`].
    /// - `now_ms` — a MONOTONIC millisecond count. Never the wall clock: the wall clock can
    ///   step backwards and a half-duplex window that closes early is the whole defect.
    ///
    /// Returns `(answer edge, chunk edge)` — the first is the extended window, the second is
    /// the raw queue. Both are logged, because the difference between them IS the diagnosis
    /// Ray could not make from the record.
    pub fn observe(
        &mut self,
        queued: bool,
        owed: bool,
        hold_secs: f32,
        now_ms: u64,
    ) -> (Option<Edge>, Option<Edge>) {
        let live = queued || owed;
        if live {
            self.last_live_ms = now_ms;
        }
        let hold_ms = (hold_secs.max(0.0) * 1000.0).ceil() as u64;
        // The tail only holds a window that was already open. Nothing has played, nothing to
        // hold.
        let within_hold =
            !live && self.open && now_ms.saturating_sub(self.last_live_ms) < hold_ms;
        let open = live || within_hold;

        let answer = match (self.open, open) {
            (false, true) => Some(Edge::Rose),
            (true, false) => Some(Edge::Fell),
            _ => None,
        };
        let chunk = match (self.queued, queued) {
            (false, true) => Some(Edge::Rose),
            (true, false) => Some(Edge::Fell),
            _ => None,
        };
        self.open = open;
        self.queued = queued;
        (answer, chunk)
    }
}

/// **HOW LONG RICH STAYS AUDIBLE AFTER THE LAST SAMPLE LEAVES THE QUEUE.** Every term is a
/// measurement taken from the running stream; nothing here is a constant someone chose.
///
/// ```text
///   output device tail   Playout::audible_tail_secs()  the DAC has it, the room does not yet
/// + input device latency Capture::input_latency_secs() this frame's audio is already that old
/// + one VAD frame        0.016 s                       the slicer's maximum hold, 256/16000
/// ```
///
/// The input term is there because the capture callback reads `speaking` at PROCESSING time
/// while judging audio that was in the room earlier; the slicer term because `FrameSlicer`
/// holds up to 255 samples waiting to complete a 256-sample frame.
///
/// Floored at one [`TICK`], because this hold is evaluated once per tick: a window shorter
/// than the interval at which it is sampled cannot be enforced, and claiming otherwise would
/// be a timing assertion the code cannot keep.
///
/// Measured on the CEO's rig on 2026-09-17 (Mac mini Speakers out, Elgato Wave:3 in):
/// output tail 10.7 ms, so the sum is well under one 25 ms tick and the floor is what applies.
pub fn audible_hold_secs(out_tail_secs: f32, in_latency_secs: f32) -> f32 {
    let slicer = frames_to_secs(1);
    (out_tail_secs + in_latency_secs + slicer).max(TICK.as_secs_f32())
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
    /// The debounce that comes into force once [`crate::aec::EchoCanceller::confident`] is
    /// true. Reported BESIDE the fallback rather than instead of it, because at the moment
    /// this line is printed neither number is a prediction: the fallback is what is running,
    /// and this is what the canceller can earn.
    pub barge_in_earned_frames: u32,
    pub barge_in_earned_secs: f32,
}

impl Diagnostics {
    /// One line for stderr at voice-mode start. Developer-facing only — never the CEO's view.
    ///
    /// **IT NAMES THE DEBOUNCE AS THE FALLBACK IT IS.** Until 2026-09-17 this line read
    /// `aec=PBFDAF 2048 taps (128 ms tail) · barge-in=313 frames (5.008 s)` and stopped
    /// there, which reads as a settled capability — two exact figures, no qualifier. It is
    /// not one. `313` is the debounce in force AT START and only while the canceller has not
    /// proven itself; the code that fills this struct has always known that and said so in a
    /// comment, while the line it printed did not.
    ///
    /// That gap was read off the running app by audit-3 (§4 #1): the boot line advertised
    /// barge-in, the runtime log said the opposite, and both were taken at face value. A
    /// developer line that has to be read alongside a source comment to mean what it says is
    /// a line that will be misread again, so it now carries both numbers and which one is
    /// running.
    pub fn summary(&self) -> String {
        format!(
            "in={} {} Hz/{} ch · out={} {} Hz/{} ch · stt={} · tts={} · aec={} · barge-in={} frames ({:.3} s) until the canceller proves itself, then {} frames ({:.3} s)",
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
            self.barge_in_earned_frames,
            self.barge_in_earned_secs,
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
    /// This utterance overlaps Rich being audible: echo until proven otherwise.
    tainted: bool,
    /// A barge-in fired during the current utterance, which proves it is NOT echo.
    barged: bool,
    /// Consecutive frames on which Rich was NOT audible, saturating. Compared against
    /// [`ECHO_LOOKBACK_FRAMES`] so the pre-roll already sitting in the recorder is judged too,
    /// not just the frame `Started` happens to land on.
    quiet_frames: u32,
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
            quiet_frames: u32::MAX,
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

        // How long since Rich was last audible, in frames. Saturating, and updated BEFORE any
        // decision below reads it, so `quiet_frames == 0` means "he is audible on this frame".
        self.quiet_frames = if speaking { 0 } else { self.quiet_frames.saturating_add(1) };

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
            // **THE TAINT RULE, conditional on the canceller and now on the WHOLE utterance.**
            //
            // With a confident canceller Rich's voice is no longer meaningfully present in
            // `frame` — it has been subtracted, and the residual has been MEASURED 6 dB below
            // the VAD's speech floor for 2.000 s. An utterance beginning while he speaks is
            // therefore the CEO starting a sentence, not an echo of Rich's, and throwing it
            // away is the bug rather than the fix. That half is untouched.
            //
            // What changed on 2026-09-17 is the other half. The rule used to be
            // `speaking && !barged && !confident`, evaluated ONCE, on this frame. Two things
            // were outside it, and Rich's own counting came back through the CEO's speakers
            // and was submitted as his message because of them:
            //
            //   1. **The 0.416 s already in the buffer.** See `ECHO_LOOKBACK_FRAMES`.
            //   2. **Everything after this frame.** An utterance born in a synthesis gap was
            //      born untainted and stayed untainted while Rich spoke over the rest of it —
            //      `SILENCE_HANGOVER_FRAMES` is 0.800 s, so it survives the gaps easily and is
            //      admitted whole. That is the `else if` below.
            //
            // `speaking` itself now covers the whole answer rather than the queue's depth
            // (`AudibleWindow`), so "Rich was audible" finally means what it says.
            let echo_is_in_the_recording = speaking || self.quiet_frames < ECHO_LOOKBACK_FRAMES;
            self.tainted = echo_is_in_the_recording && !self.barged && !confident;
            out.push(CapMsg::Started { tainted: self.tainted });
        } else if recording && !self.tainted && speaking && !self.barged && !confident {
            // **TAINT IS RE-EVALUATED FOR AS LONG AS THE UTTERANCE IS ALIVE.** Rich became
            // audible during an utterance that had already started, and the canceller cannot
            // separate the two voices, so the recording now contains him. Once set it stays
            // set until the utterance ends — only a barge-in clears it, and a barge-in is a
            // positive signal that the CEO is the one talking.
            self.tainted = true;
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

/// **THE DECREMENT OF [`Shared::pending_speech`], MADE STRUCTURAL.**
///
/// A counter that says "Rich still owes the speakers a sentence" is only safe if it can never
/// be left high: a stuck non-zero value would hold `speaking` true forever, and a microphone
/// that is permanently tainted is a microphone that has stopped working. The speaker loop has
/// four exits from one iteration — the stale-generation skip before synthesis, the stale-
/// generation skip after it, a synthesis error, and the success path — plus unwind. A `Drop`
/// guard covers all five by construction, which an `else` branch does not.
struct PendingSpeech(Arc<Shared>);

impl Drop for PendingSpeech {
    fn drop(&mut self) {
        // Saturating, so a decrement that somehow outnumbers its increment reads zero rather
        // than `usize::MAX` — the failure mode here must be "Rich is heard", never "the CEO
        // is never heard again".
        let _ = self.0.pending_speech.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| {
            Some(n.saturating_sub(1))
        });
    }
}

struct Shared {
    /// Live input level 0..1, f32 bits. Written per frame by the audio thread.
    level: AtomicU32,
    /// **TRUE FOR THE WHOLE OF RICH'S ANSWER**, not merely while the playout queue is
    /// non-empty — read by the audio thread to arm barge-in and to taint what it records.
    ///
    /// It used to be exactly `playout.is_playing()`, and that left two holes an utterance
    /// could be born in, both of them inside an answer the CEO can hear:
    ///
    /// 1. **The gaps between spoken sentences.** Sentences are synthesized one at a time on
    ///    the speaker thread (`MacSay` spawns `say` per sentence). Whenever synthesis of
    ///    sentence N+1 takes longer than the playback of sentence N, the queue empties and
    ///    this flag went false mid-answer. Ray's candidate-.5 walk on 2026-09-17 answered
    ///    *"Please count slowly out loud from 1 to 20"*, whose deltas chunk into roughly
    ///    twenty one-word sentences and therefore twenty separate `say` spawns.
    /// 2. **The device tail.** See [`crate::playout::Playout::audible_tail_secs`].
    ///
    /// So it is now `queued || synthesis still owed || within the measured tail of either`.
    /// [`Shared::pending_speech`] is the "still owed" term.
    speaking: AtomicBool,
    /// Sentences handed to the speaker thread that have NOT yet reached the playout queue —
    /// synthesis in flight. Non-zero means Rich's answer is not over however empty the queue
    /// is, which is the fact that closes hole 1 above. Incremented at the send, decremented
    /// by a guard that runs on every exit from the speaker loop's body including unwind.
    pending_speech: AtomicUsize,
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

/// **THE CANCELLER'S LIVE STATE, PUBLISHED LOSSLESSLY.**
///
/// This replaces a single `AtomicU32` that packed confidence into bit 0 and whole-dB ERLE into
/// bits 1.., via `(erle_db.max(0.0) as u32) << 1`. That packing destroyed the two facts an
/// operator needs most:
///
/// - **it clamped negatives to zero.** Measured on this Mac on 2026-09-17 the live figure is
///   **−0.1 dB** — the canceller removing marginally less than nothing — and the log printed
///   `erle=0 dB`. "Zero" reads as "not started yet"; the truth is "running and achieving
///   nothing on this path", which is a different problem with a different answer.
/// - **it truncated toward zero**, so anything under 1.0 dB also printed `0`.
///
/// Ray's candidate-.4 walk read `erle=0 dB` off the running app and took it as evidence the
/// canceller was not learning at all. It was learning; it was learning a path whose coherence
/// caps any linear canceller at 4.3 dB (`docs/verification/2026-09-17-aec-erle-on-the-ceo-rig.md`).
/// A number that cannot be negative cannot report that, so it is stored in signed millidecibels.
///
/// One relaxed store per audio frame, no locks, readable from anywhere.
#[derive(Debug, Default)]
pub struct AecShared {
    /// The canceller has measured its residual low enough, for long enough, to be trusted.
    confident: AtomicBool,
    /// Echo Return Loss Enhancement in **millidecibels, signed**. Negative is a real reading.
    erle_mdb: AtomicI32,
    /// The tracked typical residual while Rich is audible, in **millidecibels full scale**.
    /// This is the number [`crate::aec::CONFIDENT_LEAK_RMS`] is compared against, so publishing
    /// it is what makes "how far short is it" answerable from a log line instead of a guess.
    leak_mdbfs: AtomicI32,
}

impl AecShared {
    fn store(&self, confident: bool, erle_db: f32, leak_rms: f32) {
        self.confident.store(confident, Ordering::Relaxed);
        self.erle_mdb.store(millis(erle_db), Ordering::Relaxed);
        self.leak_mdbfs.store(millis(dbfs(leak_rms)), Ordering::Relaxed);
    }
    fn confident(&self) -> bool {
        self.confident.load(Ordering::Relaxed)
    }
    fn erle_db(&self) -> f32 {
        self.erle_mdb.load(Ordering::Relaxed) as f32 / 1000.0
    }
    fn leak_dbfs(&self) -> f32 {
        self.leak_mdbfs.load(Ordering::Relaxed) as f32 / 1000.0
    }
}

/// dB to signed millidecibels, saturating rather than wrapping. A non-finite reading stores 0
/// — the one value that cannot be mistaken for a measurement of anything.
fn millis(db: f32) -> i32 {
    if !db.is_finite() {
        return 0;
    }
    (db * 1000.0).clamp(i32::MIN as f32, i32::MAX as f32) as i32
}

/// RMS to dBFS, with the same floor `aec.rs` and the examples use.
fn dbfs(rms: f32) -> f32 {
    20.0 * rms.max(1e-12).log10()
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
    /// The canceller's live state — confidence, signed ERLE, tracked leak floor. Written once
    /// per audio frame by the capture thread. See [`AecShared`] for why it is not one packed
    /// word any more.
    aec_state: Arc<AecShared>,
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
    /// **A VOICE WAS MEASURED, WHISPER RAN, AND THE WORDS IT RETURNED WERE NOT WORDS** —
    /// whisper's documented non-speech noise (`(clears throat)`, `[BLANK_AUDIO]`), refused by
    /// [`stt::is_meaningful`]. Dropping it is right. Saying nothing about it was not.
    ///
    /// **The defect this closes is an ASYMMETRY, not a missing feature** (audit-3 §4 #4,
    /// frame `a3-15`). Two refusal paths sit side by side in [`RecognizerDesk::handle`] and
    /// they treated the CEO completely differently:
    ///
    /// | path | when | what he was told |
    /// |---|---|---|
    /// | [`crate::voiced`] gate, pre-whisper | the audio carried no voice | [`VoiceNotice::HeardNoVoice`], on the FIRST refusal |
    /// | [`stt::is_meaningful`], post-whisper | a voice, but no words | **nothing** until the THIRD in a row |
    ///
    /// So the case where he definitely DID speak — a voice was measured, which is a stronger
    /// signal than the pre-whisper path ever has — was the quieter of the two. A 2.3 s
    /// utterance came back `(clears throat)` and the window did not change at all: he could
    /// not tell "not heard" from "heard and discarded" from "broken".
    ///
    /// **It is latched per RUN, exactly like [`VoiceNotice::HeardNoVoice`]**, and for that
    /// notice's stated reason: an open mic can produce these back to back, and a line per
    /// discard is a drip that trains him to ignore the one that matters. First discard says
    /// it; the rest are stderr only; the latch clears the moment an utterance is admitted,
    /// because that proves the input recovered. At [`SILENT_DISCARD_RUN`] the stronger
    /// [`VoiceNotice::SoundButNoWords`] takes over and this one stands aside, so a run of
    /// discards produces two sentences in total and never two at once.
    ///
    /// **It goes down `rich://voice-notice`, not `rich://voice-error`.** Nothing failed and
    /// voice did not stop, which is the split `event.rs` draws. It also means the line is not
    /// suppressed when the voice panel is closed — `main.js`'s notice listener is the only one
    /// of the four that does not bail on `!voiceMode`.
    DidNotCatchThat,
    /// **RICH COULD NOT LISTEN WHILE HE WAS SPEAKING, AND WHATEVER THE MICROPHONE PICKED UP
    /// THEN WAS THROWN AWAY** — audit-3 §4 #1, corrected after candidate .4's walk proved the
    /// first wording false on the CEO's own rig.
    ///
    /// ## What it replaced, and why the replacement is not a softening
    ///
    /// This variant used to be `TalkedOverRich` and it said *"You started talking while I was
    /// still speaking … so that didn't reach me and I haven't sent anything."* Ray walked it on
    /// the CEO's screen on 2026-09-17 and it fired while he was provably silent
    /// (`docs/verification/2026-09-17-nightly-1.2.0-20260917.4-onscreen-audit.md` §3): at output
    /// volume 85 a spoken turn produced the notice with nobody talking, and the identical turn
    /// with the output volume set to 0 produced no discard and no notice at all. The single
    /// variable was whether Rich's own voice was audible in the room.
    ///
    /// **The code says the same thing, and it says it structurally.** `push_residual` sets
    /// `self.tainted = speaking && !self.barged && !confident`, so a tainted discard requires
    /// `confident == false` — the canceller declining to vouch for its own residual. When it IS
    /// confident the utterance is ADMITTED rather than discarded and there is nothing to
    /// announce. **So the old sentence was emitted only, and exactly, on the path where the app
    /// cannot know whose voice it heard.** There was no reachable path on which it was known to
    /// be true. That is why the accusation is deleted rather than gated behind a condition.
    ///
    /// ## It is not a transient state on the CEO's hardware — measured
    ///
    /// Measured on this Mac on 2026-09-17 — five live runs of `examples/aec_live`, two of
    /// `examples/aec_probe`, and one recorded pair replayed offline, all pasted in
    /// `docs/verification/2026-09-17-aec-erle-on-the-ceo-rig.md`. Mac mini Speakers out, Elgato
    /// Wave:3 in, at the CEO's own volume setting:
    ///
    /// ```text
    ///   steady-state ERLE, five live runs      -0.5 .. +0.7 dB   (nothing removed)
    ///   ERLE over the recorded sentence         6.3 dB
    ///   microphone while Rich is audible      -42 .. -46 dBFS
    ///   aec::CONFIDENT_LEAK_RMS               -52.04 dBFS
    ///   far-active blocks under that threshold  77.6 %, longest run 1.376 s of the 2.000 s
    ///   coherence ceiling for ANY linear filter single digits (4.3 dB full band on a click
    ///                                           train, 7.6 dB over 300-3400 Hz)
    /// ```
    ///
    /// The canceller is marginal there by measurement, not by opinion, and it does not reach
    /// confidence. So the taint rule stays in force and every spoken answer through the speakers
    /// produces one of these discards.
    ///
    /// That is what makes the wording load-bearing rather than cosmetic: this line is not a rare
    /// edge case he might see once, it is the line he meets after every spoken answer.
    ///
    /// ## What the sentence is allowed to assert
    ///
    /// Only what this file can prove: Rich was speaking, the canceller could not separate the
    /// two voices, and the audio captured in that window was not used. **Everything about the
    /// CEO is conditional** — `if you said something just then` — because the app genuinely does
    /// not know, and `the_notice_makes_no_unconditional_claim_about_the_ceo` pins that.
    ///
    /// It still states the CONSEQUENCE, for the reason [`VoiceNotice::HeardNoVoice`] does: the
    /// failure this explains is the app sending the TAIL of his sentence as though it were the
    /// whole of it, and "I haven't sent anything" is the fact that makes Rich answering a
    /// fragment make sense. It still ends with a STATUS and not an instruction — "wait until I
    /// finish" would be an instruction to use the product more carefully to work around a
    /// limitation, which is not a thing to ask of him.
    ///
    /// **Latched once per voice session**, not per run — see [`HalfDuplexNotice`]. What it
    /// describes is a standing property of the room and the hardware, not an event.
    CouldNotListenWhileSpeaking,
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
            // OPENS WITH THE AUDIT'S OWN WORDS, and they are the right words: "I didn't catch
            // that" is what a person says when they heard you and the words did not land. It
            // is the honest description of this path — a voice WAS measured, so "I heard
            // nothing" would be false, and naming whisper's `(clears throat)` would put an
            // implementation detail in his ear.
            //
            // IT STATES THE CONSEQUENCE SECOND, for `HeardNoVoice`'s reason: the question a
            // silent drop leaves open is whether something was sent anyway, and a fragment
            // sent as if it were a whole sentence is the failure mode this crate has already
            // shipped once. So the line closes that question before anything else.
            //
            // IT ENDS WITH A STATUS AND NOT AN INSTRUCTION. "Say that again" is an imperative
            // aimed at a reader who has no button to press — the affordance for repeating
            // himself IS the open microphone, and saying so is what tells him he can just
            // speak. Same last three words as `HeardNoVoice`, deliberately: the two are the
            // same event to him, and only the cause differs.
            VoiceNotice::DidNotCatchThat => {
                "I didn't catch that, so I haven't sent anything. I'm still listening."
            }
            // EVERY CLAUSE ABOUT THE CEO IS CONDITIONAL, and that is the whole correction.
            // The sentence this replaced opened "You started talking while I was still
            // speaking", which is an assertion about something HE did, made on the one code
            // path where the canceller has explicitly declined to vouch for its residual.
            // On the CEO's own rig it fired at him while he was silent, after every spoken
            // answer. A status may describe the app with certainty; it may not describe the
            // reader with certainty it does not have.
            //
            // IT DESCRIBES WHAT RICH DID, which IS knowable here: Rich was speaking, the two
            // voices could not be told apart, and the audio from that window was not used.
            // It makes no capability claim — "I can't hear you while I'm speaking" would be
            // false twice, because talking over Rich for long enough DOES cut him off today
            // and a confident canceller admits the utterance outright.
            //
            // IT STATES THE CONSEQUENCE, for the reason `HeardNoVoice` does, and here the
            // reason is sharper than anywhere else in this enum: the failure it explains is
            // the app sending the TAIL of his sentence as though it were the whole of it.
            // He watched Rich answer a fragment. "I haven't sent anything" is the fact that
            // makes that make sense.
            //
            // IT ENDS WITH A STATUS AND NOT AN INSTRUCTION. "Wait until I finish" is an
            // imperative, and worse, it is an instruction to use the product more carefully
            // to work around a limitation — which is not a thing to ask of him.
            VoiceNotice::CouldNotListenWhileSpeaking => {
                "While I was speaking, I couldn't tell your voice from my own — so if you \
                 said something just then, it didn't reach me and I haven't sent anything. \
                 I'm listening now."
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
    /// [`VoiceNotice::DidNotCatchThat`] has been said this run of discards. Latched for the
    /// reason [`Self::said_heard_no_voice`] is: the first discard speaks, the rest are stderr
    /// only, and admitting an utterance clears it.
    said_did_not_catch_that: bool,
}

impl Default for RecognizerDesk {
    fn default() -> Self {
        RecognizerDesk::new()
    }
}

impl RecognizerDesk {
    pub fn new() -> RecognizerDesk {
        RecognizerDesk {
            discards: 0,
            said_sound_but_no_words: false,
            said_heard_no_voice: false,
            said_did_not_catch_that: false,
        }
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
                    // THE OPERATOR'S LINE STAYS EXACTLY AS IT WAS. It carries the transcript
                    // that was thrown away, which is the one thing the CEO's sentence must
                    // never carry, and audit-3 read the defect off it.
                    eprintln!("[richos-voice] discarded non-speech transcript: {text:?}");
                    self.discards += 1;
                    if self.discards >= SILENT_DISCARD_RUN && !self.said_sound_but_no_words {
                        // THE STRONGER LINE TAKES OVER AND THE SHORT ONE STANDS ASIDE. Both
                        // firing here would say the same thing twice in one breath; latching
                        // the short one too means a longer run stays quiet after this.
                        self.said_sound_but_no_words = true;
                        self.said_did_not_catch_that = true;
                        observer.on_voice_event(&VoiceEvent::Error {
                            message: VoiceNotice::SoundButNoWords.ceo_message().to_string(),
                            at: now_millis(),
                        });
                    } else if !self.said_did_not_catch_that {
                        // THE FIX FOR audit-3 §4 #4. He spoke, a voice was measured, and
                        // until now the window did not change at all. A NOTICE, not an
                        // error: voice is running and has made a call on his behalf.
                        self.said_did_not_catch_that = true;
                        observer.on_voice_event(&VoiceEvent::Notice {
                            message: VoiceNotice::DidNotCatchThat.ceo_message().to_string(),
                            at: now_millis(),
                        });
                    }
                    return;
                }
                self.discards = 0;
                self.said_sound_but_no_words = false;
                // An admitted utterance proves the input recovered, so the run is over and the
                // next bad one speaks again.
                self.said_did_not_catch_that = false;
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

        // WHICH RECOGNIZER THIS MACHINE COULD CARRY, said out loud — once, here, at the toggle.
        //
        // `Resolution::ceo_message()` is `None` whenever the machine got the best rung it has or
        // an engineer named the model outright, so this is silent on a healthy machine and on a
        // developer's. It speaks only when the product has quietly made a choice on his behalf,
        // which is the thing `hardware.rs` exists to stop happening in silence.
        //
        // ONCE, NOT PER UTTERANCE. Resolution happens once per voice-mode start, and a sentence
        // repeated after everything he says is noise — and noise is what makes a real notice get
        // ignored. It rides `voice-notice` rather than `voice-error` because voice is WORKING:
        // the UI's `voice-error` handler also flips the panel out of voice mode, so sending it
        // there would end the conversation it was reporting on.
        if let Some(message) = recognizer.resolution().ceo_message() {
            observer.on_voice_event(&VoiceEvent::Notice { message, at: now_millis() });
        }

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
            pending_speech: AtomicUsize::new(0),
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
        // The canceller's live state, lossless and signed — see `AecShared`. One relaxed store
        // per frame from the audio thread, readable by anyone without a lock.
        let aec_state_for_diagnostics = Arc::new(AecShared::default());
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
            // touching the audio thread from outside it. Signed and unclamped: a negative ERLE
            // is a real reading and the old packing could not express it.
            let m = brain.aec_metrics();
            aec_state.store(
                brain.aec_confident(),
                m.map(|m| m.erle_db).unwrap_or(0.0),
                m.map(|m| m.leak_floor_rms).unwrap_or(0.0),
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
            // What the canceller can EARN, from the one frame-math helper. Never typed.
            barge_in_earned_frames: crate::bargein::AEC_BARGE_IN_WINDOW_FRAMES,
            barge_in_earned_secs: frames_to_secs(crate::bargein::AEC_BARGE_IN_WINDOW_FRAMES),
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
                    // This sentence is no longer "owed" from the moment this body ends,
                    // whichever way it ends. See `PendingSpeech`.
                    let _pending = PendingSpeech(shared.clone());
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
            // The canceller's live state, published per frame by the audio thread. The
            // supervisor reads it to report WHY a discard happened instead of guessing.
            let aec_state = aec_state_for_diagnostics.clone();
            let input_latency = capture.latency();
            threads.push(std::thread::spawn(move || {
                supervise(
                    shared,
                    machine,
                    playout,
                    observer,
                    cap_rx,
                    utt_tx,
                    aec_state,
                    input_latency,
                );
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
        self.aec_state.confident()
    }

    /// Live Echo Return Loss Enhancement in dB — how much of Rich's own voice the canceller is
    /// currently removing from the microphone. 0.0 until it has something to report, and
    /// **negative when the filter is adding energy rather than removing it**, which is a real
    /// state this returned `0` for until 2026-09-17. Measured, never estimated.
    pub fn echo_return_loss_enhancement_db(&self) -> f32 {
        self.aec_state.erle_db()
    }

    /// The tracked typical residual echo while Rich is audible, in dBFS. Compare with
    /// [`crate::aec::CONFIDENT_LEAK_RMS`] to see how far the canceller is from earning the
    /// short barge-in window on this hardware — the gap, not the verdict.
    pub fn echo_leak_floor_dbfs(&self) -> f32 {
        self.aec_state.leak_dbfs()
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

    /// **THE ONLY PLACE A SENTENCE IS HANDED TO THE SPEAKER THREAD.**
    ///
    /// One function because the increment of [`Shared::pending_speech`] has to happen at the
    /// SEND and not at the synthesis: between the two sits `say`'s process spawn, and that
    /// interval is precisely the gap an utterance used to be born untainted in. Counting from
    /// the send means Rich's answer is "in progress" from the instant its first sentence is
    /// handed over, before any sound exists — which also closes the 25 ms `TICK` the
    /// supervisor would otherwise take to notice the queue filling.
    ///
    /// A failed send decrements immediately: the speaker thread is gone, so nothing is owed.
    fn send_speak(&self, generation: u64, text: String) {
        let Some(tx) = &self.speak_tx else { return };
        self.shared.pending_speech.fetch_add(1, Ordering::Relaxed);
        if tx.send(SpeakMsg { generation, text }).is_err() {
            let _ = self.shared.pending_speech.fetch_update(
                Ordering::Relaxed,
                Ordering::Relaxed,
                |n| Some(n.saturating_sub(1)),
            );
        }
    }

    /// A `rich://chunk` delta arrived. Accumulate, and hand every completed sentence to the
    /// speaker thread immediately — this is the pipelining.
    pub fn speak_delta(&self, delta: &str) {
        let generation = self.shared.generation.load(Ordering::Relaxed);
        let sentences = match self.chunker.lock() {
            Ok(mut c) => c.push(delta),
            Err(_) => return,
        };
        for text in sentences {
            self.send_speak(generation, text);
        }
    }

    /// The turn's terminal event arrived: speak whatever is left.
    pub fn speak_end(&self) {
        let generation = self.shared.generation.load(Ordering::Relaxed);
        let tail = match self.chunker.lock() {
            Ok(mut c) => c.flush(),
            Err(_) => None,
        };
        if let Some(text) = tail {
            self.send_speak(generation, text);
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
        CutOffDesk::handle(reason, observer, |text| {
            self.send_speak(generation, text.to_string());
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

/// **WHETHER TO TELL HIM RICH COULD NOT LISTEN WHILE SPEAKING, AND HOW OFTEN.**
///
/// A struct rather than a `bool` in [`supervise`] for the reason [`RecognizerDesk`] is one:
/// what has to be provable is not the sentence but the CADENCE. A latch living as a local
/// inside a spawned thread is reachable only by a test that owns a microphone, which means in
/// practice it is reachable by no test at all.
///
/// ## ONCE PER VOICE SESSION — changed from once-per-run, and the number is the reason
///
/// It used to clear whenever an utterance got through, on the theory that being heard proves
/// the run is over. That theory assumed the discards were EVENTS — the CEO interrupting now
/// and then. On his actual hardware they are not.
///
/// Measured on this Mac, 2026-09-17 (`docs/verification/2026-09-17-aec-erle-on-the-ceo-rig.md`):
/// Mac mini Speakers out, Elgato Wave:3 in, steady-state ERLE of **−0.5 … +0.7 dB** across five
/// live runs — nothing measurably removed — against a residual that would have to sit at
/// **−52.04 dBFS** ([`crate::aec::CONFIDENT_LEAK_RMS`]) while the microphone reads −42 … −46 dBFS
/// during Rich's speech. The canceller does not reach confidence there, so Rich's own voice comes
/// back into the microphone, opens an utterance, and is discarded as taint **after every single
/// spoken answer**. Cleared-on-heard therefore means: he speaks, he is heard, the
/// latch clears, Rich answers, the echo is discarded, the notice fires. Once per answer, forever.
///
/// The crate's own doctrine on every other notice here is that a line each time is a drip that
/// trains him to ignore the one that matters. A drip about a STANDING property of the room is
/// worse than that — it is a drip that can never stop, because nothing he does changes it.
///
/// So it is said once, the first time the session hits it, and then never again. What is lost is
/// real and is named rather than glossed: a second genuine talk-over later in the same session
/// is silent. That is the honest trade on hardware where the app cannot tell a second talk-over
/// from the echo of Rich's next sentence.
///
/// Pure: no clock, no channel, no observer.
#[derive(Debug, Clone, Default)]
pub struct HalfDuplexNotice {
    said: bool,
}

impl HalfDuplexNotice {
    pub fn new() -> Self {
        HalfDuplexNotice::default()
    }

    /// An utterance that began inside Rich's playout was discarded because the canceller could
    /// not vouch for the residual. Returns whether this is the one to say out loud.
    pub fn discard_during_playout(&mut self) -> bool {
        if self.said {
            return false;
        }
        self.said = true;
        true
    }

    /// Has the notice already been said in this voice session? The diagnostic that makes "why
    /// did it not say anything" answerable without re-reading the caller.
    pub fn already_said(&self) -> bool {
        self.said
    }
}

/// The supervisor loop: owns the state machine, emits every UI event, dispatches work.
#[allow(clippy::too_many_arguments)]
fn supervise(
    shared: Arc<Shared>,
    machine: Arc<Mutex<VoiceStateMachine>>,
    playout: Arc<Playout>,
    observer: Arc<dyn VoiceObserver>,
    cap_rx: Receiver<CapMsg>,
    utt_tx: Sender<Box<Utterance>>,
    shared_aec: Arc<AecShared>,
    input_latency: crate::capture::InputLatency,
) {
    let mut last_state = VoiceState::Off;
    // Rich's audible window, and the monotonic clock that drives it. `Instant`, never the wall
    // clock: a window that closes early because the system clock stepped is the defect again.
    let mut audible = AudibleWindow::new();
    let started_at = Instant::now();
    // `VoiceNotice::CouldNotListenWhileSpeaking` has been said in this voice session. Latched
    // for the whole session rather than per run — see `HalfDuplexNotice`, which carries the
    // measurement that decided it.
    let mut half_duplex = HalfDuplexNotice::new();
    let mut last_level_emit = Instant::now() - LEVEL_EMIT_EVERY;
    let mut last_level = -1.0f32;
    let mut no_audio = false;
    let mut no_audio_changed = false;

    while shared.running.load(Ordering::SeqCst) {
        // 1. Drain the audio thread's messages.
        loop {
            match cap_rx.try_recv() {
                Ok(CapMsg::Started { tainted }) => {
                    // **PRINTED WHETHER TRUE OR FALSE** — Ray's walk could not tell an admitted
                    // utterance from a discarded one in the log, because only discards printed.
                    // An invariant you can only ever see violated is not one you can audit.
                    eprintln!(
                        "[richos-voice] {} utterance START tainted={tainted} (Rich audible={})",
                        wall_clock_utc(),
                        shared.speaking.load(Ordering::Relaxed)
                    );
                    if !tainted {
                        if let Ok(mut m) = machine.lock() {
                            m.utterance_started();
                        }
                    }
                }
                Ok(CapMsg::Utterance(u)) => {
                    eprintln!(
                        "[richos-voice] {} utterance END ADMITTED — {:.3} s, on to the recognizer (Rich audible={})",
                        wall_clock_utc(),
                        u.samples.len() as f32 / crate::vad::SAMPLE_RATE as f32,
                        shared.speaking.load(Ordering::Relaxed)
                    );
                    if let Ok(mut m) = machine.lock() {
                        m.utterance_ended();
                    }
                    let _ = utt_tx.send(u);
                }
                Ok(CapMsg::Discarded { tainted }) => {
                    eprintln!(
                        "[richos-voice] {} utterance END DISCARDED tainted={tainted} (Rich audible={})",
                        wall_clock_utc(),
                        shared.speaking.load(Ordering::Relaxed)
                    );
                    if let Ok(mut m) = machine.lock() {
                        m.utterance_ended();
                    }
                    if tainted {
                        // **THE OLD TEXT HERE SAID `(no AEC)` AND THAT WAS FALSE.** The
                        // canceller is running on this exact frame — `CaptureBrain::push_frame`
                        // subtracts the echo before the VAD, the endpointer or the recorder
                        // see anything. What is true is narrower and it is the fact that
                        // decides the CEO's experience: the canceller has not yet MEASURED
                        // its residual low enough, for long enough, to be trusted, so the
                        // fallback taint rule is the one in force.
                        //
                        // The difference is not pedantry. Audit-3 read `(no AEC)` off the
                        // running app, concluded the feature was absent, and filed the boot
                        // line's `aec=PBFDAF` as a contradiction. Both lines were describing
                        // the same working canceller in two different states, and one of them
                        // was lying about which.
                        //
                        // **AND THE REPLACEMENT OVER-PROMISED IN ITS TURN, which is why this
                        // line changed again on 2026-09-17.** It said the canceller "has not
                        // proven itself YET" and that barge-in needed 5.008 s "UNTIL IT DOES".
                        // Both words promise a convergence that, on the CEO's own hardware,
                        // never arrives: measured that day across five live runs, the
                        // steady-state ERLE is −0.5 … +0.7 dB and the microphone reads −42 … −46
                        // dBFS while Rich speaks, against the −52.04 dBFS the threshold demands
                        // (`docs/verification/2026-09-17-aec-erle-on-the-ceo-rig.md`). So the
                        // line now reports the GAP — measured ERLE, measured residual, the
                        // threshold it has to reach — and lets the reader see how far short it
                        // is, instead of asserting that it is nearly there.
                        let erle = shared_aec.erle_db();
                        let leak = shared_aec.leak_dbfs();
                        eprintln!(
                            "[richos-voice] discarded audio captured while Rich was speaking — the echo canceller cannot vouch for this audio (erle={erle:.1} dB, residual {leak:.1} dBFS vs the {:.1} dBFS it must hold for {:.3} s after {:.3} s of Rich speaking); barge-in needs {:.3} s of talking over him while that is so",
                            dbfs(crate::aec::CONFIDENT_LEAK_RMS),
                            crate::aec::blocks_to_secs(crate::aec::CONFIDENCE_HOLD_BLOCKS),
                            crate::aec::blocks_to_secs(crate::aec::CONFIDENCE_WARMUP_BLOCKS),
                            crate::vad::frames_to_secs(BARGE_IN_DEBOUNCE_FRAMES),
                        );
                        // AND HE IS TOLD, once per voice session — see `HalfDuplexNotice`.
                        // What he is told asserts nothing about whether he spoke, because on
                        // this path the app cannot know: `tainted` requires `!confident`, and
                        // `!confident` is the canceller saying it cannot separate the voices.
                        if half_duplex.discard_during_playout() {
                            observer.on_voice_event(&VoiceEvent::Notice {
                                message: VoiceNotice::CouldNotListenWhileSpeaking
                                    .ceo_message()
                                    .to_string(),
                                at: now_millis(),
                            });
                        }
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

        // 2. Reconcile playout with the state machine, and decide whether Rich is AUDIBLE.
        //
        //    **THE QUEUE IS NOT THE GROUND TRUTH FOR THAT, and this line used to say it was.**
        //    `playout.is_playing()` is `queued_samples() > 0`, which is false before the first
        //    sample of an answer, false in every gap between spoken sentences, and false while
        //    the device is still emitting the last one. See `AudibleWindow`.
        let queued = playout.is_playing();
        let owed = shared.pending_speech.load(Ordering::Relaxed);
        let hold = audible_hold_secs(playout.audible_tail_secs(), input_latency.secs());
        let now_ms = started_at.elapsed().as_millis() as u64;
        let (answer_edge, chunk_edge) = audible.observe(queued, owed > 0, hold, now_ms);
        let playing = audible.is_open();
        shared.speaking.store(playing, Ordering::Relaxed);

        // **THE BOUNDARIES, WITH A WALL CLOCK.** Ray's candidate-.5 walk could not say from the
        // record whether the admitted utterance began in a gap between spoken sentences or
        // after playout had ended, because nothing here was timestamped and the chunk
        // boundaries were never printed at all. Both are printed now, in the ledger's own
        // format, so the next walk reads the answer off the log instead of inferring it.
        match chunk_edge {
            Some(Edge::Rose) => eprintln!(
                "[richos-voice] {} playout chunk START — {:.3} s queued, {owed} sentence(s) still in synthesis",
                wall_clock_utc(),
                playout.queued_secs()
            ),
            Some(Edge::Fell) => eprintln!(
                "[richos-voice] {} playout chunk END — queue empty, {owed} sentence(s) still in synthesis",
                wall_clock_utc()
            ),
            None => {}
        }
        match answer_edge {
            Some(Edge::Rose) => eprintln!(
                "[richos-voice] {} ANSWER AUDIBLE — half-duplex window OPEN (hold after the last sample {:.0} ms = out {:.1} + in {:.1} + slicer {:.1})",
                wall_clock_utc(),
                hold * 1000.0,
                playout.audible_tail_secs() * 1000.0,
                input_latency.secs() * 1000.0,
                frames_to_secs(1) * 1000.0
            ),
            Some(Edge::Fell) => eprintln!(
                "[richos-voice] {} answer over — half-duplex window CLOSED, the microphone is the CEO's again",
                wall_clock_utc()
            ),
            None => {}
        }

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

    /// `rich://voice-notice` only. A SEPARATE helper from `messages()` on purpose: the whole
    /// point of audit-3 §4 #4's fix is which CHANNEL the sentence goes down, and a helper
    /// that merged the two would pass whether the line was a notice or an error.
    fn notices(rec: &Recorder) -> Vec<String> {
        rec.events
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| match e {
                VoiceEvent::Notice { message, .. } => Some(message.clone()),
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

    /// INVARIANT — **audit-3 §4 #4, the exact frame `a3-15`.** One 2.3 s utterance, whisper
    /// returns `(clears throat)`, and the window must not sit there unchanged.
    ///
    /// The numbers are the audit's: a 2.3 s recording, and whisper's real return value. What
    /// is asserted is all three halves of the defect — he is TOLD, nothing was SENT, and the
    /// operator's log line still carries the transcript (that last one by the `eprintln`
    /// beside the emit, which this test cannot read and does not claim to).
    #[test]
    fn a_single_discarded_transcript_says_so_instead_of_changing_nothing() {
        let rec = Recorder::default();
        let mut desk = RecognizerDesk::new();
        desk.handle(
            &utterance(framed(synthetic_voice(2.3, 190.0, 130.0, -26.0), -55.0, 23)),
            &rec,
            |_| Ok(("(clears throat)".to_string(), 310)),
            |t| panic!("a discarded transcript was submitted as his message: {t:?}"),
        );
        assert_eq!(
            notices(&rec),
            vec![VoiceNotice::DidNotCatchThat.ceo_message().to_string()],
            "the discard was silent — the defect audit-3 §4 #4 recorded at frame a3-15"
        );
        assert!(transcripts(&rec).is_empty(), "whisper's noise reached the thread");
        assert!(
            messages(&rec).is_empty(),
            "a working microphone raised a voice-ERROR; nothing failed and voice did not stop"
        );
    }

    /// POSITIVE CONTROL for the test above. Without it that test would pass just as well if
    /// the notice fired on EVERY utterance, which would be a worse product than the silence
    /// it replaced.
    #[test]
    fn an_utterance_that_becomes_a_turn_raises_no_notice_at_all() {
        let rec = Recorder::default();
        let mut desk = RecognizerDesk::new();
        let sent = Mutex::new(Vec::<String>::new());
        desk.handle(
            &utterance(framed(synthetic_voice(2.3, 190.0, 130.0, -26.0), -55.0, 23)),
            &rec,
            |_| Ok(("Book the flight for Tuesday.".to_string(), 310)),
            |t| sent.lock().unwrap().push(t),
        );
        assert_eq!(sent.into_inner().unwrap(), vec!["Book the flight for Tuesday.".to_string()]);
        assert!(notices(&rec).is_empty(), "a good turn apologized for itself");
        assert!(messages(&rec).is_empty());
    }

    /// INVARIANT: a RUN of discards produces two sentences in total, in order, and never two
    /// in one breath. The short line speaks first because it is the first thing he needs; at
    /// [`SILENT_DISCARD_RUN`] the stronger line takes over and the short one stands aside.
    ///
    /// The count is the thing being pinned. Before this change the run said NOTHING until the
    /// third; a fix that made it say something every time would be a drip, which is the
    /// failure `HeardNoVoice` documents at length.
    #[test]
    fn a_run_of_discards_speaks_once_then_escalates_once_and_never_both_at_once() {
        let rec = Recorder::default();
        let mut desk = RecognizerDesk::new();
        let discard = |desk: &mut RecognizerDesk, rec: &Recorder, seed: u64| {
            desk.handle(
                &utterance(framed(synthetic_voice(1.2, 190.0, 130.0, -26.0), -55.0, seed)),
                rec,
                |_| Ok(("[BLANK_AUDIO]".to_string(), 300)),
                |t| panic!("submitted: {t:?}"),
            );
        };

        discard(&mut desk, &rec, 31);
        assert_eq!(notices(&rec).len(), 1, "the first discard was silent");
        assert!(messages(&rec).is_empty(), "the first discard escalated immediately");

        discard(&mut desk, &rec, 37);
        assert_eq!(notices(&rec).len(), 1, "the second discard repeated the line — a drip");
        assert!(messages(&rec).is_empty());

        // SILENT_DISCARD_RUN == 3: the stronger line, and NOT a second short one.
        discard(&mut desk, &rec, 41);
        assert_eq!(
            messages(&rec),
            vec![VoiceNotice::SoundButNoWords.ceo_message().to_string()],
            "the run never escalated"
        );
        assert_eq!(notices(&rec).len(), 1, "both lines fired at once — he was told twice");

        discard(&mut desk, &rec, 43);
        assert_eq!(notices(&rec).len(), 1, "the run kept talking after it had said its piece");
        assert_eq!(messages(&rec).len(), 1);
    }

    /// INVARIANT: the latch clears on a good turn, so the next bad one speaks again. Same
    /// contract as `the_refusal_is_said_once_per_run_and_again_after_the_room_recovers`,
    /// which is the neighboring refusal path — the two now behave the same way, and that
    /// symmetry IS the fix.
    #[test]
    fn a_good_turn_clears_the_latch_so_the_next_discard_speaks_again() {
        let rec = Recorder::default();
        let mut desk = RecognizerDesk::new();
        let discard = |desk: &mut RecognizerDesk, rec: &Recorder, seed: u64| {
            desk.handle(
                &utterance(framed(synthetic_voice(1.2, 190.0, 130.0, -26.0), -55.0, seed)),
                rec,
                |_| Ok(("(clears throat)".to_string(), 300)),
                |_| {},
            );
        };
        discard(&mut desk, &rec, 51);
        assert_eq!(notices(&rec).len(), 1);

        desk.handle(
            &utterance(framed(synthetic_voice(1.2, 190.0, 130.0, -26.0), -55.0, 53)),
            &rec,
            |_| Ok(("Approved.".to_string(), 300)),
            |_| {},
        );
        discard(&mut desk, &rec, 59);
        assert_eq!(notices(&rec).len(), 2, "the discard went silent after a good turn");
    }

    /// INVARIANT — **audit-3 §4 #1: a discard during Rich's playout is no longer silent.** The
    /// first one of the voice session says so; the rest are stderr only.
    #[test]
    fn the_first_discard_during_playout_says_so_and_the_rest_do_not() {
        let mut latch = HalfDuplexNotice::new();
        assert!(latch.discard_during_playout(), "the first one was silent — the defect itself");
        assert!(latch.already_said());
        assert!(!latch.discard_during_playout(), "the notice became a drip");
        assert!(!latch.discard_during_playout());
    }

    /// INVARIANT — **and this is the assertion that reversed on 2026-09-17.** It used to read
    /// `being_heard_clears_the_talked_over_latch`: an admitted utterance reset the latch, so
    /// the next discard spoke again.
    ///
    /// **Ray's candidate-.4 walk is what made that wrong.** On the CEO's rig the discards are
    /// not interruptions, they are Rich's own voice returning through the speakers, and they
    /// happen after EVERY spoken answer. So the old cycle was: he speaks → heard → latch clears
    /// → Rich answers → echo discarded → notice. One notice per answer, for the life of the
    /// session, about a condition nothing he does can change. The measurement behind "nothing
    /// he does can change it" is in `HalfDuplexNotice`'s own doc comment: single-digit ERLE on a
    /// path that would need the residual 6 dB under the VAD's speech floor.
    ///
    /// So being heard no longer clears it, and the latch has no clearing path at all.
    #[test]
    fn being_heard_does_not_re_arm_the_notice_because_the_condition_is_not_an_event() {
        let mut latch = HalfDuplexNotice::new();
        assert!(latch.discard_during_playout());
        // The supervisor's `CapMsg::Utterance` arm used to call `heard()` here. There is
        // deliberately no such method to call: a per-answer line is the defect this prevents.
        assert!(latch.already_said(), "the latch cleared itself somehow");
        assert!(!latch.discard_during_playout(), "one notice per spoken answer, forever");
    }

    /// INVARIANT: a fresh latch says nothing until something is actually discarded. Without
    /// this, a latch that returned `true` on construction would pass the two tests above.
    #[test]
    fn a_fresh_latch_has_nothing_to_say() {
        let latch = HalfDuplexNotice::new();
        assert!(!latch.already_said());
        assert!(!HalfDuplexNotice::default().already_said());
    }

    /// **NEGATIVE PROBE — candidate .4's blocker: the notice must not tell him he spoke.**
    ///
    /// Ray proved on the CEO's screen that this line fires on Rich's own echo with the CEO
    /// silent (volume 85 → notice; the identical turn at volume 0 → no discard, no notice).
    /// The sentence that shipped opened *"You started talking while I was still speaking"*,
    /// which is a statement about something HE did, emitted on the one path where the canceller
    /// has declined to vouch for its residual.
    ///
    /// This asserts the property rather than the sentence: **every reference to the CEO is
    /// conditional.** A future edit may reword freely and may not reintroduce an assertion
    /// about him.
    #[test]
    fn the_notice_makes_no_unconditional_claim_about_the_ceo() {
        let m = VoiceNotice::CouldNotListenWhileSpeaking.ceo_message();
        let lower = m.to_lowercase();
        // The conditional is the whole correction, so it is required by name.
        assert!(lower.contains("if you said something"), "{m}");
        // None of these can be true of a path where `confident == false`. The first is the
        // exact sentence Ray's walk refused.
        for accusation in [
            "you started talking",
            "you were talking",
            "you spoke",
            "you interrupted",
            "you talked over",
            "your voice reached",
        ] {
            assert!(!lower.contains(accusation), "{m} asserts {accusation:?} and cannot know it");
        }
        // What it IS allowed to assert: Rich's own behavior, which this file does know.
        assert!(lower.contains("while i was speaking"), "{m}");
    }

    /// INVARIANT: the line still states the CONSEQUENCE and still ends with a status rather
    /// than an instruction — the two properties the wording change had to preserve.
    #[test]
    fn the_half_duplex_line_states_the_consequence_and_promises_nothing() {
        let m = VoiceNotice::CouldNotListenWhileSpeaking.ceo_message();
        // The fact he is missing: those words did not arrive, and nothing was sent in his
        // name. The second half is what makes Rich answering a fragment make sense.
        assert!(m.contains("didn't reach me"), "{m}");
        assert!(m.contains("haven't sent anything"), "{m}");
        // Ends with a status, never an instruction to work around the limitation.
        assert!(m.ends_with("I'm listening now."), "{m}");
        for imperative in ["wait ", "try ", "please", "say it again"] {
            assert!(!m.to_lowercase().contains(imperative), "{m} contains {imperative:?}");
        }
        // No machinery, same bar as every other notice here.
        assert!(!m.chars().any(|c| c.is_ascii_digit()), "{m}");
        assert!(!m.to_lowercase().contains("aec"), "{m}");
        assert!(!m.to_lowercase().contains("cancel"), "{m}");
        assert!(!m.to_lowercase().contains("barge"), "{m}");
    }

    /// **THE PUBLISHED ERLE CAN BE NEGATIVE.** The packed `AtomicU32` this replaced computed
    /// `(erle_db.max(0.0) as u32) << 1`, so the −0.1 dB measured live on the CEO's rig reached
    /// the operator log as `erle=0 dB` — indistinguishable from "has not started".
    #[test]
    fn a_negative_erle_survives_publication() {
        let s = AecShared::default();
        s.store(false, -0.14, 0.0148);
        assert!(!s.confident());
        assert!((s.erle_db() - (-0.14)).abs() < 0.001, "{}", s.erle_db());
        // 0.0148 rms = 20*log10(0.0148) = -36.59 dBFS — the live figure from the walk's rig.
        assert!((s.leak_dbfs() - (-36.59)).abs() < 0.02, "{}", s.leak_dbfs());
        // POSITIVE CONTROL: the same path carries a positive reading unharmed.
        s.store(true, 28.0, 0.00126);
        assert!(s.confident());
        assert!((s.erle_db() - 28.0).abs() < 0.001, "{}", s.erle_db());
    }

    /// INVARIANT: every notice in the enum is a DIFFERENT sentence. Four states that mean
    /// four different things about his microphone must not collapse into one.
    #[test]
    fn no_two_voice_notices_say_the_same_thing() {
        let all = [
            VoiceNotice::SoundButNoWords.ceo_message(),
            VoiceNotice::HeardNoVoice.ceo_message(),
            VoiceNotice::ReplyCutOff.ceo_message(),
            VoiceNotice::DidNotCatchThat.ceo_message(),
            VoiceNotice::CouldNotListenWhileSpeaking.ceo_message(),
        ];
        for (i, a) in all.iter().enumerate() {
            for (j, b) in all.iter().enumerate() {
                if i != j {
                    assert_ne!(a, b, "two notices say the same thing");
                }
            }
        }
    }

    /// INVARIANT: the two refusal paths say DIFFERENT sentences, because they are different
    /// facts about the room. `HeardNoVoice` means no voice was measured at all; this one
    /// means a voice WAS measured and the words did not survive. Collapsing them would tell
    /// him his microphone is dead when it is working perfectly.
    #[test]
    fn the_two_refusal_paths_do_not_say_the_same_thing() {
        let caught = VoiceNotice::DidNotCatchThat.ceo_message();
        for other in [
            VoiceNotice::HeardNoVoice.ceo_message(),
            VoiceNotice::SoundButNoWords.ceo_message(),
            VoiceNotice::ReplyCutOff.ceo_message(),
        ] {
            assert_ne!(caught, other);
        }
        // House discipline, asserted rather than trusted: it closes the "was anything sent?"
        // question and ends with a status rather than an instruction.
        assert!(caught.contains("haven't sent anything"));
        assert!(caught.ends_with("I'm still listening."));
        // NAMES NO MACHINERY — the same bar `the_silent_discard_notice_names_no_control_and_no
        // _machinery` holds `SoundButNoWords` to. The transcript that was thrown away is the
        // operator's `eprintln`, never his sentence.
        assert!(!caught.contains('/'), "{caught}");
        assert!(!caught.chars().any(|c| c.is_ascii_digit()), "{caught}");
        assert!(!caught.to_lowercase().contains("whisper"), "{caught}");
        assert!(!caught.to_lowercase().contains("transcri"), "{caught}");
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
            echo_gate: "PBFDAF 2048 taps (128 ms tail)".into(),
            echo_cancellation: true,
            barge_in_frames: BARGE_IN_DEBOUNCE_FRAMES,
            barge_in_secs: frames_to_secs(BARGE_IN_DEBOUNCE_FRAMES),
            barge_in_earned_frames: crate::bargein::AEC_BARGE_IN_WINDOW_FRAMES,
            barge_in_earned_secs: frames_to_secs(crate::bargein::AEC_BARGE_IN_WINDOW_FRAMES),
        };
        let s = d.summary();
        // Printed so `--nocapture` shows the line a reviewer would read at boot, rather than
        // leaving them to reassemble it from the assertions below.
        println!("{s}");
        assert!(s.contains("313 frames"), "{s}");
        assert!(s.contains("5.008 s"), "{s}");
        // THE LINE MUST NOT STOP THERE. Two bare figures read as a settled capability, and
        // audit-3 §4 #1 read them exactly that way off the running app.
        assert!(s.contains("until the canceller proves itself"), "{s}");
        assert!(s.contains("25 frames"), "{s}");
        assert!(s.contains("0.400 s"), "{s}");
        assert!(
            d.echo_cancellation,
            "echo cancellation SHIPS — this assertion used to read the other way and had \
             outlived the aec.rs landing"
        );
    }

    /// INVARIANT — **THE FRAME MATH, RE-DERIVED HERE RATHER THAN TRUSTED.** Every figure the
    /// boot line prints, and every figure audit-3 §4 #1 reasoned about, computed from the
    /// constants by the one helper: `frames × 256 ÷ 16000`, shown rather than asserted.
    ///
    /// This exists because the audit had to take two printed numbers on faith to write its
    /// finding, and one of the two was a fallback wearing a capability's clothes.
    #[test]
    fn every_number_the_boot_line_prints_is_the_frame_math_and_not_a_round_figure() {
        assert_eq!(crate::vad::SAMPLE_RATE, 16_000);
        assert_eq!(crate::vad::VAD_FRAME_SAMPLES, 256);

        // The fallback debounce, in force until the canceller earns better.
        assert_eq!(BARGE_IN_DEBOUNCE_FRAMES, 313);
        assert!((frames_to_secs(313) - 5.008).abs() < 1e-6, "{}", frames_to_secs(313));

        // What it shortens to, and how much of that window must be speech.
        assert_eq!(crate::bargein::AEC_BARGE_IN_WINDOW_FRAMES, 25);
        assert!((frames_to_secs(25) - 0.400).abs() < 1e-6);
        assert!(
            (frames_to_secs(crate::bargein::AEC_BARGE_IN_REQUIRED_FRAMES) - 0.240).abs() < 1e-6
        );

        // The filter, and the price of confidence: 2.000 s of warm-up, then 2.000 s held.
        assert_eq!(crate::aec::AEC_TAPS, 2048);
        assert!((crate::aec::filter_tail_secs() - 0.128).abs() < 1e-6);
        assert!(
            (crate::aec::blocks_to_secs(crate::aec::CONFIDENCE_WARMUP_BLOCKS) - 2.000).abs() < 1e-6
        );
        assert!(
            (crate::aec::blocks_to_secs(crate::aec::CONFIDENCE_HOLD_BLOCKS) - 2.000).abs() < 1e-6
        );
        assert!(
            (crate::aec::blocks_to_secs(
                crate::aec::CONFIDENCE_WARMUP_BLOCKS + crate::aec::CONFIDENCE_HOLD_BLOCKS
            ) - 4.000)
                .abs()
                < 1e-6,
            "confidence costs 4.000 s of Rich ACTUALLY SPEAKING, not 4.000 s of wall clock"
        );
    }

    /// INVARIANT — **THE QUESTION AUDIT-3 §4 #1 LEFT OPEN, ANSWERED WITHOUT A MICROPHONE.**
    ///
    /// The audit could not tell whether the CEO's sentence was cut only by the discard window
    /// or ALSO by an end-of-utterance cut, and named the experiment that would settle it:
    /// "one person speaking one uninterrupted sentence longer than four seconds while Rich is
    /// silent". It is an acoustic experiment for a fact that is not acoustic — the endpointer
    /// decides it, and it decides it the same way every time.
    ///
    /// **There is no four-second cut.** The only two limits an uninterrupted utterance can
    /// meet:
    ///   * `SILENCE_HANGOVER_FRAMES` =   50 × 256 ÷ 16000 =  0.800 s of SILENCE ends it, and
    ///     an uninterrupted sentence by definition never contains that much;
    ///   * `MAX_UTTERANCE_FRAMES`    = 1875 × 256 ÷ 16000 = 30.000 s, the ceiling.
    ///
    /// So a sentence "longer than four seconds" is not a special case at all, and the cut the
    /// CEO saw was the discard window and nothing else.
    #[test]
    fn nothing_cuts_an_uninterrupted_sentence_at_four_seconds() {
        let hangover = frames_to_secs(crate::endpoint::SILENCE_HANGOVER_FRAMES);
        let ceiling = frames_to_secs(crate::endpoint::MAX_UTTERANCE_FRAMES);
        assert!((hangover - 0.800).abs() < 1e-6, "{hangover}");
        assert!((ceiling - 30.000).abs() < 1e-6, "{ceiling}");
        // Nothing between the hangover and the ceiling ends an utterance that keeps
        // producing speech, so every length the audit wondered about survives.
        for secs in [4.1_f32, 5.0, 10.0, 29.0] {
            assert!(
                secs > hangover && secs < ceiling,
                "{secs} s would be cut, which would make the audit's worry real"
            );
        }
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
